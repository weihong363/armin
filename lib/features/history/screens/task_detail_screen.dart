import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../runtime/services/runtime_event_bus.dart';
import '../../runtime/models/runtime_task_snapshot.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/parsers/approval_request.dart';
import '../../agent/parsers/task_result.dart';
import '../../agent/parsers/terminal_prompt.dart';
import '../../agent/services/codex_output_cleaner.dart';
import '../../voice/services/device_voice_service.dart';
import '../../voice/services/voice_service.dart';
import '../../tasks/models/native_output_turn.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/models/voice_input.dart';
import '../../tasks/services/output_summary_provider.dart';
import '../../tasks/services/semantic_snippet_builder.dart';
import '../../tasks/services/turn_output_slicer.dart';
import '../../tasks/services/voice_task_command_processor.dart';
import '../../tasks/screens/task_draft_screen.dart';
import '../../tasks/widgets/add_context_sheet.dart';

enum _TaskDetailAction {
  rerun,
  forceStop,
  cleanupSession,
  delete,
}

class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _resultTabIndex = 1;
  static const _refreshTriggerDistance = 96.0;
  static const _topRefreshGestureHeight = 180.0;
  static const _maxTopPullOffset = 36.0;

  late final TabController _tabController =
      TabController(length: 3, vsync: this);
  final _attentionAnchorKey = GlobalKey();
  int _latestTurnRevealToken = 0;
  String _handledAttentionRevealSignature = '';

  StreamSubscription<RuntimeEvent>? _eventSubscription;
  int _resultVersion = 0;
  RuntimeTaskSnapshot? _progressSnapshot;
  bool _taskPageAtTop = true;
  bool _topRefreshTracking = false;
  bool _topRefreshArmed = false;
  bool _topRefreshRunning = false;
  double _topRefreshDragDistance = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = AppStateScope.read(context);
    _eventSubscription = state.runtimeEvents.listen(_onRuntimeEvent);
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _revealLatestResult();
    }
  }

  void _revealLatestResult() {
    if (!mounted) {
      return;
    }
    setState(() {
      _latestTurnRevealToken++;
    });
    if (_tabController.index != _resultTabIndex) {
      _tabController.animateTo(_resultTabIndex);
    }
  }

  void _onRuntimeEvent(RuntimeEvent event) {
    if (event.taskId != widget.taskId || !mounted) {
      return;
    }
    switch (event.type) {
      case RuntimeEventType.taskProgress:
        // Lightweight: only update the snapshot for progress bar / status label.
        // No full rebuild — InheritedNotifier still drives batched frame-end
        // rebuilds, but _resultVersion stays unchanged so _ResultPanel skips
        // expensive _outputSummaries computation.
        if (event.snapshot != null) {
          setState(() {
            _progressSnapshot = event.snapshot;
          });
        }
        break;
      case RuntimeEventType.taskCompleted:
      case RuntimeEventType.taskFailed:
      case RuntimeEventType.taskCancelled:
      case RuntimeEventType.taskStopped:
      case RuntimeEventType.taskWaitingUser:
      case RuntimeEventType.taskPaused:
        // Terminal / low-frequency: bump version so _ResultPanel does a full
        // recomputation. Clear progress snapshot so UI switches to full
        // TaskSession data.
        setState(() {
          _progressSnapshot = null;
          _resultVersion++;
        });
      case RuntimeEventType.taskCreated:
      case RuntimeEventType.taskStarted:
      case RuntimeEventType.taskResumed:
      case RuntimeEventType.connectionRestored:
        setState(() {
          _resultVersion++;
        });
      case RuntimeEventType.outputUpdated:
      case RuntimeEventType.deliverableUpdated:
      case RuntimeEventType.approvalRequested:
      case RuntimeEventType.approvalResolving:
      case RuntimeEventType.approvalResolved:
      case RuntimeEventType.approvalRejected:
      case RuntimeEventType.approvalFailed:
      case RuntimeEventType.observerAttached:
      case RuntimeEventType.observerDetached:
      case RuntimeEventType.connectionLost:
      case RuntimeEventType.reviewSubmitted:
      case RuntimeEventType.waitingForInstruction:
      case RuntimeEventType.waitingForReview:
      case RuntimeEventType.waitingForApproval:
        // New event types: no special handling needed for detail screen yet.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = _findTask(state.tasks);
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }
    _maybeRevealAttentionAction(task);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          PopupMenuButton<_TaskDetailAction>(
            onSelected: (action) async {
              switch (action) {
                case _TaskDetailAction.rerun:
                  _rerunTask(context, task);
                case _TaskDetailAction.forceStop:
                  await _forceStopTask(context, task);
                case _TaskDetailAction.cleanupSession:
                  await _cleanupSession(context, task);
                case _TaskDetailAction.delete:
                  _confirmDelete(context, task);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _TaskDetailAction.rerun,
                enabled: _canRerun(task),
                child: const Text('重新执行'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.forceStop,
                enabled: _canForceStop(task),
                child: const Text('强制停止'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.cleanupSession,
                enabled: _canCleanupSession(task),
                child: const Text('清理远端会话'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.delete,
                enabled: _canDelete(task),
                child: const Text('删除任务'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Listener(
          onPointerDown: _handleTopRefreshPointerDown,
          onPointerMove: _handleTopRefreshPointerMove,
          onPointerUp: (_) => _finishTopRefreshGesture(context, task),
          onPointerCancel: (_) => _resetTopRefreshGesture(),
          child: Stack(
            children: [
              Transform.translate(
                offset: Offset(0, _topPullOffset),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleTaskScrollNotification,
                  child: NestedScrollView(
                    physics: const _DeliberateRefreshScrollPhysics(),
                    headerSliverBuilder: (context, innerBoxIsScrolled) => [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver:
                            SliverToBoxAdapter(child: _TaskHeader(task: task)),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: _CurrentSituationCard(
                              task: task, progressSnapshot: _progressSnapshot),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: KeyedSubtree(
                            key: _attentionAnchorKey,
                            child: _TaskNeedsPanel(
                              task: task,
                              onViewResult: _revealLatestResult,
                            ),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _TabBarHeaderDelegate(
                          TabBar(
                            controller: _tabController,
                            isScrollable: false,
                            labelColor: ArminTheme.ink,
                            indicatorColor: ArminTheme.primary,
                            tabs: const [
                              Tab(text: '动态'),
                              Tab(text: '产出'),
                              Tab(text: '高级'),
                            ],
                          ),
                        ),
                      ),
                    ],
                    body: TabBarView(
                      controller: _tabController,
                      children: [
                        _TimelinePanel(task: task),
                        _ResultPanel(
                          task: task,
                          revealLatestTurnToken: _latestTurnRevealToken,
                          resultVersion: _resultVersion,
                        ),
                        _AdvancedDebugPanel(task: task),
                      ],
                    ),
                  ),
                ),
              ),
              if (_topRefreshArmed || _topRefreshRunning)
                const Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: ArminTheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double get _topPullOffset =>
      math.min(_topRefreshDragDistance * 0.35, _maxTopPullOffset);

  void _handleTopRefreshPointerDown(PointerDownEvent event) {
    final canStart = _taskPageAtTop &&
        event.localPosition.dy <= _topRefreshGestureHeight &&
        !_topRefreshRunning;
    _topRefreshTracking = canStart;
    _topRefreshDragDistance = 0;
    _topRefreshArmed = false;
  }

  void _handleTopRefreshPointerMove(PointerMoveEvent event) {
    if (!_topRefreshTracking || event.delta.dy <= 0) {
      return;
    }
    setState(() {
      _topRefreshDragDistance += event.delta.dy;
      _topRefreshArmed = _topRefreshDragDistance >= _refreshTriggerDistance;
    });
  }

  Future<void> _finishTopRefreshGesture(
    BuildContext context,
    TaskSession task,
  ) async {
    if (!_topRefreshTracking) {
      return;
    }
    final shouldRefresh = _topRefreshDragDistance >= _refreshTriggerDistance;
    _topRefreshTracking = false;
    if (!shouldRefresh) {
      _resetTopRefreshGesture();
      return;
    }
    setState(() {
      _topRefreshRunning = true;
      _topRefreshArmed = true;
      _topRefreshDragDistance = _refreshTriggerDistance;
    });
    try {
      await AppStateScope.read(context).refreshTaskFromRemote(task);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('同步远端状态失败：$error')),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _topRefreshRunning = false;
      _topRefreshArmed = false;
      _topRefreshDragDistance = 0;
    });
  }

  void _resetTopRefreshGesture() {
    if (!mounted) {
      return;
    }
    setState(() {
      _topRefreshTracking = false;
      _topRefreshArmed = false;
      _topRefreshDragDistance = 0;
    });
  }

  bool _handleTaskScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _taskPageAtTop = notification.metrics.extentBefore == 0;
    }
    return false;
  }

  void _maybeRevealAttentionAction(TaskSession task) {
    if (!_isAttentionRequired(task.status) || _isTestEnvironment) {
      return;
    }
    final signature =
        '${task.id}:${task.status.name}:${task.updatedAt.microsecondsSinceEpoch}';
    if (_handledAttentionRevealSignature == signature) {
      return;
    }
    _handledAttentionRevealSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final anchorContext = _attentionAnchorKey.currentContext;
      if (anchorContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        anchorContext,
        alignment: 0.05,
        duration: const Duration(milliseconds: 220),
      );
    });
  }

  bool get _isTestEnvironment {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('Test') || bindingName.contains('Automated');
  }

  TaskSession? _findTask(List<TaskSession> tasks) {
    for (final task in tasks) {
      if (task.id == widget.taskId) {
        return task;
      }
    }
    return null;
  }

  void _rerunTask(BuildContext context, TaskSession task) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(
          initialTaskText: task.userText,
          selectedHostId: task.host.id,
          initialProjectPath: task.host.projectPath,
        ),
      ),
    );
  }

  Future<void> _forceStopTask(BuildContext context, TaskSession task) async {
    try {
      await AppStateScope.read(context).stopTask(task);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('强制停止失败：$error')),
      );
    }
  }

  Future<void> _cleanupSession(BuildContext context, TaskSession task) async {
    try {
      await AppStateScope.read(context).cleanupRemoteSession(task);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已请求清理远端 tmux 会话。')),
        );
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理远端会话失败：$error')),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    TaskSession task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除任务?'),
          content: Text(task.displayTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && context.mounted) {
      try {
        await AppStateScope.read(context).deleteTask(task.id);
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$error')),
        );
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  bool _canDelete(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed;
  }

  bool _canForceStop(TaskSession task) {
    return task.status == TaskStatus.running ||
        task.status == TaskStatus.paused ||
        task.status == TaskStatus.needApproval ||
        task.status == TaskStatus.turnIdle ||
        task.status == TaskStatus.needAttention ||
        task.status == TaskStatus.observerDetached ||
        task.status == TaskStatus.pending;
  }

  bool _canRerun(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed ||
        task.status == TaskStatus.stopped ||
        task.status == TaskStatus.runtimeLost;
  }

  bool _canCleanupSession(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed ||
        task.status == TaskStatus.stopped ||
        task.status == TaskStatus.runtimeLost;
  }
}

class _DeliberateRefreshScrollPhysics extends AlwaysScrollableScrollPhysics {
  const _DeliberateRefreshScrollPhysics({super.parent});

  static const _dragStartThreshold = 36.0;

  @override
  double get dragStartDistanceMotionThreshold => _dragStartThreshold;

  @override
  _DeliberateRefreshScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _DeliberateRefreshScrollPhysics(parent: buildParent(ancestor));
  }
}

class _TaskHeader extends StatefulWidget {
  const _TaskHeader({required this.task});

  final TaskSession task;

  @override
  State<_TaskHeader> createState() => _TaskHeaderState();
}

class _TaskHeaderState extends State<_TaskHeader> {
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  Timer? _timer;
  bool _savingTitle = false;
  bool _editingTitle = false;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.task.title;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _TaskHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.title != widget.task.title) {
      _titleController.text = widget.task.title;
      if (!_editingTitle) {
        _titleFocusNode.unfocus();
      }
    }
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.completedAt != widget.task.completedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _titleFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_isLiveTask(widget.task)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final statusColor = _detailStatusColor(task.status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _editingTitle
                  ? TextField(
                      key: const Key('task-title-field'),
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      enabled: !_savingTitle,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      style: Theme.of(context).textTheme.titleLarge,
                      decoration: InputDecoration(
                        labelText: '标题',
                        hintText: task.displayTitle,
                        isDense: true,
                        border: const UnderlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: '保存标题',
                          icon: _savingTitle
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          onPressed: _savingTitle
                              ? null
                              : () => _saveTitle(context, task),
                        ),
                      ),
                      onSubmitted: (_) => _saveTitle(context, task),
                    )
                  : Row(
                      key: const ValueKey('task-title-display'),
                      children: [
                        Expanded(
                          child: Text(
                            task.displayTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '编辑标题',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _savingTitle
                              ? null
                              : () {
                                  setState(() => _editingTitle = true);
                                  _titleController.text = task.title;
                                  _titleController.selection =
                                      TextSelection.collapsed(
                                    offset: _titleController.text.length,
                                  );
                                  Future.microtask(() {
                                    if (mounted) {
                                      _titleFocusNode.requestFocus();
                                    }
                                  });
                                },
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MiniBadge(
                  key: const Key('runtime-control-state-badge'),
                  label: _detailStatusLabel(task.status),
                  color: statusColor,
                  animate: task.status == TaskStatus.running,
                ),
                Text(
                  _statusTimingText(task),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isLiveTask(TaskSession task) {
    return task.completedAt == null &&
        (task.status == TaskStatus.running ||
            task.status == TaskStatus.pending ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.needApproval ||
            task.status == TaskStatus.turnIdle ||
            task.status == TaskStatus.needAttention ||
            task.status == TaskStatus.observerDetached);
  }

  Future<void> _saveTitle(BuildContext context, TaskSession task) async {
    final trimmed = _titleController.text.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题不能为空。')),
      );
      _titleController.text = task.title;
      return;
    }
    if (trimmed == task.title.trim()) {
      if (mounted) {
        setState(() => _editingTitle = false);
      }
      return;
    }
    setState(() => _savingTitle = true);
    try {
      await AppStateScope.read(context).updateTaskTitle(task, trimmed);
      if (!context.mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      if (mounted) {
        setState(() => _editingTitle = false);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题已更新。')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('标题更新失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingTitle = false);
      }
    }
  }
}

class _CurrentSituationCard extends StatelessWidget {
  const _CurrentSituationCard({required this.task, this.progressSnapshot});

  final TaskSession task;
  final RuntimeTaskSnapshot? progressSnapshot;

  @override
  Widget build(BuildContext context) {
    final text = progressSnapshot != null && task.status == TaskStatus.running
        ? _progressSituationText(task, progressSnapshot!)
        : _currentSituationText(task);
    return _InfoCard(
      title: '当前状况',
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _TimelinePanel extends StatefulWidget {
  const _TimelinePanel({required this.task});

  final TaskSession task;

  @override
  State<_TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<_TimelinePanel> {
  String _cachedReadableSummary = '';
  String _cachedSignature = '';

  static String _computeSignature(TaskSession task) {
    return '${task.id}:${task.status.name}:${task.shortSummary}:'
        '${task.completedAt?.microsecondsSinceEpoch}';
  }

  static String _computeReadableSummary(TaskSession task) {
    return const SemanticSnippetBuilder()
        .build(
          const CodexOutputCleaner().clean(task.shortSummary),
          contentType: SnippetContentType.agentSummary,
          maxChars: 220,
        )
        .visibleText;
  }

  @override
  void initState() {
    super.initState();
    _cachedSignature = _computeSignature(widget.task);
    _cachedReadableSummary = _computeReadableSummary(widget.task);
  }

  @override
  void didUpdateWidget(covariant _TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSignature = _computeSignature(widget.task);
    if (newSignature != _cachedSignature) {
      _cachedSignature = newSignature;
      _cachedReadableSummary = _computeReadableSummary(widget.task);
    }
  }

  @override
  Widget build(BuildContext context) {
    final readableSummary = _cachedReadableSummary;
    final items = [
      _TimelineItem(
        icon: Icons.add_task_outlined,
        time: _timeLabel(widget.task.createdAt),
        title: '\u4efb\u52a1\u5df2\u521b\u5efa',
        subtitle: _cleanSnippet(widget.task.userText, maxChars: 120),
      ),
      _TimelineItem(
        icon: Icons.send_outlined,
        time: _timeLabel(widget.task.updatedAt),
        title: '\u5de5\u4f5c\u5df2\u5f00\u59cb',
        subtitle: '\u4ece\u4efb\u52a1\u7b80\u8ff0\u5f00\u59cb\u5de5\u4f5c',
      ),
      for (final input in _followUpVoiceInputs(widget.task))
        _TimelineItem(
          icon: Icons.add_comment_outlined,
          time: _timeLabel(input.createdAt),
          title: '\u4e0a\u4e0b\u6587\u5df2\u6dfb\u52a0',
          subtitle: _cleanSnippet(input.rawSttText, maxChars: 120),
        ),
      _TimelineItem(
        icon: _timelineResultIcon(widget.task.status),
        time: widget.task.completedAt == null
            ? '--:--'
            : _timeLabel(widget.task.completedAt!),
        title: _timelineResultTitle(widget.task.status),
        subtitle: readableSummary.isEmpty
            ? _currentSituationText(widget.task)
            : readableSummary,
        color: _timelineResultColor(widget.task.status),
      ),
    ];
    final visibleItems = items.reversed.take(3).toList(growable: false);

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: visibleItems.length + (widget.task.turns.isEmpty ? 0 : 1),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index < visibleItems.length) {
          return visibleItems[index];
        }
        return _InfoCard(
          title: '\u4efb\u52a1\u8f93\u51fa\u5386\u53f2',
          child: _TurnSummaryList(task: widget.task),
        );
      },
    );
  }

  Iterable<VoiceInput> _followUpVoiceInputs(TaskSession task) {
    final hasInitialVoice = task.rawSttText.trim().isNotEmpty &&
        task.voiceInputs.isNotEmpty &&
        task.voiceInputs.first.rawSttText.trim() == task.rawSttText.trim();
    return task.voiceInputs.skip(hasInitialVoice ? 1 : 0);
  }
}

class _TurnSummaryList extends StatelessWidget {
  const _TurnSummaryList({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final indexedTurns = [
      for (var index = 0; index < task.turns.length; index++)
        _IndexedTurn(index: index, turn: task.turns[index]),
    ]..sort((a, b) => b.turn.turnIndex.compareTo(a.turn.turnIndex));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final indexedTurn in indexedTurns)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TurnSummaryRow(
              turn: indexedTurn.turn,
              turnIndex: indexedTurn.index,
              turns: task.turns,
            ),
          ),
      ],
    );
  }
}

class _TurnSummaryRow extends StatelessWidget {
  const _TurnSummaryRow({
    required this.turn,
    required this.turnIndex,
    required this.turns,
  });

  final NativeOutputTurn turn;
  final int turnIndex;
  final List<NativeOutputTurn> turns;

  @override
  Widget build(BuildContext context) {
    final title = turn.turnIndex == 1 ? '初始任务输出' : '上下文更新输出 ${turn.turnIndex}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            _MiniBadge(
              label: _turnStatusLabel(turn.status),
              color: _turnStatusColor(turn.status),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _timeLabel(turn.startedAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          _fallback(turn.userInput, '无用户输入'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (turn.rawOutput.isNotEmpty || turn.cleanedOutput.isNotEmpty) ...[
          const SizedBox(height: 6),
          _LazyTurnOutputExpansion(
            key: ValueKey(
                '${turn.id}:${turn.lastOutputAt.microsecondsSinceEpoch}'),
            turns: turns,
            turnIndex: turnIndex,
          ),
        ],
      ],
    );
  }
}

class _LazyTurnOutputExpansion extends StatefulWidget {
  const _LazyTurnOutputExpansion({
    required this.turns,
    required this.turnIndex,
    super.key,
  });

  final List<NativeOutputTurn> turns;
  final int turnIndex;

  @override
  State<_LazyTurnOutputExpansion> createState() =>
      _LazyTurnOutputExpansionState();
}

class _LazyTurnOutputExpansionState extends State<_LazyTurnOutputExpansion> {
  static const _turnOutputSlicer = TurnOutputSlicer();

  bool _expanded = false;
  String? _fullOutput;

  @override
  void didUpdateWidget(covariant _LazyTurnOutputExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turns != widget.turns ||
        oldWidget.turnIndex != widget.turnIndex) {
      _fullOutput = _expanded ? _buildFullOutput() : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 4),
      title: const Text('显示原始输出'),
      onExpansionChanged: (expanded) {
        setState(() {
          _expanded = expanded;
          _fullOutput = expanded ? _buildFullOutput() : null;
        });
      },
      children: [
        if (_expanded)
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              _fallback(_fullOutput ?? '', '无'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  String _buildFullOutput() {
    return _turnOutputSlicer.rawOutputForTurn(
      widget.turns,
      widget.turnIndex,
    );
  }
}

enum _VoicePlaybackState { idle, playing, paused }

class _IndexedTurn {
  const _IndexedTurn({required this.index, required this.turn});

  final int index;
  final NativeOutputTurn turn;
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.icon,
    required this.time,
    required this.title,
    required this.subtitle,
    this.color,
  });

  final IconData icon;
  final String time;
  final String title;
  final String subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(time, style: Theme.of(context).textTheme.bodySmall),
        ),
        Icon(icon, size: 20, color: color ?? ArminTheme.ink),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultPanel extends StatefulWidget {
  const _ResultPanel({
    required this.task,
    required this.revealLatestTurnToken,
    required this.resultVersion,
  });

  final TaskSession task;
  final int revealLatestTurnToken;
  final int resultVersion;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  static const _turnOutputSlicer = TurnOutputSlicer();
  static const _foldLineLimit = 20;

  final GlobalKey _topAnchorKey = GlobalKey();
  Future<List<_TurnOutputSummary>>? _summariesFuture;
  int _handledRevealToken = 0;

  String? _activeVoiceCardId;
  _VoicePlaybackState _voicePlaybackState = _VoicePlaybackState.idle;
  VoiceService? _voiceService;

  Future<void> _onVoicePlay(String cardId, String fullOutput) async {
    final voiceService = AppStateScope.read(context).voiceService;

    if (_activeVoiceCardId != null) {
      await voiceService.stopSpeaking();
    }

    _activeVoiceCardId = cardId;
    _voicePlaybackState = _VoicePlaybackState.playing;
    setState(() {});

    final speechText = DeviceVoiceService.cleanSpeechText(fullOutput);
    try {
      await voiceService.speakSummary(speechText);
    } catch (_) {}

    if (!mounted) {
      return;
    }
    if (_activeVoiceCardId == cardId &&
        _voicePlaybackState == _VoicePlaybackState.playing) {
      _activeVoiceCardId = null;
      _voicePlaybackState = _VoicePlaybackState.idle;
      setState(() {});
    }
  }

  void _onVoicePause() {
    if (_activeVoiceCardId == null ||
        _voicePlaybackState != _VoicePlaybackState.playing) {
      return;
    }
    _voiceService?.pauseSpeaking();
    _voicePlaybackState = _VoicePlaybackState.paused;
    setState(() {});
  }

  void _onVoiceStop() {
    if (_activeVoiceCardId == null) {
      return;
    }
    _voiceService?.stopSpeaking();
    _activeVoiceCardId = null;
    _voicePlaybackState = _VoicePlaybackState.idle;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _voiceService = AppStateScope.of(context).voiceService;
    _summariesFuture ??= _outputSummaries(widget.task);
    _maybeRevealLatestTurn();
  }

  @override
  void dispose() {
    _disposeVoiceCoordinator();
    super.dispose();
  }

  void _disposeVoiceCoordinator() {
    if (_activeVoiceCardId != null) {
      _voiceService?.stopSpeaking();
      _activeVoiceCardId = null;
      _voicePlaybackState = _VoicePlaybackState.idle;
    }
  }

  @override
  void didUpdateWidget(covariant _ResultPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final deepChanged = oldWidget.resultVersion != widget.resultVersion;
    if (deepChanged &&
        (oldWidget.task.id != widget.task.id ||
            oldWidget.task.summary != widget.task.summary ||
            oldWidget.task.result?.summary != widget.task.result?.summary ||
            _turnsSignature(oldWidget.task) != _turnsSignature(widget.task))) {
      _summariesFuture = _outputSummaries(widget.task);
    }
    if (oldWidget.revealLatestTurnToken != widget.revealLatestTurnToken) {
      _maybeRevealLatestTurn();
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.task.result;
    return ListView(
      key: const PageStorageKey<String>('task-detail-result-list'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
      children: [
        SizedBox(key: _topAnchorKey, height: 0),
        _InfoCard(
          title: '结果 / 产出',
          trailing: Text(
            '点击播放/暂停 · 长按终止',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.45),
                ),
          ),
          child: FutureBuilder<List<_TurnOutputSummary>>(
            future: _summariesFuture,
            builder: (context, snapshot) {
              final outputs = snapshot.data ?? const [];
              if (outputs.isEmpty) {
                return const Text('暂无结果');
              }
              return Column(
                children: [
                  for (final output in outputs)
                    _OutputSegmentCard(
                      title: output.title,
                      text: output.text,
                      speechText: output.speechText,
                      fullOutputForSpeech: output.fullOutputForSpeech,
                      foldLineLimit: _foldLineLimit,
                      cardId: output.title,
                      voicePlaybackState: _activeVoiceCardId == output.title
                          ? _voicePlaybackState
                          : _VoicePlaybackState.idle,
                      onVoicePlay: _onVoicePlay,
                      onVoicePause: _onVoicePause,
                      onVoiceStop: _onVoiceStop,
                    ),
                ],
              );
            },
          ),
        ),
        if (_hasAnyDetails(result))
          _InfoCard(
            title: '产出详情',
            child: _ResultDetailsSection(
              changedFiles: result?.changedFiles ?? const [],
              validation: result?.validation ?? const [],
              risks: result?.risks ?? const [],
              nextActions: result?.nextActions ?? const [],
            ),
          ),
      ],
    );
  }

  bool _hasAnyDetails(TaskResult? result) {
    if (result == null) return false;
    return _sectionHasContent(result.changedFiles) ||
        _sectionHasContent(result.validation) ||
        _sectionHasContent(result.risks) ||
        _sectionHasContent(result.nextActions);
  }

  bool _sectionHasContent(List<String> values) {
    return values.any((v) {
      final trimmed = v.trim();
      return trimmed.isNotEmpty &&
          trimmed != '-' &&
          trimmed != '\u65e0' &&
          trimmed != 'None';
    });
  }

  Future<List<_TurnOutputSummary>> _outputSummaries(TaskSession task) async {
    final provider = AppStateScope.of(context).outputSummaryProvider;
    final summaries = <_TurnOutputSummary>[];
    final indexedTurns = [
      for (var index = 0; index < task.turns.length; index++)
        _IndexedTurn(index: index, turn: task.turns[index]),
    ]..sort((a, b) => b.turn.turnIndex.compareTo(a.turn.turnIndex));
    for (final indexedTurn in indexedTurns) {
      final index = indexedTurn.index;
      final turn = indexedTurn.turn;
      if (!_isResultTurn(turn.status)) {
        continue;
      }
      final cleanedOutput = _turnOutputSlicer.outputForTurn(task.turns, index);
      final summary = await provider.summarize(
        OutputSummaryRequest(
          cleanedOutput: cleanedOutput,
          status: task.status,
          taskTitle: task.title,
          promptInputs: [turn.userInput],
          agentCommand: task.host.agentCommand,
        ),
      );
      final text = summary.displaySummary.trim();
      final speechText = summary.speechSummary.trim().isNotEmpty
          ? summary.speechSummary.trim()
          : DeviceVoiceService.cleanSpeechText(text);
      if (text.isNotEmpty) {
        summaries.add(
          _TurnOutputSummary(
            title: _deliverableTitle(turn.turnIndex, summaries.isEmpty),
            text: text,
            speechText: speechText,
            fullOutputForSpeech: text,
          ),
        );
      }
    }
    if (summaries.isNotEmpty) {
      return summaries;
    }
    final explicitResult = _explicitResultSummary(task);
    if (explicitResult.isEmpty) {
      return const [];
    }
    final resultSummary = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: explicitResult,
        status: task.status,
        taskTitle: task.title,
        promptInputs: [task.userText],
        agentCommand: task.host.agentCommand,
      ),
    );
    final text = resultSummary.displaySummary.trim();
    return text.isEmpty
        ? const []
        : [
            _TurnOutputSummary(
              title: '结果',
              text: text,
              speechText: resultSummary.speechSummary.trim().isNotEmpty
                  ? resultSummary.speechSummary.trim()
                  : DeviceVoiceService.cleanSpeechText(text),
              fullOutputForSpeech: text,
            ),
          ];
  }

  bool _isResultTurn(NativeOutputTurnStatus status) {
    return switch (status) {
      NativeOutputTurnStatus.needAttention => false,
      NativeOutputTurnStatus.running ||
      NativeOutputTurnStatus.turnIdle ||
      NativeOutputTurnStatus.runtimeLost ||
      NativeOutputTurnStatus.failed ||
      NativeOutputTurnStatus.completedByUser ||
      NativeOutputTurnStatus.failedByUser ||
      NativeOutputTurnStatus.stopped =>
        true,
    };
  }

  void _maybeRevealLatestTurn() {
    if (widget.revealLatestTurnToken == _handledRevealToken) {
      return;
    }
    _handledRevealToken = widget.revealLatestTurnToken;
    _scheduleScrollToTop();
  }

  void _scheduleScrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final anchorContext = _topAnchorKey.currentContext;
      if (anchorContext != null) {
        Scrollable.ensureVisible(
          anchorContext,
          alignment: 0,
          duration: Duration.zero,
        );
      }
    });
  }

  String _turnsSignature(TaskSession task) {
    return task.turns
        .map((t) => '${t.turnIndex}:${t.status.name}:'
            '${t.rawOutput.hashCode}:${t.lastOutputAt.microsecondsSinceEpoch}')
        .join('|');
  }

  String _explicitResultSummary(TaskSession task) {
    return const CodexOutputCleaner().clean(task.result?.summary ?? '').trim();
  }
}

String _deliverableTitle(int turnIndex, bool isLatest) {
  if (isLatest) {
    return '摘要';
  }
  return '摘要 $turnIndex';
}

class _ResultDetailsSection extends StatefulWidget {
  const _ResultDetailsSection({
    required this.changedFiles,
    required this.validation,
    required this.risks,
    required this.nextActions,
  });

  final List<String> changedFiles;
  final List<String> validation;
  final List<String> risks;
  final List<String> nextActions;

  @override
  State<_ResultDetailsSection> createState() => _ResultDetailsSectionState();
}

class _ResultDetailsSectionState extends State<_ResultDetailsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final allEmpty = _sectionIsEmpty(widget.changedFiles) &&
        _sectionIsEmpty(widget.validation) &&
        _sectionIsEmpty(widget.risks) &&
        _sectionIsEmpty(widget.nextActions);
    if (allEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          label: Text(_expanded ? '收起非输出内容' : '展开非输出内容'),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            children: [
              _DetailList(
                title: '变更文件',
                values: widget.changedFiles,
              ),
              _DetailList(
                title: '验证结果',
                values: widget.validation,
              ),
              _DetailList(
                title: '潜在风险',
                values: widget.risks,
              ),
              _DetailList(
                title: '下一步',
                values: widget.nextActions,
              ),
            ],
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        ),
      ],
    );
  }

  bool _sectionIsEmpty(List<String> values) {
    return values.isEmpty ||
        values.every((v) {
          final trimmed = v.trim();
          return trimmed.isEmpty ||
              trimmed == '-' ||
              trimmed == '无' ||
              trimmed == 'None';
        });
  }
}

class _TurnOutputSummary {
  const _TurnOutputSummary({
    required this.title,
    required this.text,
    this.speechText = '',
    required this.fullOutputForSpeech,
  });

  final String title;
  final String text;
  final String speechText;
  final String fullOutputForSpeech;
}

class _OutputSegmentCard extends StatefulWidget {
  const _OutputSegmentCard({
    required this.title,
    required this.text,
    required this.speechText,
    required this.fullOutputForSpeech,
    required this.foldLineLimit,
    required this.cardId,
    required this.voicePlaybackState,
    required this.onVoicePlay,
    required this.onVoicePause,
    required this.onVoiceStop,
  });

  final String title;
  final String text;
  final String speechText;
  final String fullOutputForSpeech;
  final int foldLineLimit;
  final String cardId;
  final _VoicePlaybackState voicePlaybackState;
  final Future<void> Function(String cardId, String fullOutput) onVoicePlay;
  final VoidCallback onVoicePause;
  final VoidCallback onVoiceStop;

  @override
  State<_OutputSegmentCard> createState() => _OutputSegmentCardState();
}

class _OutputSegmentCardState extends State<_OutputSegmentCard> {
  bool _outputExpanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final needsFolding = lines.length > widget.foldLineLimit;
    final displayText = (needsFolding && !_outputExpanded)
        ? lines.take(widget.foldLineLimit).join('\n')
        : widget.text;

    final voiceButton = _buildVoiceButton();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAF8),
          border: Border.all(color: ArminTheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  voiceButton,
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(displayText),
              if (needsFolding) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _outputExpanded = !_outputExpanded);
                    },
                    icon: Icon(
                      _outputExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    label: Text(
                      _outputExpanded ? '隐藏原始输出' : '显示原始输出',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceButton() {
    final state = widget.voicePlaybackState;

    final IconData icon;
    final String tooltip;
    final VoidCallback onTap;
    final VoidCallback? onLongPress;

    switch (state) {
      case _VoicePlaybackState.idle:
        icon = Icons.volume_up_outlined;
        tooltip = '朗读这段输出';
        onTap = () => _onPlay();
        onLongPress = null;
      case _VoicePlaybackState.playing:
        icon = Icons.pause_outlined;
        tooltip = '暂停朗读（长按停止）';
        onTap = () => widget.onVoicePause();
        onLongPress = () => widget.onVoiceStop();
      case _VoicePlaybackState.paused:
        icon = Icons.play_arrow_outlined;
        tooltip = '继续朗读（长按停止）';
        onTap = () => _onPlay();
        onLongPress = () => widget.onVoiceStop();
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 24),
          ),
        ),
      ),
    );
  }

  void _onPlay() {
    final speechSource = widget.fullOutputForSpeech.isNotEmpty
        ? widget.fullOutputForSpeech
        : (widget.speechText.isNotEmpty ? widget.speechText : widget.text);
    widget.onVoicePlay(widget.cardId, speechSource);
  }
}

class _DetailList extends StatelessWidget {
  const _DetailList({required this.title, required this.values});

  final String title;
  final List<String> values;

  static bool _isEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ||
        trimmed == '-' ||
        trimmed == '无' ||
        trimmed == 'None';
  }

  bool get _allEmpty => values.every(_isEmpty);

  @override
  Widget build(BuildContext context) {
    if (_allEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _BulletList(values: values),
          ],
        ),
      ),
    );
  }
}

class _TaskNeedsPanel extends StatefulWidget {
  const _TaskNeedsPanel({
    required this.task,
    required this.onViewResult,
  });

  final TaskSession task;
  final VoidCallback onViewResult;

  @override
  State<_TaskNeedsPanel> createState() => _TaskNeedsPanelState();
}

class _TaskNeedsPanelState extends State<_TaskNeedsPanel> {
  static const _voiceCommandProcessor = VoiceTaskCommandProcessor();
  static const _turnOutputSlicer = TurnOutputSlicer();

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final nextAction = _nextActionForTask(task.status);
    return _InfoCard(
      title: '这个任务需要什么',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(nextAction.icon, color: nextAction.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nextAction.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      nextAction.description,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_pendingApproval(task) != null) ...[
            _ApprovalPromptCard(
              approval: _pendingApproval(task)!,
              onApprove: () => _runControlAction(
                context,
                () => AppStateScope.read(context)
                    .resolveApproval(task, approved: true),
              ),
              onReject: () => _runControlAction(
                context,
                () => AppStateScope.read(context)
                    .resolveApproval(task, approved: false),
              ),
              onVoice: () => _showFollowUpSheet(
                context,
                title: '审批处理',
                hintText: '说“批准”或“拒绝”',
                approval: _pendingApproval(task),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (task.terminalPrompt != null &&
              _pendingApproval(task) == null) ...[
            _TerminalPromptCard(
              prompt: task.terminalPrompt!,
              onSelect: (option) => _selectTerminalPromptOption(
                context,
                task,
                option,
              ),
              onVoice: () => _showFollowUpSheet(
                context,
                title: '选择终端选项',
                hintText: _terminalPromptVoiceHint(task.terminalPrompt!),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _PrimaryTaskActionButton(
            task: task,
            onAddContext: () => _showFollowUpSheet(context),
            onViewResult: widget.onViewResult,
            onResume: () => _runControlAction(
              context,
              () => AppStateScope.read(context).resumeTask(task),
            ),
            onMarkCompleted: () => _runControlAction(
              context,
              () => AppStateScope.read(context).markTaskCompleted(task),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runControlAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('运行控制失败：$error')),
      );
    }
  }

  Future<void> _selectTerminalPromptOption(
    BuildContext context,
    TaskSession task,
    TerminalPromptOption option,
  ) async {
    final needsText = _optionNeedsManualInput(option);
    final customResponse =
        needsText ? await _askTerminalPromptResponse(context, option) : null;
    if (!context.mounted || (needsText && customResponse == null)) {
      return;
    }
    await _runControlAction(
      context,
      () => AppStateScope.read(context).selectTerminalOption(
        task,
        option,
        customResponse: customResponse ?? '',
      ),
    );
  }

  bool _optionNeedsManualInput(TerminalPromptOption option) {
    final label = option.label.toLowerCase();
    return label.contains('type something') ||
        label.contains('input') ||
        label.contains('message') ||
        label.contains('输入') ||
        label.contains('填写') ||
        label.contains('补充');
  }

  String _terminalPromptVoiceHint(TerminalPrompt prompt) {
    final labels = prompt.options
        .where((option) => !_optionNeedsManualInput(option))
        .map((option) => _readableOptionLabel(option))
        .where((label) => label.isNotEmpty)
        .take(3)
        .toList(growable: false);
    if (labels.isEmpty) {
      return '说出要选择的编号，或直接说明要输入的内容';
    }
    final quoted = labels.map((label) => '“$label”').toList(growable: false);
    final examples = quoted.length == 1
        ? quoted.single
        : '${quoted.take(quoted.length - 1).join('、')}或${quoted.last}';
    final hasManualInput = prompt.options.any(_optionNeedsManualInput);
    return hasManualInput ? '说$examples，或说“输入内容”' : '说$examples';
  }

  String _readableOptionLabel(TerminalPromptOption option) {
    final label = option.label.trim();
    if (label.isNotEmpty) {
      return label;
    }
    return '选 ${option.key}';
  }

  Future<String?> _askTerminalPromptResponse(
    BuildContext context,
    TerminalPromptOption option,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _TerminalPromptResponseDialog(option: option),
    );
  }

  ApprovalRequest? _pendingApproval(TaskSession task) {
    for (final approval in task.approvalRequests) {
      if (_isPendingApproval(approval.status)) {
        return approval;
      }
    }
    if (task.approval != null && _isPendingApproval(task.approval!.status)) {
      return task.approval;
    }
    return null;
  }

  bool _isPendingApproval(String status) {
    return status.trim().toLowerCase() == 'pending';
  }

  void _showFollowUpSheet(
    BuildContext context, {
    String title = '继续任务',
    String hintText = '接下来需要做什么？',
    ApprovalRequest? approval,
  }) {
    AddContextSheet.show(
      context,
      task: widget.task,
      title: title,
      hintText: hintText,
      approval: approval,
      interpretVoiceCommand: _voiceCommandProcessor.interpret,
      onSubmit: (sheetContext, instruction, command) async {
        if (command == null) {
          await AppStateScope.read(sheetContext).sendFollowUp(
            widget.task,
            instruction,
          );
          return;
        }
        await _runVoiceCommand(sheetContext, command);
      },
    );
  }

  Future<void> _runVoiceCommand(
    BuildContext context,
    VoiceTaskCommandResult command,
  ) {
    final state = AppStateScope.read(context);
    return switch (command.action) {
      VoiceTaskAction.sendInstruction => state.sendFollowUp(
          widget.task,
          command.instruction,
          addedConstraints: command.constraints,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.stopTask =>
        state.stopTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.markCompleted => state.markTaskCompleted(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.resumeTask =>
        state.resumeTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.reconnectObserver => state.reconnectTask(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.selectTerminalOption => state.selectTerminalOption(
          widget.task,
          TerminalPromptOption(
            key: command.terminalOptionKey ?? '',
            label: command.label,
          ),
        ),
      VoiceTaskAction.readResult => _speakLatestResult(context),
      VoiceTaskAction.resolveApprovalRequest => state.resolveApproval(
          widget.task,
          approved: command.approvalApproved ?? false),
    };
  }

  Future<void> _speakLatestResult(BuildContext context) async {
    final state = AppStateScope.read(context);
    final text = await _latestResultSpeechText(context, widget.task);
    if (text.isEmpty) {
      throw const VoiceUnavailableException('没有可朗读的结果内容');
    }
    await state.voiceService.speakSummary(text);
  }

  Future<String> _latestResultSpeechText(
    BuildContext context,
    TaskSession task,
  ) async {
    final provider = AppStateScope.of(context).outputSummaryProvider;
    final latestResult = _latestResultTurn(task);
    if (latestResult != null) {
      final latestIndex = latestResult.index;
      final latestTurn = latestResult.turn;
      final summary = await provider.summarize(
        OutputSummaryRequest(
          cleanedOutput:
              _turnOutputSlicer.outputForTurn(task.turns, latestIndex),
          status: task.status,
          taskTitle: task.title,
          promptInputs: [latestTurn.userInput],
          agentCommand: task.host.agentCommand,
        ),
      );
      final latestText = summary.displaySummary.trim();
      if (latestText.isNotEmpty) {
        final speechText = summary.speechSummary.trim();
        return speechText.isNotEmpty
            ? speechText
            : DeviceVoiceService.cleanSpeechText(latestText);
      }
    }

    final explicitResult = _explicitResultSummary(task);
    if (explicitResult.isEmpty) {
      return '';
    }
    final resultSummary = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: explicitResult,
        status: task.status,
        taskTitle: task.title,
        promptInputs: [task.userText],
        agentCommand: task.host.agentCommand,
      ),
    );
    final resultText = resultSummary.displaySummary.trim();
    if (resultText.isEmpty) {
      return '';
    }
    final speechText = resultSummary.speechSummary.trim();
    return speechText.isNotEmpty
        ? speechText
        : DeviceVoiceService.cleanSpeechText(resultText);
  }

  _IndexedTurn? _latestResultTurn(TaskSession task) {
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (_isReadableResultTurn(turn.status)) {
        return _IndexedTurn(index: index, turn: turn);
      }
    }
    return null;
  }

  bool _isReadableResultTurn(NativeOutputTurnStatus status) {
    return switch (status) {
      NativeOutputTurnStatus.needAttention ||
      NativeOutputTurnStatus.running =>
        false,
      NativeOutputTurnStatus.turnIdle ||
      NativeOutputTurnStatus.runtimeLost ||
      NativeOutputTurnStatus.failed ||
      NativeOutputTurnStatus.completedByUser ||
      NativeOutputTurnStatus.failedByUser ||
      NativeOutputTurnStatus.stopped =>
        true,
    };
  }

  String _explicitResultSummary(TaskSession task) {
    return const CodexOutputCleaner().clean(task.result?.summary ?? '').trim();
  }
}

class _AddContextEntry extends StatelessWidget {
  const _AddContextEntry({
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: const Icon(Icons.add_comment_outlined),
      label: const Text('向此任务添加上下文'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        alignment: Alignment.centerLeft,
      ),
    );
  }
}

class _AddContextPanel extends StatefulWidget {
  const _AddContextPanel({required this.task});

  final TaskSession task;

  @override
  State<_AddContextPanel> createState() => _AddContextPanelState();
}

class _AddContextPanelState extends State<_AddContextPanel> {
  static const _voiceCommandProcessor = VoiceTaskCommandProcessor();

  @override
  Widget build(BuildContext context) {
    final enabled = _runtimeControlStateFromTask(widget.task.status) !=
            RuntimeControlState.stopped ||
        widget.task.status == TaskStatus.runtimeLost;
    return _InfoCard(
      title: '添加上下文',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '向此任务添加上下文',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          _AddContextEntry(
            enabled: enabled,
            onPressed: () => _showFollowUpSheet(context),
          ),
        ],
      ),
    );
  }

  void _showFollowUpSheet(BuildContext context) {
    AddContextSheet.show(
      context,
      task: widget.task,
      title: '向此任务添加上下文',
      hintText: '添加约束、决定或后续指令...',
      interpretVoiceCommand: _voiceCommandProcessor.interpret,
      onSubmit: (sheetContext, instruction, command) async {
        if (command == null) {
          await AppStateScope.read(sheetContext).sendFollowUp(
            widget.task,
            instruction,
          );
          return;
        }
        await _runVoiceCommand(sheetContext, command);
      },
    );
  }

  Future<void> _runVoiceCommand(
    BuildContext context,
    VoiceTaskCommandResult command,
  ) {
    final state = AppStateScope.read(context);
    return switch (command.action) {
      VoiceTaskAction.sendInstruction => state.sendFollowUp(
          widget.task,
          command.instruction,
          addedConstraints: command.constraints,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.stopTask =>
        state.stopTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.markCompleted => state.markTaskCompleted(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.resumeTask =>
        state.resumeTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.reconnectObserver => state.reconnectTask(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.selectTerminalOption => state.selectTerminalOption(
          widget.task,
          TerminalPromptOption(
            key: command.terminalOptionKey ?? '',
            label: command.label,
          ),
        ),
      VoiceTaskAction.readResult => _speakLatestResult(context),
      VoiceTaskAction.resolveApprovalRequest => state.resolveApproval(
          widget.task,
          approved: command.approvalApproved ?? false),
    };
  }

  Future<void> _speakLatestResult(BuildContext context) async {
    await AppStateScope.read(context).speakTaskSummary(widget.task);
  }
}

class _PrimaryTaskActionButton extends StatelessWidget {
  const _PrimaryTaskActionButton({
    required this.task,
    required this.onAddContext,
    required this.onViewResult,
    required this.onResume,
    required this.onMarkCompleted,
  });

  final TaskSession task;
  final VoidCallback onAddContext;
  final VoidCallback onViewResult;
  final VoidCallback onResume;
  final VoidCallback onMarkCompleted;

  @override
  Widget build(BuildContext context) {
    final action = _primaryTaskActionFor(task.status);
    if (action == null) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: switch (action.kind) {
          _PrimaryTaskActionKind.addContext => onAddContext,
          _PrimaryTaskActionKind.viewResult => onViewResult,
          _PrimaryTaskActionKind.resume => onResume,
          _PrimaryTaskActionKind.markCompleted => onMarkCompleted,
        },
        icon: Icon(action.icon),
        label: Text(action.label),
      ),
    );
  }
}

enum _PrimaryTaskActionKind {
  addContext,
  viewResult,
  resume,
  markCompleted,
}

class _PrimaryTaskAction {
  const _PrimaryTaskAction({
    required this.label,
    required this.icon,
    required this.kind,
  });

  final String label;
  final IconData icon;
  final _PrimaryTaskActionKind kind;
}

class _ApprovalPromptCard extends StatelessWidget {
  const _ApprovalPromptCard({
    required this.approval,
    required this.onApprove,
    required this.onReject,
    required this.onVoice,
  });

  final ApprovalRequest approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Text(
                '任务确认',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            approval.reason,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            approval.command,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),
          Text(
            '风险：${approval.risk}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_outlined),
                label: const Text('允许'),
              ),
              OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_outlined),
                label: const Text('拒绝'),
              ),
              TextButton.icon(
                onPressed: onVoice,
                icon: const Icon(Icons.mic_none_outlined),
                label: const Text('语音处理'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalPromptCard extends StatelessWidget {
  const _TerminalPromptCard({
    required this.prompt,
    required this.onSelect,
    required this.onVoice,
  });

  final TerminalPrompt prompt;
  final ValueChanged<TerminalPromptOption> onSelect;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final command = prompt.command.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pause_circle_outline, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  prompt.question,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton.filledTonal(
                tooltip: '语音选择',
                icon: const Icon(Icons.mic_none_outlined, size: 18),
                onPressed: onVoice,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (command.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              command,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade800,
                    fontFamily: 'monospace',
                  ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in prompt.options)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  avatar: Text(option.key),
                  label: Text(option.label),
                  onPressed: () => onSelect(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalPromptResponseDialog extends StatefulWidget {
  const _TerminalPromptResponseDialog({required this.option});

  final TerminalPromptOption option;

  @override
  State<_TerminalPromptResponseDialog> createState() =>
      _TerminalPromptResponseDialogState();
}

class _TerminalPromptResponseDialogState
    extends State<_TerminalPromptResponseDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    return AlertDialog(
      title: Text('${option.key}. ${option.label}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: '输入要发送给远端 CLI 的内容',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) {
              return;
            }
            Navigator.of(context).pop(text);
          },
          child: const Text('发送'),
        ),
      ],
    );
  }
}

class _AdvancedDebugPanel extends StatefulWidget {
  const _AdvancedDebugPanel({required this.task});

  final TaskSession task;

  @override
  State<_AdvancedDebugPanel> createState() => _AdvancedDebugPanelState();
}

class _AdvancedDebugPanelState extends State<_AdvancedDebugPanel> {
  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final controlState = _runtimeControlStateFromTask(task.status);
    final canResolveRuntimeLost = task.status == TaskStatus.runtimeLost;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '高级控制',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ControlButton(
                icon: Icons.check_circle_outline,
                label: '标记完成',
                tone: ControlTone.neutral,
                onPressed: (controlState == RuntimeControlState.stopped ||
                            controlState == RuntimeControlState.detached) &&
                        !canResolveRuntimeLost
                    ? null
                    : () => _runControlAction(
                          context,
                          () => AppStateScope.read(context)
                              .markTaskCompleted(task),
                        ),
              ),
              _ControlButton(
                icon: Icons.report_gmailerrorred_outlined,
                label: '标记失败',
                tone: ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped &&
                        !canResolveRuntimeLost
                    ? null
                    : () => _runControlAction(
                          context,
                          () =>
                              AppStateScope.read(context).markTaskFailed(task),
                        ),
              ),
              _ControlButton(
                icon: Icons.not_interested_outlined,
                label: '中断',
                tone: ControlTone.danger,
                onPressed: task.turns.isNotEmpty &&
                        task.turns.last.status ==
                            NativeOutputTurnStatus.running
                    ? () => _runControlAction(
                          context,
                          () => AppStateScope.read(context)
                              .interruptTask(task),
                        )
                    : null,
              ),
              _ControlButton(
                icon: Icons.stop_rounded,
                label: '停止',
                tone: ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped
                    ? null
                    : () => _runControlAction(
                          context,
                          () => AppStateScope.read(context).stopTask(task),
                        ),
              ),
              _ControlButton(
                icon: controlState == RuntimeControlState.detached
                    ? Icons.sensors_outlined
                    : Icons.link_off_outlined,
                label: controlState == RuntimeControlState.detached
                    ? '重新监听'
                    : '断开监听',
                tone: controlState == RuntimeControlState.detached
                    ? ControlTone.neutral
                    : ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped
                    ? null
                    : () => _runControlAction(
                          context,
                          () => controlState == RuntimeControlState.detached
                              ? AppStateScope.read(context)
                                  .reconnectTask(task)
                              : AppStateScope.read(context)
                                  .disconnectTask(task),
                        ),
              ),
            ],
          ),
        ),
        _InfoCard(
          title: '调试命令',
          child: SelectableText(
            'tmux attach -t ${task.host.tmuxSessionName}\n'
            'tmux capture-pane -p -t ${task.host.tmuxSessionName} -S -200',
          ),
        ),
        _InfoCard(
          title: '审批历史',
          child: task.approvalRequests.isEmpty && task.approval == null
              ? const Text('无')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final approval in task.approvalRequests.isEmpty
                        ? [task.approval!]
                        : task.approvalRequests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              'reason: ${approval.reason}\n'
                              'command: ${approval.command}\n'
                              'risk: ${approval.risk}\n'
                              'status: ${approval.status}',
                            ),
                            const SizedBox(height: 10),
                            if (_isPendingApproval(approval.status))
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.read(context)
                                              .resolveApproval(task,
                                                  approved: true);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已允许，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.check_outlined),
                                    label: const Text('允许'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.read(context)
                                              .resolveApproval(task,
                                                  approved: false);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已拒绝，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.close_outlined),
                                    label: const Text('拒绝'),
                                  ),
                                ],
                              )
                            else
                              _MiniBadge(
                                label: _approvalStatusLabel(approval.status),
                                color: _approvalStatusColor(approval.status),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        _InfoCard(
          title: '指标',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '指标渲染已暂停',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                '任务仍在记录必要的运行指标，但此页面默认不渲染指标节点。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _isPendingApproval(String status) {
    return status.trim().toLowerCase() == 'pending';
  }

  String _approvalStatusLabel(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => '已允许',
      'rejected' => '已拒绝',
      final value when value.isNotEmpty => value,
      _ => '已处理',
    };
  }

  Color _approvalStatusColor(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => Colors.green.shade700,
      'rejected' => Colors.red.shade700,
      _ => Colors.grey.shade700,
    };
  }

  Future<void> _runControlAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('运行控制失败：$error')),
      );
    }
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (trailing != null)
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: trailing!,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TabBarHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TabBarHeaderDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.centerLeft,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarHeaderDelegate oldDelegate) {
    return oldDelegate.tabBar != tabBar;
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Text('无');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('- $value'),
          ),
      ],
    );
  }
}

class _MiniBadge extends StatefulWidget {
  const _MiniBadge({
    required this.label,
    required this.color,
    this.animate = false,
    super.key,
  });

  final String label;
  final Color color;
  final bool animate;

  @override
  State<_MiniBadge> createState() => _MiniBadgeState();
}

class _MiniBadgeState extends State<_MiniBadge> with TickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _MiniBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate ||
        oldWidget.color != widget.color) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.animate && !_isTestEnvironment) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1600),
      )..repeat();
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  bool get _isTestEnvironment {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('Test') || bindingName.contains('Automated');
  }

  @override
  Widget build(BuildContext context) {
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          widget.label,
          style: TextStyle(color: widget.color, fontSize: 12),
        ),
      ),
    );
    if (_controller == null) {
      return pill;
    }
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _CometBadgePainter(
          color: widget.color,
          animation: _controller!,
        ),
        child: pill,
      ),
    );
  }
}

class _CometBadgePainter extends CustomPainter {
  _CometBadgePainter({
    required this.color,
    required Animation<double> animation,
  }) : super(repaint: animation) {
    _animation = animation;
  }

  final Color color;
  late final Animation<double> _animation;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = _animation.value;
    final center = Offset(size.width / 2, size.height / 2);
    final radiusX = math.max(20, size.width / 2 + 5);
    final radiusY = math.max(12, size.height / 2 + 4);
    final angle = progress * math.pi * 2;

    for (var i = 4; i >= 0; i--) {
      final t = i / 4;
      final trailAngle = angle - t * 0.62;
      final dotCenter = Offset(
        center.dx + math.cos(trailAngle) * radiusX,
        center.dy + math.sin(trailAngle) * radiusY,
      );
      final alpha = math.max(0.08, 0.92 - i * 0.19);
      final radius = math.max(1.8, 4.2 - t * 2.3);
      final glowPaint = Paint()
        ..color = color.withValues(alpha: alpha * 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawCircle(dotCenter, radius + 2, glowPaint);

      final dotPaint = Paint()..color = color.withValues(alpha: alpha);
      canvas.drawCircle(dotCenter, radius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CometBadgePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate._animation != _animation;
  }
}

enum RuntimeControlState {
  active,
  paused,
  detached,
  stopped,
}

class _NextAction {
  const _NextAction({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color color;
}

String _detailStatusLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.draft || TaskStatus.pending => '等待开始',
    TaskStatus.running => '进行中',
    TaskStatus.paused => '已暂停',
    TaskStatus.stopped => '已停止',
    TaskStatus.needApproval => '需要你决定',
    TaskStatus.turnIdle => '等待你的下一步指令',
    TaskStatus.needAttention => '需要你关注',
    TaskStatus.observerDetached => '更新已暂停',
    TaskStatus.runtimeLost => '连接已暂停',
    TaskStatus.userCompleted || TaskStatus.completed => '可查看',
    TaskStatus.userFailed || TaskStatus.failed => '需要查看',
  };
}

Color _detailStatusColor(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention =>
      Colors.orange.shade700,
    TaskStatus.running || TaskStatus.pending => ArminTheme.primary,
    TaskStatus.paused ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      Colors.blueGrey.shade700,
    TaskStatus.failed || TaskStatus.userFailed => Colors.red.shade700,
    TaskStatus.completed || TaskStatus.userCompleted => Colors.green.shade700,
    TaskStatus.draft || TaskStatus.stopped => Colors.grey.shade700,
  };
}

String _statusTimingText(TaskSession task) {
  if (task.completedAt != null) {
    return '更新于 ${_timeLabel(task.completedAt!)}';
  }
  if (_isTaskLive(task.status)) {
    final startedAt = task.startedAt ?? task.createdAt;
    return '${_elapsedLabel(DateTime.now().difference(startedAt))} 持续中';
  }
  return '更新于 ${_timeLabel(task.updatedAt)}';
}

String _elapsedLabel(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m';
  }
  return '刚刚';
}

bool _isTaskLive(TaskStatus status) {
  return switch (status) {
    TaskStatus.pending ||
    TaskStatus.running ||
    TaskStatus.paused ||
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.observerDetached =>
      true,
    TaskStatus.draft ||
    TaskStatus.stopped ||
    TaskStatus.runtimeLost ||
    TaskStatus.userCompleted ||
    TaskStatus.userFailed ||
    TaskStatus.completed ||
    TaskStatus.failed =>
      false,
  };
}

bool _isAttentionRequired(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.paused ||
    TaskStatus.failed ||
    TaskStatus.userFailed =>
      true,
    _ => false,
  };
}

String _cleanSnippet(String value, {int maxChars = 160}) {
  final cleaned = const CodexOutputCleaner().clean(value);
  return const SemanticSnippetBuilder()
      .build(
        cleaned,
        contentType: SnippetContentType.agentSummary,
        maxChars: maxChars,
      )
      .visibleText
      .trim();
}

String _currentSituationText(TaskSession task) {
  final hasOutput = _hasMeaningfulOutput(task);
  return switch (task.status) {
    TaskStatus.turnIdle => hasOutput
        ? '最新结果已就绪。\n'
            '等待你的下一步指令。'
        : '此任务正在等待你的下一步指令才能继续。',
    TaskStatus.needAttention when task.terminalPrompt != null => hasOutput
        ? '最新结果已就绪。\n'
            '从下方选项中选择如何继续。'
        : '此任务正在等待你的选择才能继续。',
    TaskStatus.needAttention => hasOutput
        ? '最新结果已就绪。\n'
            '给出你的下一步指令、约束或决定。'
        : '此任务需要你的关注才能继续推进。',
    TaskStatus.needApproval => hasOutput
        ? '任务发现了需要你决定的事项。\n'
            '批准或拒绝以继续。'
        : '此任务正在等待你的决定才能继续。',
    TaskStatus.failed || TaskStatus.userFailed => '此任务遇到了问题，需要查看后才能继续。',
    TaskStatus.paused => '此任务已暂停。\n准备好后恢复它。',
    TaskStatus.running || TaskStatus.pending => '此任务仍在工作中。\n当前不需要任何操作。',
    TaskStatus.completed || TaskStatus.userCompleted => '最新结果已就绪，可供查看。',
    TaskStatus.runtimeLost => '更新已暂停。\n如需继续观察此任务，请重新连接。',
    TaskStatus.observerDetached => '更新已暂停。\n任务可能仍在远端运行。',
    TaskStatus.stopped => '此任务已停止。\n查看输出，或根据需要启动新运行。',
    TaskStatus.draft => '此任务尚未启动。',
  };
}

bool _hasMeaningfulOutput(TaskSession task) {
  if (task.shortSummary.isNotEmpty &&
      const CodexOutputCleaner().clean(task.shortSummary).trim().isNotEmpty) {
    return true;
  }
  if (task.result?.summary != null &&
      const CodexOutputCleaner()
          .clean(task.result!.summary)
          .trim()
          .isNotEmpty) {
    return true;
  }
  if (task.turns.isNotEmpty) {
    return true;
  }
  return false;
}

String _progressSituationText(TaskSession task, RuntimeTaskSnapshot snapshot) {
  final action = snapshot.action.isNotEmpty ? '动作: ${snapshot.action}。' : '';
  final progress = snapshot.progress > 0 ? '进度 ${snapshot.progress}%' : '';
  final parts = [action, progress].where((p) => p.isNotEmpty);
  if (parts.isEmpty) return _currentSituationText(task);
  return '此任务仍在工作中。${parts.join('，')}。'
      '\n当前不需要任何操作。';
}

_NextAction _nextActionForTask(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => _NextAction(
        title: '需要你决定',
        description: '选择此任务是否可以继续执行提议的操作。',
        icon: Icons.rule_outlined,
        color: Colors.orange.shade700,
      ),
    TaskStatus.turnIdle || TaskStatus.needAttention => _NextAction(
        title: '需要你的指令',
        description: '发送下一步指令、约束或决定。',
        icon: Icons.add_comment_outlined,
        color: Colors.orange.shade700,
      ),
    TaskStatus.running || TaskStatus.pending => const _NextAction(
        title: '当前无需操作',
        description: '任务仍在推进。你可以让它继续运行或暂停它。',
        icon: Icons.play_circle_outline,
        color: ArminTheme.primary,
      ),
    TaskStatus.completed || TaskStatus.userCompleted => _NextAction(
        title: '可查看',
        description: '检查交付成果，然后接受或继续添加上下文。',
        icon: Icons.fact_check_outlined,
        color: Colors.green.shade700,
      ),
    TaskStatus.failed || TaskStatus.userFailed => _NextAction(
        title: '需要查看',
        description: '检查发生的情况，并决定是否从此处继续。',
        icon: Icons.error_outline,
        color: Colors.red.shade700,
      ),
    TaskStatus.paused => _NextAction(
        title: '已暂停',
        description: '准备好后恢复此任务。',
        icon: Icons.pause_circle_outline,
        color: Colors.blueGrey.shade700,
      ),
    TaskStatus.observerDetached => _NextAction(
        title: '需要时重新连接',
        description: '更新已暂停。继续前请重新连接或查看详情。',
        icon: Icons.wifi_off_outlined,
        color: Colors.blueGrey.shade700,
      ),
    TaskStatus.runtimeLost => _NextAction(
        title: '连接已暂停',
        description: '远端会话不再可用。准备好后处理任务状态。',
        icon: Icons.task_alt_outlined,
        color: Colors.blueGrey.shade700,
      ),
    TaskStatus.draft => _NextAction(
        title: '准备任务',
        description: '此任务尚未启动。',
        icon: Icons.edit_note_outlined,
        color: Colors.grey.shade700,
      ),
    TaskStatus.stopped => _NextAction(
        title: '查看详情',
        description: '此任务已停止。查看历史记录或启动新运行。',
        icon: Icons.stop_circle_outlined,
        color: Colors.grey.shade700,
      ),
  };
}

_PrimaryTaskAction? _primaryTaskActionFor(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => const _PrimaryTaskAction(
        label: '查看',
        icon: Icons.rule_outlined,
        kind: _PrimaryTaskActionKind.addContext,
      ),
    TaskStatus.turnIdle || TaskStatus.needAttention => const _PrimaryTaskAction(
        label: '继续',
        icon: Icons.add_comment_outlined,
        kind: _PrimaryTaskActionKind.addContext,
      ),
    TaskStatus.failed || TaskStatus.userFailed => const _PrimaryTaskAction(
        label: '查看问题',
        icon: Icons.error_outline,
        kind: _PrimaryTaskActionKind.viewResult,
      ),
    TaskStatus.completed ||
    TaskStatus.userCompleted =>
      const _PrimaryTaskAction(
        label: '查看结果',
        icon: Icons.fact_check_outlined,
        kind: _PrimaryTaskActionKind.viewResult,
      ),
    TaskStatus.paused => const _PrimaryTaskAction(
        label: '恢复',
        icon: Icons.play_arrow_outlined,
        kind: _PrimaryTaskActionKind.resume,
      ),
    TaskStatus.runtimeLost => const _PrimaryTaskAction(
        label: '标记完成',
        icon: Icons.check_circle_outline,
        kind: _PrimaryTaskActionKind.markCompleted,
      ),
    TaskStatus.running ||
    TaskStatus.pending ||
    TaskStatus.draft ||
    TaskStatus.stopped ||
    TaskStatus.observerDetached =>
      null,
  };
}

extension RuntimeControlStateLabel on RuntimeControlState {
  String get label {
    return switch (this) {
      RuntimeControlState.active => '运行中',
      RuntimeControlState.paused => '已暂停',
      RuntimeControlState.detached => '已断开监听',
      RuntimeControlState.stopped => '已停止',
    };
  }

  Color get color {
    return switch (this) {
      RuntimeControlState.active => ArminTheme.primary,
      RuntimeControlState.paused => Colors.orange,
      RuntimeControlState.detached => Colors.blueGrey,
      RuntimeControlState.stopped => Colors.red,
    };
  }
}

RuntimeControlState _runtimeControlStateFromTask(TaskStatus status) {
  return switch (status) {
    TaskStatus.paused => RuntimeControlState.paused,
    TaskStatus.stopped ||
    TaskStatus.runtimeLost ||
    TaskStatus.userCompleted ||
    TaskStatus.userFailed ||
    TaskStatus.completed ||
    TaskStatus.failed =>
      RuntimeControlState.stopped,
    TaskStatus.observerDetached => RuntimeControlState.detached,
    TaskStatus.draft ||
    TaskStatus.pending ||
    TaskStatus.running ||
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention =>
      RuntimeControlState.active,
  };
}

enum ControlTone {
  neutral,
  danger,
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final ControlTone tone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = tone == ControlTone.danger ? Colors.red : ArminTheme.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.26)),
      ),
    );
  }
}

String _fallback(String value, String fallback) {
  return value.trim().isEmpty ? fallback : value;
}

String _timeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _timelineResultTitle(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => '需要你决定',
    TaskStatus.turnIdle => '等待你的下一步',
    TaskStatus.needAttention => '等待你的输入',
    TaskStatus.observerDetached => '更新已暂停',
    TaskStatus.runtimeLost => '连接已暂停',
    TaskStatus.failed || TaskStatus.userFailed => '发现问题',
    TaskStatus.completed || TaskStatus.userCompleted => '工作已完成',
    TaskStatus.running || TaskStatus.pending => '工作进行中',
    TaskStatus.paused => '任务已暂停',
    TaskStatus.stopped => '已停止',
    TaskStatus.draft => '草稿已创建',
  };
}

IconData _timelineResultIcon(TaskStatus status) {
  return switch (status) {
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost =>
      Icons.error_outline,
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.needApproval ||
    TaskStatus.observerDetached =>
      Icons.pause_circle_outline,
    _ => Icons.check_circle_outline,
  };
}

Color _timelineResultColor(TaskStatus status) {
  return switch (status) {
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost =>
      Colors.red,
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.needApproval ||
    TaskStatus.observerDetached =>
      Colors.orange,
    _ => ArminTheme.ink,
  };
}

String _turnStatusLabel(NativeOutputTurnStatus status) {
  return switch (status) {
    NativeOutputTurnStatus.running => 'Working',
    NativeOutputTurnStatus.turnIdle => 'Waiting',
    NativeOutputTurnStatus.needAttention => 'Needs input',
    NativeOutputTurnStatus.runtimeLost => 'Connection paused',
    NativeOutputTurnStatus.failed => 'Needs review',
    NativeOutputTurnStatus.completedByUser => 'Ready to review',
    NativeOutputTurnStatus.failedByUser => 'Marked failed',
    NativeOutputTurnStatus.stopped => 'Stopped',
  };
}

Color _turnStatusColor(NativeOutputTurnStatus status) {
  return switch (status) {
    NativeOutputTurnStatus.running => ArminTheme.primary,
    NativeOutputTurnStatus.turnIdle => Colors.teal,
    NativeOutputTurnStatus.needAttention => Colors.orange,
    NativeOutputTurnStatus.runtimeLost => Colors.red,
    NativeOutputTurnStatus.failed => Colors.red,
    NativeOutputTurnStatus.completedByUser => Colors.green,
    NativeOutputTurnStatus.failedByUser => Colors.red,
    NativeOutputTurnStatus.stopped => Colors.red,
  };
}
