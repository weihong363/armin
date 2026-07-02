import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../core/services/armin_app_state.dart';
import '../../../shared/line_noise_filter.dart';
import '../../../shared/scroll/armin_scroll_behavior.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../../hosts/models/host_config.dart';
import '../../projects/models/project_path_config.dart';
import '../../runtime/models/approval_state.dart';
import '../../runtime/models/runtime_task_snapshot.dart';
import '../../runtime/models/work_state.dart';
import '../../runtime/services/runtime_event_bus.dart';
import '../../tasks/models/native_output_turn.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/models/voice_input.dart';
import '../../tasks/screens/task_draft_screen.dart';
import '../../tasks/services/semantic_snippet_builder.dart';
import '../../tasks/services/turn_output_slicer.dart';
import '../../tasks/services/voice_task_command_processor.dart';
import '../../tasks/widgets/add_context_sheet.dart';
import '../../voice/services/device_voice_service.dart';
import '../../voice/services/voice_service.dart';

enum _TaskDetailAction {
  rerun,
  forceStop,
  cleanupSession,
  delete,
}

const _taskDetailTabScrollPhysics = ClampingScrollPhysics();
const _recentPreviewCacheLimit = 3;
const _timelineCacheLimit = 12;

final _recentPreviewCache = <String, String>{};
final _timelineCache = <String, _TimelineViewModel>{};

String? _cachedRecentPreview(String signature) {
  return _recentPreviewCache[signature];
}

void _cacheRecentPreview(String signature, String preview) {
  _recentPreviewCache[signature] = preview;
  while (_recentPreviewCache.length > _recentPreviewCacheLimit) {
    _recentPreviewCache.remove(_recentPreviewCache.keys.first);
  }
}

_TimelineViewModel? _cachedTimeline(String signature) {
  return _timelineCache[signature];
}

void _cacheTimeline(String signature, _TimelineViewModel model) {
  _timelineCache[signature] = model;
  while (_timelineCache.length > _timelineCacheLimit) {
    _timelineCache.remove(_timelineCache.keys.first);
  }
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
  static const _dragUpdateThreshold = 4.0;

  late final TabController _tabController =
      TabController(length: 3, vsync: this);
  final _attentionAnchorKey = GlobalKey();
  int _latestTurnRevealToken = 0;
  String _handledAttentionRevealSignature = '';

  StreamSubscription<RuntimeEvent>? _eventSubscription;
  final int _resultVersion = 0;
  final ValueNotifier<RuntimeTaskSnapshot?> _progressNotifier =
      ValueNotifier<RuntimeTaskSnapshot?>(null);

  bool _taskPageAtTop = true;
  bool _topRefreshTracking = false;
  bool _topRefreshArmed = false;
  bool _topRefreshRunning = false;
  double _topRefreshDragDistance = 0;
  double _lastTopRefreshPaintDistance = 0;
  final ValueNotifier<int> _visibleTabIndexNotifier = ValueNotifier<int>(0);
  ArminAppState? _appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController.addListener(_handleTabChanged);
    final state = AppStateScope.read(context);
    _appState = state;
    _eventSubscription = state.runtimeEvents.listen(_onRuntimeEvent);
    state.setActiveDetailTaskId(widget.taskId);
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _progressNotifier.dispose();
    _visibleTabIndexNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _appState?.voiceService.stopSpeaking();
    _appState?.clearActiveDetailTaskId();
    super.dispose();
  }

  void _handleTabChanged() {
    final nextIndex = _tabController.index;
    if (_visibleTabIndexNotifier.value == nextIndex || !mounted) {
      return;
    }
    _visibleTabIndexNotifier.value = nextIndex;
  }

  void _selectTab(int index) {
    if (!mounted || index < 0 || index >= _tabController.length) {
      return;
    }
    if (_visibleTabIndexNotifier.value != index) {
      _visibleTabIndexNotifier.value = index;
    }
    if (_tabController.index != index) {
      _tabController.index = index;
      return;
    }
    final animationValue = _tabController.animation?.value;
    final isSettled =
        animationValue == null || (animationValue - index).abs() < 0.001;
    if (!_tabController.indexIsChanging && !isSettled) {
      _tabController.offset = 0;
    }
  }

  Widget _detailTab(String label, int index) {
    return Tab(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _selectTab(index),
        child: Center(child: Text(label)),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Do not auto-jump to the result tab on resume. Runtime/output updates can
    // arrive while the user is scrolling or switching tabs; only explicit user
    // actions should reveal the result tab.
  }

  void _revealLatestResult() {
    if (!mounted) {
      return;
    }
    setState(() {
      _latestTurnRevealToken++;
    });
    _selectTab(_resultTabIndex);
  }

  void _onRuntimeEvent(RuntimeEvent event) {
    if (event.taskId != widget.taskId || !mounted) {
      return;
    }
    if (event.type == RuntimeEventType.taskProgress && event.snapshot != null) {
      _progressNotifier.value = event.snapshot;
      return;
    }
    if (event.type == RuntimeEventType.taskCompleted ||
        event.type == RuntimeEventType.taskFailed ||
        event.type == RuntimeEventType.taskCancelled ||
        event.type == RuntimeEventType.taskStopped ||
        event.type == RuntimeEventType.taskWaitingUser ||
        event.type == RuntimeEventType.taskPaused) {
      _progressNotifier.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskListenable = AppStateScope.read(context).taskListenable(
      widget.taskId,
    );
    return ValueListenableBuilder<TaskSession?>(
      valueListenable: taskListenable,
      builder: (context, task, _) {
        return _buildTaskScaffold(context, task);
      },
    );
  }

  Widget _buildTaskScaffold(BuildContext context, TaskSession? task) {
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }
    final workState = _effectiveWorkStateFor(
      task,
      AppStateScope.read(context).workState(task.id),
    );
    _maybeRevealAttentionAction(task, workState);

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
                    physics: const ArminScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    headerSliverBuilder: (context, innerBoxIsScrolled) => [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: _TaskHeader(
                            task: task,
                            workState: workState,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: ValueListenableBuilder<RuntimeTaskSnapshot?>(
                            valueListenable: _progressNotifier,
                            builder: (context, progressSnapshot, _) {
                              return _CurrentSituationCard(
                                task: task,
                                workState: workState,
                                progressSnapshot: progressSnapshot,
                              );
                            },
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: KeyedSubtree(
                            key: _attentionAnchorKey,
                            child: _TaskNeedsPanel(
                              task: task,
                              workState: workState,
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
                            onTap: _selectTab,
                            isScrollable: false,
                            labelColor: ArminTheme.ink,
                            indicatorColor: ArminTheme.primary,
                            tabs: [
                              _detailTab('动态', 0),
                              _detailTab('产出', 1),
                              _detailTab('高级', 2),
                            ],
                          ),
                        ),
                      ),
                    ],
                    body: ValueListenableBuilder<int>(
                      valueListenable: _visibleTabIndexNotifier,
                      builder: (context, visibleTabIndex, _) {
                        return _CurrentTaskTabPanel(
                          key: ValueKey<String>(
                            'task-detail-tab-body-${task.id}',
                          ),
                          index: visibleTabIndex,
                          task: task,
                          revealLatestTurnToken: _latestTurnRevealToken,
                          resultVersion: _resultVersion,
                        );
                      },
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
    _lastTopRefreshPaintDistance = 0;
    _topRefreshArmed = false;
  }

  void _handleTopRefreshPointerMove(PointerMoveEvent event) {
    if (!_topRefreshTracking || event.delta.dy <= 0) {
      return;
    }
    final nextDistance = _topRefreshDragDistance + event.delta.dy;
    final wasArmed = _topRefreshArmed;
    final nextArmed = nextDistance >= _refreshTriggerDistance;
    final movedEnough = (nextDistance - _lastTopRefreshPaintDistance).abs() >=
        _dragUpdateThreshold;
    if (!movedEnough && wasArmed == nextArmed) {
      _topRefreshDragDistance = nextDistance;
      return;
    }
    setState(() {
      _topRefreshDragDistance = nextDistance;
      _lastTopRefreshPaintDistance = nextDistance;
      _topRefreshArmed = nextArmed;
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
      _lastTopRefreshPaintDistance = _refreshTriggerDistance;
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
      _lastTopRefreshPaintDistance = 0;
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
      _lastTopRefreshPaintDistance = 0;
    });
  }

  bool _handleTaskScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _taskPageAtTop = notification.metrics.extentBefore == 0;
    }
    return false;
  }

  bool get _isTestEnvironment {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('Test') || bindingName.contains('Automated');
  }

  void _maybeRevealAttentionAction(TaskSession task, WorkState? workState) {
    if (!_isAttentionRequired(workState) || _isTestEnvironment) {
      return;
    }
    final signature = '${task.id}:${_workPhaseName(workState)}:'
        '${task.updatedAt.microsecondsSinceEpoch}';
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

  void _rerunTask(BuildContext context, TaskSession task) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(
          initialTaskText: task.userText,
          initialTaskTitle: task.title,
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
    return switch (task.status) {
      TaskStatus.completed ||
      TaskStatus.failed ||
      TaskStatus.userCompleted ||
      TaskStatus.userFailed ||
      TaskStatus.stopped ||
      TaskStatus.runtimeLost =>
        true,
      _ => false,
    };
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

class _CurrentTaskTabPanel extends StatelessWidget {
  const _CurrentTaskTabPanel({
    super.key,
    required this.index,
    required this.task,
    required this.revealLatestTurnToken,
    required this.resultVersion,
  });

  final int index;
  final TaskSession task;
  final int revealLatestTurnToken;
  final int resultVersion;

  @override
  Widget build(BuildContext context) {
    return switch (index) {
      0 => _TimelinePanel(task: task),
      1 => _ResultPanel(
          task: task,
          revealLatestTurnToken: revealLatestTurnToken,
          resultVersion: resultVersion,
        ),
      _ => _AdvancedDebugPanel(task: task),
    };
  }
}

class _TaskHeader extends StatefulWidget {
  const _TaskHeader({
    required this.task,
    required this.workState,
  });

  final TaskSession task;
  final WorkState? workState;

  @override
  State<_TaskHeader> createState() => _TaskHeaderState();
}

class _TaskHeaderState extends State<_TaskHeader> {
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  bool _savingTitle = false;
  bool _editingTitle = false;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.task.title;
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
  }

  @override
  void dispose() {
    _titleFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final statusColor = _detailStatusColor(task.status, widget.workState);
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
                        hintText: '输入任务标题',
                        hintStyle:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.22),
                                ),
                        isDense: true,
                        border: const UnderlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _titleController,
                              builder: (context, value, _) {
                                if (value.text.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return IconButton(
                                  tooltip: '清除标题',
                                  icon: const Icon(Icons.close),
                                  onPressed: _savingTitle
                                      ? null
                                      : () {
                                          _titleController.clear();
                                        },
                                );
                              },
                            ),
                            IconButton(
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
                          ],
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
                  label: _detailStatusLabel(task.status, widget.workState),
                  color: statusColor,
                  animate: _workPhaseFor(widget.workState, task.status) ==
                      WorkPhase.working,
                ),
                _TaskTimingText(task: task),
                GestureDetector(
                  onTap: () => _showHostEditor(context, task),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 14,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${task.host.name}  ·  ${task.host.projectPath}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.55),
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveTitle(BuildContext context, TaskSession task) async {
    final trimmed = _titleController.text.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题不能为空。')),
      );
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

  Future<void> _showHostEditor(BuildContext context, TaskSession task) async {
    final appState = AppStateScope.read(context);
    final hosts = appState.hosts;

    final result = await showDialog<HostConfig>(
      context: context,
      builder: (ctx) => _HostEditDialog(
        currentHost: task.host,
        hosts: hosts,
        projectPaths: appState.projectPaths,
      ),
    );

    if (result == null || !mounted || !context.mounted) {
      return;
    }

    // Show confirmation dialog before applying the change.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认变更主机/项目'),
        content: Text(
          '将任务「${task.displayTitle}」的\n'
          '主机变更为「${result.name}」，\n'
          '项目路径变更为「${result.projectPath}」？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted || !context.mounted) {
      return;
    }

    try {
      await appState.updateTaskHost(task, result);
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('主机/项目已更新。')),
        );
      }
    } catch (error) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('主机/项目更新失败：$error')),
        );
      }
    }
  }
}

class _HostEditDialog extends StatefulWidget {
  const _HostEditDialog({
    required this.currentHost,
    required this.hosts,
    required this.projectPaths,
  });

  final HostConfig currentHost;
  final List<HostConfig> hosts;
  final List<ProjectPathConfig> projectPaths;

  @override
  State<_HostEditDialog> createState() => _HostEditDialogState();
}

class _HostEditDialogState extends State<_HostEditDialog> {
  late String _selectedHostId;
  late String _selectedProjectPathId;

  @override
  void initState() {
    super.initState();
    _selectedHostId = widget.currentHost.id;
    final currentPath = widget.currentHost.projectPath;
    final matched =
        widget.projectPaths.where((p) => p.path == currentPath).firstOrNull;
    _selectedProjectPathId = matched?.id ?? '';
  }

  String get _selectedProjectPath =>
      widget.projectPaths
          .where((p) => p.id == _selectedProjectPathId)
          .firstOrNull
          ?.path ??
      widget.currentHost.projectPath;

  HostConfig _buildResultHost() {
    final selectedHost = widget.hosts.firstWhere(
      (h) => h.id == _selectedHostId,
      orElse: () => widget.currentHost,
    );
    return selectedHost.copyWith(
      projectPath: _selectedProjectPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑主机/项目'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedHostId,
              decoration: const InputDecoration(
                labelText: '主机',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: widget.hosts.map((host) {
                return DropdownMenuItem(
                  value: host.id,
                  child: Text(
                    host.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedHostId = value);
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selectedProjectPathId,
              decoration: const InputDecoration(
                labelText: '项目路径',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: widget.projectPaths.map((pp) {
                return DropdownMenuItem(
                  value: pp.id,
                  child: Text(
                    pp.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedProjectPathId = value);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _buildResultHost()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _TaskTimingText extends StatefulWidget {
  const _TaskTimingText({required this.task});

  final TaskSession task;

  @override
  State<_TaskTimingText> createState() => _TaskTimingTextState();
}

class _TaskTimingTextState extends State<_TaskTimingText>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _TaskTimingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.completedAt != widget.task.completedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) {
      return;
    }
    _appActive = active;
    _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_appActive &&
        TickerMode.valuesOf(context).enabled &&
        _isLiveTask(widget.task)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _statusTimingText(widget.task),
      style: Theme.of(context).textTheme.bodySmall,
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
}

class _CurrentSituationCard extends StatelessWidget {
  const _CurrentSituationCard({
    required this.task,
    required this.workState,
    this.progressSnapshot,
  });

  final TaskSession task;
  final WorkState? workState;
  final RuntimeTaskSnapshot? progressSnapshot;

  @override
  Widget build(BuildContext context) {
    final text = progressSnapshot != null &&
            _workPhaseFor(workState, task.status) == WorkPhase.working
        ? _progressSituationText(task, progressSnapshot!)
        : _currentSituationText(task, workState);
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
  String _cachedSignature = '';
  late _TimelineViewModel _viewModel;

  static String _computeSignature(TaskSession task) {
    return '${task.id}:${task.status.name}:${task.shortSummary}:'
        '${task.updatedAt.microsecondsSinceEpoch}:'
        '${task.completedAt?.microsecondsSinceEpoch}:'
        '${task.voiceInputs.length}:${task.turns.length}';
  }

  static _TimelineViewModel _timelineViewModelFor(TaskSession task) {
    final signature = _computeSignature(task);
    final cached = _cachedTimeline(signature);
    if (cached != null) {
      return cached;
    }
    final readableSummary = const SemanticSnippetBuilder()
        .build(
          const AgentOutputCleaner().clean(task.shortSummary),
          contentType: SnippetContentType.agentSummary,
          maxChars: 220,
        )
        .visibleText;
    final allItems = [
      _TimelineItemData(
        icon: Icons.add_task_outlined,
        time: _timeLabel(task.createdAt),
        title: '任务已创建',
        subtitle: _cleanSnippet(task.userText, maxChars: 120),
      ),
      _TimelineItemData(
        icon: Icons.send_outlined,
        time: _timeLabel(task.updatedAt),
        title: '工作已开始',
        subtitle: '从任务简述开始工作',
      ),
      for (final input in _followUpVoiceInputsFor(task))
        _TimelineItemData(
          icon: Icons.add_comment_outlined,
          time: _timeLabel(input.createdAt),
          title: '上下文已添加',
          subtitle: _cleanSnippet(input.rawSttText, maxChars: 120),
        ),
      _TimelineItemData(
        icon: _timelineResultIcon(task.status),
        time:
            task.completedAt == null ? '--:--' : _timeLabel(task.completedAt!),
        title: _timelineResultTitle(task.status),
        subtitle: readableSummary.isEmpty
            ? _currentSituationText(task)
            : readableSummary,
        color: _timelineResultColor(task.status),
      ),
    ];
    final model = _TimelineViewModel(
      visibleItems: allItems.reversed.take(3).toList(growable: false),
      hasTurns: task.turns.isNotEmpty,
    );
    _cacheTimeline(signature, model);
    return model;
  }

  @override
  void initState() {
    super.initState();
    _cachedSignature = _computeSignature(widget.task);
    _viewModel = _timelineViewModelFor(widget.task);
  }

  @override
  void didUpdateWidget(covariant _TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSignature = _computeSignature(widget.task);
    if (newSignature != _cachedSignature) {
      _cachedSignature = newSignature;
      _viewModel = _timelineViewModelFor(widget.task);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key:
          PageStorageKey<String>('task-detail-timeline-list-${widget.task.id}'),
      physics: _taskDetailTabScrollPhysics,
      padding: const EdgeInsets.all(20),
      itemCount: _viewModel.visibleItems.length + (_viewModel.hasTurns ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index < _viewModel.visibleItems.length) {
          return _TimelineItem.fromData(_viewModel.visibleItems[index]);
        }
        return _InfoCard(
          title: '\u4efb\u52a1\u8f93\u51fa\u5386\u53f2',
          child: _TurnSummaryList(task: widget.task),
        );
      },
    );
  }

  static Iterable<VoiceInput> _followUpVoiceInputsFor(TaskSession task) {
    final hasInitialVoice = task.rawSttText.trim().isNotEmpty &&
        task.voiceInputs.isNotEmpty &&
        task.voiceInputs.first.rawSttText.trim() == task.rawSttText.trim();
    return task.voiceInputs.skip(hasInitialVoice ? 1 : 0);
  }
}

class _TurnSummaryList extends StatefulWidget {
  const _TurnSummaryList({required this.task});

  final TaskSession task;

  @override
  State<_TurnSummaryList> createState() => _TurnSummaryListState();
}

class _TurnSummaryListState extends State<_TurnSummaryList> {
  static const _collapsedTurnCount = 3;

  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _TurnSummaryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final indexedTurns = [
      for (var index = 0; index < widget.task.turns.length; index++)
        _IndexedTurn(index: index, turn: widget.task.turns[index]),
    ]..sort((a, b) => b.turn.turnIndex.compareTo(a.turn.turnIndex));
    final hiddenCount = indexedTurns.length - _collapsedTurnCount;
    final visibleTurns = _expanded
        ? indexedTurns
        : indexedTurns.take(_collapsedTurnCount).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final indexedTurn in visibleTurns)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TurnSummaryRow(
              turn: indexedTurn.turn,
              turnIndex: indexedTurn.index,
              turns: widget.task.turns,
            ),
          ),
        if (!_expanded && hiddenCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text('查看全部 $hiddenCount 条更早输出'),
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
      key: PageStorageKey<String>(
        'turn-output-expansion-${widget.turns[widget.turnIndex].id}',
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 4),
      title: const Text('显示原始输出'),
      onExpansionChanged: (expanded) {
        // Defer setState — ExpansionTile may fire this during initState
        // (PageStorage restoration) while the framework is still building.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _expanded = expanded;
            _fullOutput = expanded ? _buildFullOutput() : null;
          });
        });
      },
      children: [
        if (_expanded)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              key: PageStorageKey<String>(
                'turn-output-text-${widget.turns[widget.turnIndex].id}',
              ),
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

  factory _TimelineItem.fromData(_TimelineItemData data) {
    return _TimelineItem(
      icon: data.icon,
      time: data.time,
      title: data.title,
      subtitle: data.subtitle,
      color: data.color,
    );
  }

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
  static const _foldLineLimit = 20;
  static const _recentOutputWindowChars = 12000;
  static const _recentOutputLineLimit = 80;
  static const _recentOutputPreviewLineLimit = 30;
  static const _summaryPageSize = 3;

  final GlobalKey _topAnchorKey = GlobalKey();
  Future<List<_TurnOutputSummary>>? _summariesFuture;
  Future<String>? _recentPreviewFuture;
  String _summarySignature = '';
  String _recentPreviewSignature = '';
  bool _summaryScheduled = false;
  bool _recentPreviewScheduled = false;
  int _handledRevealToken = 0;
  int _visibleSummaryCount = _summaryPageSize;

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
    _voiceService = AppStateScope.read(context).voiceService;
    _syncResultWork();
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
    if (deepChanged ||
        oldWidget.task.id != widget.task.id ||
        oldWidget.task.summary != widget.task.summary ||
        oldWidget.task.shortSummary != widget.task.shortSummary ||
        _turnsSignature(oldWidget.task) != _turnsSignature(widget.task)) {
      if (oldWidget.task.id != widget.task.id ||
          _turnsSignature(oldWidget.task) != _turnsSignature(widget.task)) {
        _visibleSummaryCount = _summaryPageSize;
      }
      _syncResultWork(force: deepChanged);
    }
    if (oldWidget.revealLatestTurnToken != widget.revealLatestTurnToken) {
      _maybeRevealLatestTurn();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const PageStorageKey<String>('task-detail-result-list'),
      physics: _taskDetailTabScrollPhysics,
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
          child: _shouldBuildResultSummary(widget.task)
              ? _buildResultSummary()
              : _buildRecentOutputPreview(),
        ),
      ],
    );
  }

  Future<List<_TurnOutputSummary>> _outputSummaries(
    TaskSession task,
    String signature,
  ) async {
    await Future<void>.delayed(Duration.zero);
    final summaries = <_TurnOutputSummary>[];
    final indexedTurns = _resultTurns(task, limit: _visibleSummaryCount);
    for (var visibleIndex = 0;
        visibleIndex < indexedTurns.length;
        visibleIndex += 1) {
      final indexedTurn = indexedTurns[visibleIndex];
      final turn = indexedTurn.turn;
      final deliverable = turn.deliverable;
      if (deliverable == null) continue;
      final text = deliverable.displaySummary.trim();
      final speechText = deliverable.speechSummary.trim().isNotEmpty
          ? deliverable.speechSummary.trim()
          : DeviceVoiceService.cleanSpeechText(text);
      if (text.isNotEmpty) {
        summaries.add(
          _TurnOutputSummary(
            title: _deliverableTitle(turn.turnIndex, visibleIndex == 0),
            text: text,
            speechText: speechText,
            fullOutputForSpeech: speechText,
          ),
        );
      }
    }
    return summaries;
  }

  bool _isResultTurn(NativeOutputTurnStatus status) {
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

  _IndexedTurn? _latestResultTurn(TaskSession task) {
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (_isResultTurn(turn.status) && turn.deliverable != null) {
        return _IndexedTurn(index: index, turn: turn);
      }
    }
    return null;
  }

  List<_IndexedTurn> _resultTurns(TaskSession task, {required int limit}) {
    final turns = <_IndexedTurn>[];
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (_isResultTurn(turn.status) && turn.deliverable != null) {
        turns.add(_IndexedTurn(index: index, turn: turn));
        if (turns.length >= limit) {
          break;
        }
      }
    }
    return turns;
  }

  int _resultTurnCount(TaskSession task) {
    return task.turns
        .where((turn) => _isResultTurn(turn.status) && turn.deliverable != null)
        .length;
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
        .map((t) => [
              t.turnIndex,
              t.status.name,
              t.userInput.hashCode,
              t.cleanedOutput.length,
              t.rawOutput.length,
              t.lastOutputAt.microsecondsSinceEpoch,
              t.deliverable?.evidenceFingerprint ?? '',
            ].join(':'))
        .join('|');
  }

  void _syncResultWork({bool force = false}) {
    if (_shouldBuildResultSummary(widget.task)) {
      _recentPreviewFuture = null;
      _recentPreviewSignature = '';
      final signature = _resultSummarySignature(widget.task);
      if (force || _summarySignature != signature) {
        _summarySignature = signature;
        _summariesFuture = null;
        _scheduleSummaryBuild(signature);
      }
      return;
    }

    _summariesFuture = null;
    _summarySignature = '';
    final signature = _recentOutputSignature(widget.task);
    if (force || _recentPreviewSignature != signature) {
      _recentPreviewSignature = signature;
      _recentPreviewFuture = null;
      if (_cachedRecentPreview(signature) == null) {
        _scheduleRecentPreviewBuild(signature);
      }
    }
  }

  Widget _buildResultSummary() {
    final future = _summariesFuture;
    if (future == null) {
      return const Text('正在整理产出…');
    }
    return FutureBuilder<List<_TurnOutputSummary>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Text('正在整理产出…');
        }
        final outputs = snapshot.data ?? const [];
        if (outputs.isEmpty) {
          return const Text('暂无结果');
        }
        return _buildOutputSummaries(outputs);
      },
    );
  }

  Widget _buildOutputSummaries(List<_TurnOutputSummary> outputs) {
    if (outputs.isEmpty) {
      return const Text('暂无结果');
    }
    final totalResultTurns = _resultTurnCount(widget.task);
    final hasMore = totalResultTurns > outputs.length;
    final remaining = totalResultTurns - outputs.length;
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
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: OutlinedButton.icon(
              onPressed: _loadMoreSummaries,
              icon: const Icon(Icons.expand_more),
              label: Text(
                '加载更多 ${remaining >= _summaryPageSize ? _summaryPageSize : remaining} 个结果',
              ),
            ),
          ),
      ],
    );
  }

  void _loadMoreSummaries() {
    setState(() {
      _visibleSummaryCount += _summaryPageSize;
      _summarySignature = '';
      _summariesFuture = null;
    });
    _syncResultWork(force: true);
  }

  Widget _buildRecentOutputPreview() {
    final cached = _cachedRecentPreview(_recentPreviewSignature);
    if (cached != null) {
      return _RecentOutputPreview(
        text: cached,
        previewLineLimit: _recentOutputPreviewLineLimit,
      );
    }
    final future = _recentPreviewFuture;
    if (future == null) {
      return const Text('正在整理最近输出…');
    }
    return FutureBuilder<String>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Text('正在整理最近输出…');
        }
        return _RecentOutputPreview(
          text: snapshot.data ?? '',
          previewLineLimit: _recentOutputPreviewLineLimit,
        );
      },
    );
  }

  void _scheduleSummaryBuild(String signature) {
    if (_summaryScheduled) {
      return;
    }
    _summaryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_summarySignature != signature ||
          !_shouldBuildResultSummary(widget.task)) {
        _summaryScheduled = false;
        _syncResultWork();
        return;
      }
      setState(() {
        _summaryScheduled = false;
        _summariesFuture = _outputSummaries(widget.task, signature);
      });
    });
  }

  void _scheduleRecentPreviewBuild(String signature) {
    if (_recentPreviewScheduled) {
      return;
    }
    _recentPreviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_recentPreviewSignature != signature ||
          _shouldBuildResultSummary(widget.task)) {
        _recentPreviewScheduled = false;
        _syncResultWork();
        return;
      }
      setState(() {
        _recentPreviewScheduled = false;
        _recentPreviewFuture = _recentOutputPreview(widget.task, signature);
      });
    });
  }

  String _resultSummarySignature(TaskSession task) {
    final resultTurn = _latestResultTurn(task);
    return [
      task.id,
      task.status.name,
      _visibleSummaryCount,
      task.summary?.hashCode ?? 0,
      task.shortSummary.hashCode,
      if (resultTurn != null) ...[
        resultTurn.turn.id,
        resultTurn.turn.status.name,
        resultTurn.turn.deliverable?.evidenceFingerprint ?? '',
      ],
    ].join(':');
  }

  String _recentOutputSignature(TaskSession task) {
    final latest = task.turns.isEmpty ? null : task.turns.last;
    return [
      task.id,
      task.status.name,
      if (latest != null) ...[
        latest.id,
        latest.status.name,
        latest.rawOutput.length,
        latest.cleanedOutput.length,
        latest.lastOutputAt.microsecondsSinceEpoch,
      ],
    ].join(':');
  }

  bool _shouldBuildResultSummary(TaskSession task) {
    return !_usesRecentOutputPreview(task.status);
  }

  Future<String> _recentOutputPreview(
      TaskSession task, String signature) async {
    await Future<void>.delayed(Duration.zero);
    if (task.turns.isEmpty) {
      return '';
    }
    final latest = task.turns.last;
    final source = latest.rawOutput.trim().isNotEmpty
        ? latest.rawOutput
        : latest.cleanedOutput;
    if (source.trim().isEmpty) {
      return '';
    }
    final tail = _tailWindow(source, _recentOutputWindowChars);
    final cleaned = const AgentOutputCleaner().clean(tail).trim();
    if (cleaned.isEmpty) {
      return '';
    }
    final lines = cleaned
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.length <= _recentOutputLineLimit) {
      final preview = lines.join('\n');
      _cacheRecentPreview(signature, preview);
      return preview;
    }
    final preview =
        lines.skip(lines.length - _recentOutputLineLimit).join('\n');
    _cacheRecentPreview(signature, preview);
    return preview;
  }
}

String _deliverableTitle(int turnIndex, bool isLatest) {
  if (isLatest) {
    return '摘要';
  }
  return '摘要 $turnIndex';
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
              Text(displayText),
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

class _TimelineViewModel {
  const _TimelineViewModel({
    required this.visibleItems,
    required this.hasTurns,
  });

  final List<_TimelineItemData> visibleItems;
  final bool hasTurns;
}

class _TimelineItemData {
  const _TimelineItemData({
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
}

class _TaskNeedsPanel extends StatefulWidget {
  const _TaskNeedsPanel({
    required this.task,
    required this.workState,
    required this.onViewResult,
  });

  final TaskSession task;
  final WorkState? workState;
  final VoidCallback onViewResult;

  @override
  State<_TaskNeedsPanel> createState() => _TaskNeedsPanelState();
}

class _TaskNeedsPanelState extends State<_TaskNeedsPanel> {
  static const _voiceCommandProcessor = VoiceTaskCommandProcessor();

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final nextAction = _nextActionForTask(task.status, widget.workState);
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
          if (_pendingApproval() != null) ...[
            _ApprovalPromptCard(
              approval: _pendingApproval()!,
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
              onSelectOption: (option) => _selectApprovalOption(
                context,
                task,
                option,
              ),
              onVoice: () => _showFollowUpSheet(
                context,
                title: '审批处理',
                hintText: _approvalVoiceHint(_pendingApproval()!),
                approval: _pendingApproval(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _PrimaryTaskActionButton(
            task: task,
            workState: widget.workState,
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

  Future<void> _selectApprovalOption(
    BuildContext context,
    TaskSession task,
    NativeApprovalOption option,
  ) async {
    final customResponse = _approvalOptionNeedsManualInput(option)
        ? await _askApprovalOptionResponse(context, option)
        : '';
    if (!context.mounted) {
      return;
    }
    if (_approvalOptionNeedsManualInput(option) && customResponse == null) {
      return;
    }
    await _runControlAction(
      context,
      () => AppStateScope.read(context).selectTerminalOption(
        task,
        option,
        customResponse: customResponse ?? '',
        approval: _pendingApproval(),
      ),
    );
  }

  bool _approvalOptionNeedsManualInput(NativeApprovalOption option) {
    final label = option.label.toLowerCase();
    return label.contains('type something') ||
        label.contains('external editor') ||
        label.contains('modify') ||
        label.contains('输入') ||
        label.contains('编辑');
  }

  String _approvalVoiceHint(NativeTerminalApproval approval) {
    if (approval.options.isEmpty) {
      return '说“批准”或“拒绝”';
    }
    final normalOptions = approval.options
        .where((option) => !_approvalOptionNeedsManualInput(option))
        .map((option) => option.label.trim())
        .where((label) => label.isNotEmpty)
        .take(3)
        .toList(growable: false);
    final manual = approval.options.any(_approvalOptionNeedsManualInput);
    final quoted = normalOptions.map((label) => '“$label”').join('、');
    if (quoted.isEmpty) {
      return manual ? '说“输入内容”' : '说“批准”或“拒绝”';
    }
    return manual ? '说$quoted，或说“输入内容”' : '说$quoted';
  }

  Future<String?> _askApprovalOptionResponse(
    BuildContext context,
    NativeApprovalOption option,
  ) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(option.label),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '补充你希望远端执行的处理方式',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('发送'),
            ),
          ],
        );
      },
    );
  }

  NativeTerminalApproval? _pendingApproval() {
    final approval = widget.workState?.approval;
    return approval?.state == ApprovalState.pending ? approval : null;
  }

  void _showFollowUpSheet(
    BuildContext context, {
    String title = '继续任务',
    String hintText = '接下来需要做什么？',
    NativeTerminalApproval? approval,
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
          NativeApprovalOption(
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
    final text = await _latestResultSpeechText(widget.task);
    if (text.isEmpty) {
      throw const VoiceUnavailableException('没有可朗读的结果内容');
    }
    await state.voiceService.speakSummary(text);
  }

  Future<String> _latestResultSpeechText(TaskSession task) async {
    final latestResult = _latestResultTurn(task);
    final deliverable = latestResult?.turn.deliverable;
    if (deliverable == null) return '';
    final speechText = deliverable.speechSummary.trim();
    return speechText.isNotEmpty
        ? speechText
        : DeviceVoiceService.cleanSpeechText(deliverable.displaySummary);
  }

  _IndexedTurn? _latestResultTurn(TaskSession task) {
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (_isReadableResultTurn(turn.status) && turn.deliverable != null) {
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
}

class _RecentOutputPreview extends StatefulWidget {
  const _RecentOutputPreview({
    required this.text,
    required this.previewLineLimit,
  });

  final String text;
  final int previewLineLimit;

  @override
  State<_RecentOutputPreview> createState() => _RecentOutputPreviewState();
}

class _RecentOutputPreviewState extends State<_RecentOutputPreview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (text.trim().isEmpty) {
      return const Text('任务正在等待你的处理，暂无可展示的正式结果。');
    }
    final lines = text.split('\n');
    final needsExpansion = lines.length > widget.previewLineLimit;
    final previewText = needsExpansion && !_expanded
        ? lines.take(widget.previewLineLimit).join('\n')
        : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '任务正在等待你的处理。下面是最近输出，正式结果会在任务完成或进入明确结果状态后整理。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAF8),
            border: Border.all(color: ArminTheme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _expanded
                ? SelectableText(
                    previewText,
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : Text(
                    previewText,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),
        ),
        if (needsExpansion) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_expanded ? '收起最近输出' : '展开最近输出'),
            ),
          ),
        ],
      ],
    );
  }
}

bool _usesRecentOutputPreview(TaskStatus status) {
  return switch (status) {
    TaskStatus.draft ||
    TaskStatus.pending ||
    TaskStatus.running ||
    TaskStatus.paused ||
    TaskStatus.needApproval ||
    TaskStatus.needAttention ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      true,
    TaskStatus.turnIdle ||
    TaskStatus.stopped ||
    TaskStatus.userCompleted ||
    TaskStatus.userFailed ||
    TaskStatus.completed ||
    TaskStatus.failed =>
      false,
  };
}

String _tailWindow(String output, int maxChars) {
  if (output.length <= maxChars) {
    return output;
  }
  return output.substring(output.length - maxChars);
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
          NativeApprovalOption(
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
    required this.workState,
    required this.onAddContext,
    required this.onViewResult,
    required this.onResume,
    required this.onMarkCompleted,
  });

  final TaskSession task;
  final WorkState? workState;
  final VoidCallback onAddContext;
  final VoidCallback onViewResult;
  final VoidCallback onResume;
  final VoidCallback onMarkCompleted;

  @override
  Widget build(BuildContext context) {
    final action = _primaryTaskActionFor(task.status, workState);
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
    required this.onSelectOption,
    required this.onVoice,
  });

  final NativeTerminalApproval approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final ValueChanged<NativeApprovalOption> onSelectOption;
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
            approval.question,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          if (approval.options.isNotEmpty)
            Text(
              approval.options.map((option) => option.label).join(' / '),
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
              if (approval.options.isEmpty) ...[
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
              ] else
                for (final option in approval.options)
                  _ApprovalOptionButton(
                    option: option,
                    onPressed: () => onSelectOption(option),
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

class _ApprovalOptionButton extends StatelessWidget {
  const _ApprovalOptionButton({
    required this.option,
    required this.onPressed,
  });

  final NativeApprovalOption option;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = option.label.toLowerCase();
    final isPositive =
        label.contains('allow') || label.contains('approve') || label == 'yes';
    if (isPositive) {
      return FilledButton(
        onPressed: onPressed,
        child: Text(option.label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(option.label),
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
      key: PageStorageKey<String>('task-detail-advanced-list-${task.id}'),
      physics: _taskDetailTabScrollPhysics,
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
                        task.turns.last.status == NativeOutputTurnStatus.running
                    ? () => _runControlAction(
                          context,
                          () => AppStateScope.read(context).interruptTask(task),
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
                              ? AppStateScope.read(context).reconnectTask(task)
                              : AppStateScope.read(context)
                                  .disconnectTask(task),
                        ),
              ),
            ],
          ),
        ),
        _InfoCard(
          title: '调试命令',
          child: Text(
            'tmux attach -t ${task.host.tmuxSessionName}\n'
            'tmux capture-pane -p -t ${task.host.tmuxSessionName} -S -200',
          ),
        ),
        _LazyInfoCard(
          title: '审批历史',
          collapsedText: _approvalHistoryCollapsedText(task),
          builder: (context) => _approvalHistoryContent(context, task),
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

  Widget _approvalHistoryContent(BuildContext context, TaskSession task) {
    final approvals = task.nativeApprovalRequests;
    if (approvals.isEmpty) {
      return const Text('无');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final approval in approvals)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _approvalHistoryRow(context, task, approval),
          ),
      ],
    );
  }

  Widget _approvalHistoryRow(
    BuildContext context,
    TaskSession task,
    NativeTerminalApproval approval,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'question: ${approval.question}\n'
          'selected: ${approval.selectedOptionKey ?? '-'}\n'
          'status: ${approval.state.name}',
        ),
        const SizedBox(height: 10),
        if (approval.state == ApprovalState.pending)
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _resolveHistoricalApproval(
                  context,
                  task,
                  approved: true,
                ),
                icon: const Icon(Icons.check_outlined),
                label: const Text('允许'),
              ),
              OutlinedButton.icon(
                onPressed: () => _resolveHistoricalApproval(
                  context,
                  task,
                  approved: false,
                ),
                icon: const Icon(Icons.close_outlined),
                label: const Text('拒绝'),
              ),
            ],
          )
        else
          _MiniBadge(
            label: _approvalStatusLabel(approval.state),
            color: _approvalStatusColor(approval.state),
          ),
      ],
    );
  }

  Future<void> _resolveHistoricalApproval(
    BuildContext context,
    TaskSession task, {
    required bool approved,
  }) async {
    var succeeded = false;
    await _runControlAction(
      context,
      () async {
        await AppStateScope.read(context).resolveApproval(
          task,
          approved: approved,
        );
        succeeded = true;
      },
    );
    if (succeeded && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(approved ? '已允许，正在继续监听远端任务。' : '已拒绝，正在继续监听远端任务。'),
        ),
      );
    }
  }

  String _approvalHistoryCollapsedText(TaskSession task) {
    final approvals = task.nativeApprovalRequests;
    if (approvals.isEmpty) {
      return '无审批记录';
    }
    if (approvals.length == 1) {
      return _approvalStatusLabel(approvals.single.state);
    }
    return '${approvals.length} 条审批记录，点开查看';
  }

  String _approvalStatusLabel(ApprovalState status) {
    return switch (status) {
      ApprovalState.pending => '等待处理',
      ApprovalState.resolving => '处理中',
      ApprovalState.resolved => '已处理',
      ApprovalState.failed => '处理失败',
      ApprovalState.none => '无',
    };
  }

  Color _approvalStatusColor(ApprovalState status) {
    return switch (status) {
      ApprovalState.pending => Colors.orange.shade700,
      ApprovalState.resolving => ArminTheme.primary,
      ApprovalState.resolved => Colors.green.shade700,
      ApprovalState.failed => Colors.red.shade700,
      ApprovalState.none => Colors.grey.shade700,
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

class _LazyInfoCard extends StatefulWidget {
  const _LazyInfoCard({
    required this.title,
    required this.collapsedText,
    required this.builder,
  });

  final String title;
  final String collapsedText;
  final WidgetBuilder builder;

  @override
  State<_LazyInfoCard> createState() => _LazyInfoCardState();
}

class _LazyInfoCardState extends State<_LazyInfoCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_outlined
                        : Icons.expand_more_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_expanded)
                Builder(builder: widget.builder)
              else
                Text(
                  widget.collapsedText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
            ],
          ),
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

WorkPhase _workPhaseFor(WorkState? workState, [TaskStatus? status]) {
  final phase = workState?.phase;
  if (phase != null) {
    return phase;
  }
  return switch (status) {
    TaskStatus.draft || TaskStatus.pending || null => WorkPhase.idle,
    TaskStatus.running => WorkPhase.working,
    TaskStatus.paused || TaskStatus.observerDetached => WorkPhase.quieting,
    TaskStatus.turnIdle => WorkPhase.turnIdle,
    TaskStatus.needApproval => WorkPhase.needsApproval,
    TaskStatus.needAttention => WorkPhase.needsInstruction,
    TaskStatus.completed || TaskStatus.userCompleted => WorkPhase.completed,
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost =>
      WorkPhase.failed,
    TaskStatus.stopped => WorkPhase.stopped,
  };
}

WorkState? _effectiveWorkStateFor(TaskSession task, WorkState? workState) {
  return workState;
}

String _workPhaseName(WorkState? workState) {
  return _workPhaseFor(workState).name;
}

String _detailStatusLabel(TaskStatus status, [WorkState? workState]) {
  if (workState != null && workState.headline.trim().isNotEmpty) {
    return workState.headline.trim();
  }
  switch (_workPhaseFor(workState, status)) {
    case WorkPhase.idle:
      return '等待开始';
    case WorkPhase.working:
      return '进行中';
    case WorkPhase.quieting:
      return status == TaskStatus.paused ? '已暂停' : '更新已暂停';
    case WorkPhase.turnIdle:
      return '等待你的下一步指令';
    case WorkPhase.needsApproval:
      return '需要你决定';
    case WorkPhase.needsDecision:
      return '需要你决定';
    case WorkPhase.needsReview:
      return '需要查看';
    case WorkPhase.needsInstruction:
      return '需要你的指令';
    case WorkPhase.completed:
      return '可查看';
    case WorkPhase.failed:
      return '需要查看';
    case WorkPhase.stopped:
      return '已停止';
  }
}

Color _detailStatusColor(TaskStatus status, [WorkState? workState]) {
  return switch (_workPhaseFor(workState, status)) {
    WorkPhase.needsApproval ||
    WorkPhase.needsDecision ||
    WorkPhase.needsReview ||
    WorkPhase.needsInstruction ||
    WorkPhase.turnIdle =>
      Colors.orange.shade700,
    WorkPhase.working || WorkPhase.idle => ArminTheme.primary,
    WorkPhase.quieting => Colors.blueGrey.shade700,
    WorkPhase.failed => Colors.red.shade700,
    WorkPhase.completed => Colors.green.shade700,
    WorkPhase.stopped => Colors.grey.shade700,
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

bool _isAttentionRequired(WorkState? workState) {
  return workState != null &&
      (workState.needsAttention ||
          workState.phase == WorkPhase.turnIdle ||
          workState.phase == WorkPhase.failed);
}

String _cleanSnippet(String value, {int maxChars = 160}) {
  final cleaned = const AgentOutputCleaner().clean(value);
  return const SemanticSnippetBuilder()
      .build(
        cleaned,
        contentType: SnippetContentType.agentSummary,
        maxChars: maxChars,
      )
      .visibleText
      .trim();
}

String _currentSituationText(TaskSession task, [WorkState? workState]) {
  if (workState == null) {
    return '正在同步任务状态。';
  }
  final statusText = workState.statusText.trim();
  if (statusText.isNotEmpty) return statusText;
  return switch (_workPhaseFor(workState, task.status)) {
    WorkPhase.idle => '等待开始。',
    WorkPhase.working => '此任务仍在工作中。',
    WorkPhase.quieting => '更新已暂停。',
    WorkPhase.turnIdle => '等待你的下一步指令。',
    WorkPhase.needsApproval || WorkPhase.needsDecision => '等待你的决定。',
    WorkPhase.needsReview => '最新结果等待查看。',
    WorkPhase.needsInstruction => '等待你的下一步指令。',
    WorkPhase.completed => '最新结果已就绪。',
    WorkPhase.failed => '此任务遇到了问题。',
    WorkPhase.stopped => '此任务已停止。',
  };
}

String _progressSituationText(TaskSession task, RuntimeTaskSnapshot snapshot) {
  final actionText = _progressActionText(snapshot.action);
  final action = actionText.isNotEmpty ? '动作: $actionText。' : '';
  final progress = snapshot.progress > 0 ? '进度 ${snapshot.progress}%' : '';
  final parts = [action, progress].where((p) => p.isNotEmpty);
  if (parts.isEmpty) return _currentSituationText(task);
  return '此任务仍在工作中。${parts.join('，')}。'
      '\n当前不需要任何操作。';
}

String _progressActionText(String value) {
  const lineNoiseFilter = LineNoiseFilter();
  final cleaned = const AgentOutputCleaner()
      .clean(value)
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .split('\n')
      .map((line) => line.trim().replaceFirst(
            RegExp(r'^[>❯▸›▪▫•*-]\s*'),
            '',
          ))
      .where((line) => line.isNotEmpty && !lineNoiseFilter.isUnreadable(line))
      .join(' ');
  if (cleaned.isEmpty) {
    return '';
  }
  return const SemanticSnippetBuilder()
      .build(
        cleaned,
        contentType: SnippetContentType.agentSummary,
        maxChars: 80,
      )
      .visibleText;
}

_NextAction _nextActionForTask(TaskStatus status, [WorkState? workState]) {
  switch (_workPhaseFor(workState, status)) {
    case WorkPhase.needsApproval:
      return _NextAction(
        title: '需要你决定',
        description: '选择此任务是否可以继续执行提议的操作。',
        icon: Icons.rule_outlined,
        color: Colors.orange.shade700,
      );
    case WorkPhase.turnIdle:
    case WorkPhase.needsInstruction:
    case WorkPhase.needsDecision:
      return _NextAction(
        title: '需要你的指令',
        description: '发送下一步指令、约束或决定。',
        icon: Icons.add_comment_outlined,
        color: Colors.orange.shade700,
      );
    case WorkPhase.working:
    case WorkPhase.idle:
      return const _NextAction(
        title: '当前无需操作',
        description: '任务仍在推进。你可以让它继续运行或暂停它。',
        icon: Icons.play_circle_outline,
        color: ArminTheme.primary,
      );
    case WorkPhase.completed:
    case WorkPhase.needsReview:
      return _NextAction(
        title: '可查看',
        description: '检查交付成果，然后接受或继续添加上下文。',
        icon: Icons.fact_check_outlined,
        color: Colors.green.shade700,
      );
    case WorkPhase.failed:
      return _NextAction(
        title: '需要查看',
        description: '检查发生的情况，并决定是否从此处继续。',
        icon: Icons.error_outline,
        color: Colors.red.shade700,
      );
    case WorkPhase.quieting:
      if (status == TaskStatus.paused) {
        return _NextAction(
          title: '已暂停',
          description: '准备好后恢复此任务。',
          icon: Icons.pause_circle_outline,
          color: Colors.blueGrey.shade700,
        );
      }
      return _NextAction(
        title: '连接已暂停',
        description: '更新已暂停。继续前请重新连接或查看详情。',
        icon: Icons.wifi_off_outlined,
        color: Colors.blueGrey.shade700,
      );
    case WorkPhase.stopped:
      return _NextAction(
        title: '查看详情',
        description: '此任务已停止。查看历史记录或启动新运行。',
        icon: Icons.stop_circle_outlined,
        color: Colors.grey.shade700,
      );
  }
}

_PrimaryTaskAction? _primaryTaskActionFor(
  TaskStatus status, [
  WorkState? workState,
]) {
  switch (_workPhaseFor(workState, status)) {
    case WorkPhase.needsApproval:
      return const _PrimaryTaskAction(
        label: '查看',
        icon: Icons.rule_outlined,
        kind: _PrimaryTaskActionKind.addContext,
      );
    case WorkPhase.turnIdle:
    case WorkPhase.needsInstruction:
    case WorkPhase.needsDecision:
      return const _PrimaryTaskAction(
        label: '继续',
        icon: Icons.add_comment_outlined,
        kind: _PrimaryTaskActionKind.addContext,
      );
    case WorkPhase.failed:
      return const _PrimaryTaskAction(
        label: '查看问题',
        icon: Icons.error_outline,
        kind: _PrimaryTaskActionKind.viewResult,
      );
    case WorkPhase.completed:
    case WorkPhase.needsReview:
      return const _PrimaryTaskAction(
        label: '查看结果',
        icon: Icons.fact_check_outlined,
        kind: _PrimaryTaskActionKind.viewResult,
      );
    case WorkPhase.quieting:
      if (status == TaskStatus.paused) {
        return const _PrimaryTaskAction(
          label: '恢复',
          icon: Icons.play_arrow_outlined,
          kind: _PrimaryTaskActionKind.resume,
        );
      }
      if (status == TaskStatus.runtimeLost) {
        return const _PrimaryTaskAction(
          label: '标记完成',
          icon: Icons.check_circle_outline,
          kind: _PrimaryTaskActionKind.markCompleted,
        );
      }
      return null;
    case WorkPhase.working:
    case WorkPhase.idle:
    case WorkPhase.stopped:
      return null;
  }
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
