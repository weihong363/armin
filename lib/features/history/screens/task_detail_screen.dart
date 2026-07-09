import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../core/services/armin_app_state.dart';
import '../../../shared/line_noise_filter.dart';
import '../../../shared/scroll/armin_scroll_behavior.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/parsers/terminal_prompt_parser.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../../hosts/models/host_config.dart';
import '../../projects/models/project_path_config.dart';
import '../../runtime/models/approval_state.dart';
import '../../runtime/models/resolved_runtime_state.dart';
import '../../runtime/models/runtime_task_snapshot.dart';
import '../../runtime/models/work_state.dart';
import '../../runtime/services/runtime_event_bus.dart';
import '../../tasks/models/loop_evaluation.dart';
import '../../tasks/models/native_output_turn.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/models/voice_input.dart';
import '../../tasks/screens/task_draft_screen.dart';
import '../../tasks/services/loop_evaluation_assistant.dart';
import '../../tasks/services/loop_follow_up_advisor.dart';
import '../../tasks/services/semantic_snippet_builder.dart';
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
const _timelineCacheLimit = 12;

final _timelineCache = <String, _TimelineViewModel>{};

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
  const TaskDetailScreen({
    required this.taskId,
    this.loopEvaluationAssistant = const LoopEvaluationAssistant(),
    super.key,
  });

  final String taskId;
  final LoopEvaluationAssistant loopEvaluationAssistant;

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
    final appState = AppStateScope.read(context);
    final status = appState.taskStatus(task);
    final workState = resolveRuntimeState(
      task,
      taskStatus: status,
      workState: appState.workState(task.id),
    ).toWorkState(task.id);
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
                enabled: _canRerun(status),
                child: const Text('重新执行'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.forceStop,
                enabled: _canForceStop(status),
                child: const Text('强制停止'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.cleanupSession,
                enabled: _canCleanupSession(status),
                child: const Text('清理远端会话'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.delete,
                enabled: _canDelete(status),
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
                    key: PageStorageKey<String>(
                      'task-detail-nested-scroll-${task.id}',
                    ),
                    physics: const ArminScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    headerSliverBuilder: (context, innerBoxIsScrolled) => [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: ValueListenableBuilder<RuntimeTaskSnapshot?>(
                            valueListenable: _progressNotifier,
                            builder: (context, progressSnapshot, _) {
                              final model = _RuntimeBrainViewModel.from(
                                task: task,
                                status: status,
                                workState: workState,
                                progressSnapshot: progressSnapshot,
                              );
                              return _RuntimeBrainCard(model: model);
                            },
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: _TaskNeedsPanel(
                            task: task,
                            status: status,
                            workState: workState,
                            onViewResult: _revealLatestResult,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: _TaskHeader(
                            task: task,
                            status: status,
                            workState: workState,
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
                          status: status,
                          resultVersion: _resultVersion,
                          loopEvaluationAssistant:
                              widget.loopEvaluationAssistant,
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

  bool _canDelete(TaskStatus status) {
    return switch (status) {
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

  bool _canForceStop(TaskStatus status) {
    return status == TaskStatus.running ||
        status == TaskStatus.paused ||
        status == TaskStatus.needApproval ||
        status == TaskStatus.turnIdle ||
        status == TaskStatus.needAttention ||
        status == TaskStatus.observerDetached ||
        status == TaskStatus.pending;
  }

  bool _canRerun(TaskStatus status) {
    return status == TaskStatus.completed ||
        status == TaskStatus.failed ||
        status == TaskStatus.userCompleted ||
        status == TaskStatus.userFailed ||
        status == TaskStatus.stopped ||
        status == TaskStatus.runtimeLost;
  }

  bool _canCleanupSession(TaskStatus status) {
    return status == TaskStatus.completed ||
        status == TaskStatus.failed ||
        status == TaskStatus.userCompleted ||
        status == TaskStatus.userFailed ||
        status == TaskStatus.stopped ||
        status == TaskStatus.runtimeLost;
  }
}

class _CurrentTaskTabPanel extends StatelessWidget {
  const _CurrentTaskTabPanel({
    super.key,
    required this.index,
    required this.task,
    required this.status,
    required this.resultVersion,
    required this.loopEvaluationAssistant,
  });

  final int index;
  final TaskSession task;
  final TaskStatus status;
  final int resultVersion;
  final LoopEvaluationAssistant loopEvaluationAssistant;

  @override
  Widget build(BuildContext context) {
    return switch (index) {
      0 => _TimelinePanel(
          task: task,
          status: status,
          loopEvaluationAssistant: loopEvaluationAssistant,
        ),
      1 => _ResultPanel(
          task: task,
          status: status,
          resultVersion: resultVersion,
        ),
      _ => _AdvancedDebugPanel(task: task, status: status),
    };
  }
}

class _RuntimeBrainViewModel {
  const _RuntimeBrainViewModel({
    required this.goal,
    required this.focus,
    required this.next,
    required this.risk,
    required this.statusLabel,
    required this.statusColor,
    required this.elapsed,
    required this.steps,
    required this.requiresAttention,
  });

  final String goal;
  final _RuntimeFocusViewModel focus;
  final String next;
  final String risk;
  final String statusLabel;
  final Color statusColor;
  final String elapsed;
  final List<_RuntimeTimelineStepViewModel> steps;
  final bool requiresAttention;

  factory _RuntimeBrainViewModel.from({
    required TaskSession task,
    required TaskStatus status,
    required WorkState? workState,
    required RuntimeTaskSnapshot? progressSnapshot,
  }) {
    final phase = runtimePhaseForTaskStatus(status);
    final statusColor = _detailStatusColor(status, workState);
    final focus = _RuntimeFocusViewModel.from(
      task: task,
      status: status,
      workState: workState,
      progressSnapshot: progressSnapshot,
    );
    return _RuntimeBrainViewModel(
      goal: _runtimeGoalText(task),
      focus: focus,
      next: _runtimeNextText(task, status, workState),
      risk: _runtimeRiskText(status, workState),
      statusLabel: _runtimePhaseLabel(phase, status),
      statusColor: statusColor,
      elapsed: _runtimeElapsedText(task, status),
      steps: _runtimeStepsFor(task, status, workState),
      requiresAttention: _isAttentionRequired(workState) ||
          status == TaskStatus.turnIdle ||
          status == TaskStatus.needAttention ||
          status == TaskStatus.needApproval,
    );
  }
}

class _RuntimeFocusViewModel {
  const _RuntimeFocusViewModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
  });

  final String id;
  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;

  factory _RuntimeFocusViewModel.from({
    required TaskSession task,
    required TaskStatus status,
    required WorkState? workState,
    required RuntimeTaskSnapshot? progressSnapshot,
  }) {
    final phase = runtimePhaseForTaskStatus(status);
    final progressAction = progressSnapshot == null
        ? ''
        : _progressActionText(progressSnapshot.action);
    final headline = workState?.headline.trim() ?? '';
    final detail = workState?.detail.trim() ?? '';
    final latestTurn = task.turns.lastOrNull;
    final latestDeliverable = latestTurn?.deliverable;
    final hasReadableDeliverable = latestDeliverable != null &&
        const AgentOutputCleaner()
            .clean(latestDeliverable.displaySummary)
            .trim()
            .isNotEmpty;

    final title = switch (phase) {
      WorkPhase.working => _firstNonEmpty([
          progressAction,
          headline,
          detail,
          'Agent 正在执行',
        ]),
      WorkPhase.needsApproval => headline.isEmpty ? '等待审批' : headline,
      WorkPhase.needsInstruction ||
      WorkPhase.turnIdle =>
        !hasReadableDeliverable
            ? _firstNonEmpty([headline, '等待你的下一步指令'])
            : '等待你验收最新结果',
      WorkPhase.needsReview => '等待你查看最新结果',
      WorkPhase.quieting => status == TaskStatus.paused ? '任务已暂停' : '监听已暂停',
      WorkPhase.completed => '任务已完成',
      WorkPhase.failed => '需要查看运行问题',
      WorkPhase.stopped => '任务已停止',
      WorkPhase.idle => '等待开始',
      WorkPhase.needsDecision => headline.isEmpty ? '等待你的决定' : headline,
    };
    final subtitle = switch (phase) {
      WorkPhase.working => 'Current Focus',
      WorkPhase.needsApproval => 'Risk / Approval',
      WorkPhase.turnIdle || WorkPhase.needsInstruction => 'User Attention',
      WorkPhase.completed || WorkPhase.needsReview => 'Review',
      WorkPhase.failed => 'Risk',
      WorkPhase.quieting => 'Connection',
      WorkPhase.idle => 'Ready',
      WorkPhase.needsDecision => 'Decision',
      WorkPhase.stopped => 'Stopped',
    };
    return _RuntimeFocusViewModel(
      id: '${task.id}:${phase.name}:$title',
      title: title,
      subtitle: subtitle,
      color: _detailStatusColor(status, workState),
      icon: _runtimeFocusIcon(phase, status),
    );
  }
}

class _RuntimeTimelineStepViewModel {
  const _RuntimeTimelineStepViewModel({
    required this.label,
    required this.state,
  });

  final String label;
  final _RuntimeTimelineStepState state;
}

enum _RuntimeTimelineStepState { done, active, idle, blocked }

class _RuntimeBrainCard extends StatelessWidget {
  const _RuntimeBrainCard({required this.model});

  final _RuntimeBrainViewModel model;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: model.statusColor.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: model.statusColor.withValues(alpha: 0.22)),
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
                    'Runtime Brain',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: model.statusColor,
                        ),
                  ),
                ),
                _MiniBadge(
                  key: const Key('runtime-control-state-badge'),
                  label: model.statusLabel,
                  color: model.statusColor,
                  animate: !model.requiresAttention &&
                      model.statusLabel == 'Executing',
                ),
              ],
            ),
            const SizedBox(height: 6),
            _RuntimeBrainField(
              label: 'Goal',
              value: model.goal,
              maxLines: 1,
            ),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final offset = Tween<Offset>(
                  begin: const Offset(0, 0.08),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: offset,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.98, end: 1).animate(
                        animation,
                      ),
                      child: child,
                    ),
                  ),
                );
              },
              child: _RuntimeBrainField(
                key: ValueKey(model.focus.id),
                label: 'Current Focus',
                value: model.focus.title,
                leading: Icon(
                  model.focus.icon,
                  size: 18,
                  color: model.focus.color,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Next · ${model.next}   Risk · ${model.risk}   Time · ${model.elapsed}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.58),
                  ),
            ),
            const SizedBox(height: 6),
            Text('当前状况', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _RuntimeBrainField extends StatelessWidget {
  const _RuntimeBrainField({
    required this.label,
    required this.value,
    this.leading,
    this.maxLines = 1,
    super.key,
  });

  final String label;
  final String value;
  final Widget? leading;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.48),
              ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: leading,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                value,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RuntimeFocusCard extends StatelessWidget {
  const _RuntimeFocusCard({required this.focus});

  final _RuntimeFocusViewModel focus;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: 'Focus',
      trailing: Text(
        focus.subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: focus.color,
            ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        child: Row(
          key: ValueKey(focus.id),
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: focus.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(focus.icon, color: focus.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                focus.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeStateTimelineCard extends StatelessWidget {
  const _RuntimeStateTimelineCard({required this.steps});

  final List<_RuntimeTimelineStepViewModel> steps;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: 'State Timeline',
      child: Column(
        children: [
          for (var index = 0; index < steps.length; index++) ...[
            _RuntimeStateTimelineStep(step: steps[index]),
            if (index != steps.length - 1)
              Container(
                width: 1,
                height: 12,
                margin: const EdgeInsets.only(left: 9),
                alignment: Alignment.centerLeft,
                color: ArminTheme.border,
              ),
          ],
        ],
      ),
    );
  }
}

class _RuntimeStateTimelineStep extends StatelessWidget {
  const _RuntimeStateTimelineStep({required this.step});

  final _RuntimeTimelineStepViewModel step;

  @override
  Widget build(BuildContext context) {
    final color = switch (step.state) {
      _RuntimeTimelineStepState.done => Colors.green.shade700,
      _RuntimeTimelineStepState.active => ArminTheme.primary,
      _RuntimeTimelineStepState.blocked => Colors.orange.shade700,
      _RuntimeTimelineStepState.idle =>
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.32),
    };
    final icon = switch (step.state) {
      _RuntimeTimelineStepState.done => Icons.check_rounded,
      _RuntimeTimelineStepState.active => Icons.circle,
      _RuntimeTimelineStepState.blocked => Icons.priority_high_rounded,
      _RuntimeTimelineStepState.idle => Icons.circle_outlined,
    };
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: step.state == _RuntimeTimelineStepState.idle
                ? Colors.transparent
                : color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: color,
                  fontWeight: step.state == _RuntimeTimelineStepState.active
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
            child: Text(step.label),
          ),
        ),
      ],
    );
  }
}

class _TaskHeader extends StatefulWidget {
  const _TaskHeader({
    required this.task,
    required this.status,
    required this.workState,
  });

  final TaskSession task;
  final TaskStatus status;
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
    final status = widget.status;
    final statusColor = _detailStatusColor(status, widget.workState);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ArminTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Task Meta',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.48),
                  ),
            ),
            const SizedBox(height: 6),
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
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: InputDecoration(
                        labelText: '标题',
                        hintText: '输入任务标题',
                        hintStyle:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MiniBadge(
                  label: _detailStatusLabel(status, widget.workState),
                  color: statusColor,
                  animate:
                      runtimePhaseForTaskStatus(status) == WorkPhase.working,
                ),
                _TaskTimingText(task: task, status: status),
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
  const _TaskTimingText({required this.task, required this.status});

  final TaskSession task;
  final TaskStatus status;

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
    if (oldWidget.status != widget.status ||
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
        _isLiveTask(widget.task, widget.status)) {
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
      _statusTimingText(widget.task, widget.status),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  bool _isLiveTask(TaskSession task, TaskStatus status) {
    return task.completedAt == null &&
        (status == TaskStatus.running ||
            status == TaskStatus.pending ||
            status == TaskStatus.paused ||
            status == TaskStatus.needApproval ||
            status == TaskStatus.turnIdle ||
            status == TaskStatus.needAttention ||
            status == TaskStatus.observerDetached);
  }
}

class _TimelinePanel extends StatefulWidget {
  const _TimelinePanel({
    required this.task,
    required this.status,
    required this.loopEvaluationAssistant,
  });

  final TaskSession task;
  final TaskStatus status;
  final LoopEvaluationAssistant loopEvaluationAssistant;

  @override
  State<_TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<_TimelinePanel> {
  String _cachedSignature = '';
  String _aiEvaluationSignature = '';
  Future<LoopEvaluationSummary>? _aiEvaluationFuture;
  late _TimelineViewModel _viewModel;

  static String _computeSignature(TaskSession task, TaskStatus status) {
    final latestTurn = task.turns.lastOrNull;
    return '${task.id}:${status.name}:'
        '${task.updatedAt.microsecondsSinceEpoch}:'
        '${task.completedAt?.microsecondsSinceEpoch}:'
        '${task.voiceInputs.length}:${task.turns.length}:'
        '${task.metricEvents.length}:'
        '${latestTurn?.status.name}:'
        '${latestTurn?.deliverable?.evidenceFingerprint}:'
        '${latestTurn?.deliverable?.displaySummary.hashCode}';
  }

  static _TimelineViewModel _timelineViewModelFor(
    TaskSession task,
    TaskStatus status,
  ) {
    final signature = _computeSignature(task, status);
    final cached = _cachedTimeline(signature);
    if (cached != null) {
      return cached;
    }
    final readableSummary = const SemanticSnippetBuilder()
        .build(
          _latestDeliverableSummary(task),
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
        icon: _timelineResultIcon(status),
        time:
            task.completedAt == null ? '--:--' : _timeLabel(task.completedAt!),
        title: _timelineResultTitle(status),
        subtitle: readableSummary.isEmpty
            ? _currentSituationText(task, status)
            : readableSummary,
        color: _timelineResultColor(status),
      ),
    ];
    final model = _TimelineViewModel(
      visibleItems: allItems.reversed.take(3).toList(growable: false),
      hasTurns: task.turns.isNotEmpty,
      hasLoopFacts: _LoopFactsSummary.fromTask(task).hasFacts,
      showAiEvaluation: _shouldShowAiEvaluation(task, status),
      followUpSuggestions: _followUpSuggestionsFor(task, status),
    );
    _cacheTimeline(signature, model);
    return model;
  }

  static String _latestDeliverableSummary(TaskSession task) {
    for (final turn in task.turns.reversed) {
      final text = turn.deliverable?.displaySummary.trim();
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  static List<LoopFollowUpSuggestion> _followUpSuggestionsFor(
    TaskSession task,
    TaskStatus status,
  ) {
    final latestTurn = task.turns.lastOrNull;
    if (status != TaskStatus.turnIdle ||
        latestTurn?.status != NativeOutputTurnStatus.turnIdle ||
        latestTurn?.deliverable == null) {
      return const [];
    }
    return const LoopFollowUpAdvisor().suggest(task);
  }

  static bool _shouldShowAiEvaluation(TaskSession task, TaskStatus status) {
    final latestTurn = task.turns.lastOrNull;
    return latestTurn?.deliverable != null ||
        status == TaskStatus.needApproval ||
        status == TaskStatus.needAttention ||
        status == TaskStatus.runtimeLost ||
        status == TaskStatus.failed;
  }

  @override
  void initState() {
    super.initState();
    _cachedSignature = _computeSignature(widget.task, widget.status);
    _viewModel = _timelineViewModelFor(widget.task, widget.status);
  }

  @override
  void didUpdateWidget(covariant _TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSignature = _computeSignature(widget.task, widget.status);
    if (newSignature != _cachedSignature) {
      _cachedSignature = newSignature;
      _viewModel = _timelineViewModelFor(widget.task, widget.status);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aiEvaluationFuture = _aiEvaluationFutureFor();
    return ListView.separated(
      key:
          PageStorageKey<String>('task-detail-timeline-list-${widget.task.id}'),
      physics: _taskDetailTabScrollPhysics,
      padding: const EdgeInsets.all(20),
      itemCount: _viewModel.visibleItems.length +
          2 +
          (_viewModel.hasLoopFacts ? 1 : 0) +
          (_viewModel.showAiEvaluation ? 1 : 0) +
          (_viewModel.followUpSuggestions.isNotEmpty ? 1 : 0) +
          (_viewModel.hasTurns ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        var itemIndex = index;
        if (itemIndex == 0) {
          final workState = AppStateScope.read(context).workState(
            widget.task.id,
          );
          final model = _RuntimeBrainViewModel.from(
            task: widget.task,
            status: widget.status,
            workState: workState,
            progressSnapshot: null,
          );
          return _RuntimeFocusCard(focus: model.focus);
        }
        itemIndex -= 1;
        if (itemIndex == 0) {
          final workState = AppStateScope.read(context).workState(
            widget.task.id,
          );
          final model = _RuntimeBrainViewModel.from(
            task: widget.task,
            status: widget.status,
            workState: workState,
            progressSnapshot: null,
          );
          return _RuntimeStateTimelineCard(steps: model.steps);
        }
        itemIndex -= 1;
        if (_viewModel.hasLoopFacts) {
          if (itemIndex == 0) {
            return _LoopFactsCard(task: widget.task);
          }
          itemIndex -= 1;
        }
        if (_viewModel.showAiEvaluation) {
          if (itemIndex == 0) {
            return _LoopEvaluationCard(future: aiEvaluationFuture);
          }
          itemIndex -= 1;
        }
        if (_viewModel.followUpSuggestions.isNotEmpty) {
          if (itemIndex == 0) {
            return _FollowUpSuggestionsCard(
              suggestions: _viewModel.followUpSuggestions,
              onUseDraft: _showSuggestedFollowUpSheet,
            );
          }
          itemIndex -= 1;
        }
        if (itemIndex < _viewModel.visibleItems.length) {
          return _TimelineItem.fromData(_viewModel.visibleItems[itemIndex]);
        }
        return _InfoCard(
          title: '\u4efb\u52a1\u8f93\u51fa\u5386\u53f2',
          child: _TurnSummaryList(task: widget.task),
        );
      },
    );
  }

  Future<LoopEvaluationSummary> _aiEvaluationFutureFor() {
    final latestTurn = widget.task.turns.lastOrNull;
    final signature = '${widget.task.id}:${widget.status.name}:'
        '${widget.task.updatedAt.microsecondsSinceEpoch}:'
        '${widget.task.metricEvents.length}:'
        '${latestTurn?.deliverable?.evidenceFingerprint}:'
        '${latestTurn?.deliverable?.displaySummary.hashCode}';
    if (_aiEvaluationFuture == null || signature != _aiEvaluationSignature) {
      _aiEvaluationSignature = signature;
      _aiEvaluationFuture = widget.loopEvaluationAssistant.evaluate(
        widget.task,
        runtimeStatus: widget.status.name,
      );
    }
    return _aiEvaluationFuture!;
  }

  void _showSuggestedFollowUpSheet(LoopFollowUpSuggestion suggestion) {
    AddContextSheet.show(
      context,
      task: widget.task,
      status: widget.status,
      title: suggestion.title,
      hintText: suggestion.reason,
      initialInstruction: suggestion.draft,
      onSubmit: (sheetContext, instruction, command) async {
        await AppStateScope.read(sheetContext).sendFollowUp(
          widget.task,
          instruction,
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

class _TurnSummaryList extends StatelessWidget {
  const _TurnSummaryList({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final latest = task.turns.lastOrNull;
    if (latest == null) {
      return const Text('暂无输出记录');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TurnSummaryRow(turn: latest),
        if (task.turns.length > 1) ...[
          const SizedBox(height: 4),
          Text(
            '已隐藏 ${task.turns.length - 1} 条更早输出，当前只展示最新结果。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.55),
                ),
          ),
        ],
      ],
    );
  }
}

class _TurnSummaryRow extends StatelessWidget {
  const _TurnSummaryRow({required this.turn});

  final NativeOutputTurn turn;

  @override
  Widget build(BuildContext context) {
    final title = turn.turnIndex == 1 ? '初始任务输出' : '上下文更新输出 ${turn.turnIndex}';
    final deliverable = turn.deliverable?.displaySummary.trim() ?? '';
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
        if (deliverable.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            deliverable,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
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
    required this.status,
    required this.resultVersion,
  });

  final TaskSession task;
  final TaskStatus status;
  final int resultVersion;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  static const _foldLineLimit = 20;
  static const _summaryPageSize = 3;

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
        oldWidget.status != widget.status ||
        _turnsSignature(oldWidget.task) != _turnsSignature(widget.task)) {
      if (oldWidget.task.id != widget.task.id ||
          _turnsSignature(oldWidget.task) != _turnsSignature(widget.task)) {
        _visibleSummaryCount = _summaryPageSize;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const PageStorageKey<String>('task-detail-result-list'),
      physics: _taskDetailTabScrollPhysics,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
      children: [
        _InfoCard(
          title: '结果 / 产出',
          trailing: Text(
            '点击播放/暂停 · 长按终止',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.45),
                ),
          ),
          child: _shouldBuildResultContent(widget.task)
              ? _buildResultSummary()
              : Text(_emptyResultText(widget.status)),
        ),
      ],
    );
  }

  List<_TurnOutputSummary> _outputSummaries(TaskSession task) {
    final summaries = <_TurnOutputSummary>[];
    final indexedTurns = _resultTurns(task, limit: _visibleSummaryCount);
    for (var visibleIndex = 0;
        visibleIndex < indexedTurns.length;
        visibleIndex += 1) {
      final indexedTurn = indexedTurns[visibleIndex];
      final turn = indexedTurn.turn;
      final deliverable = turn.deliverable;
      if (deliverable == null) continue;
      final text = _displaySummaryText(deliverable.displaySummary);
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
    if (summaries.isEmpty) {
      final progress = _progressOutputSummary(task);
      if (progress != null) {
        summaries.add(progress);
      }
    }
    return summaries;
  }

  _TurnOutputSummary? _progressOutputSummary(TaskSession task) {
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (turn.deliverable != null ||
          turn.status == NativeOutputTurnStatus.running) {
        continue;
      }
      final text = _progressSummaryText(turn);
      if (text.isEmpty) continue;
      return _TurnOutputSummary(
        title: '最近进展（非最终结果）',
        text: text,
        speechText: '',
        fullOutputForSpeech: '',
      );
    }
    return null;
  }

  String _progressSummaryText(NativeOutputTurn turn) {
    final source = turn.cleanedOutput.trim().isNotEmpty
        ? turn.cleanedOutput
        : turn.rawOutput;
    if (const TerminalPromptParser().parse(source) != null ||
        _looksLikeTerminalInteraction(source)) {
      return '';
    }
    final cleaned = const AgentOutputCleaner().clean(source);
    if (cleaned.trim().isEmpty) return '';
    final lines = <String>[];
    for (final line in cleaned.split('\n')) {
      final progressLine = _progressLine(line);
      if (progressLine.isNotEmpty && !lines.contains(progressLine)) {
        lines.add(progressLine);
      }
    }
    if (lines.isEmpty) return '';
    final tail = lines.length <= 6 ? lines : lines.sublist(lines.length - 6);
    return [
      '目标 CLI 尚未输出正式结果；下面是最近可确认的执行进展。',
      ...tail,
    ].join('\n');
  }

  bool _looksLikeTerminalInteraction(String output) {
    final lower = output.toLowerCase();
    return (lower.contains('allow once') ||
            lower.contains('reject and type something') ||
            lower.contains('permission required')) &&
        (lower.contains('allow this command') ||
            lower.contains('apply this change') ||
            lower.contains('redirection detected') ||
            lower.contains('command:'));
  }

  String _progressLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return '';
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('armin_diag:') ||
        lower.startsWith('armin context governance') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('thinking') ||
        const LineNoiseFilter().isUnreadable(trimmed) ||
        lower.contains("what's new") ||
        lower.contains('not login please auth') ||
        lower.contains('/release-notes for more')) {
      return '';
    }
    final content = trimmed.replaceFirst(RegExp(r'^[▪▫]\s*'), '').trim();
    final readMatch = RegExp(r'^Read\((.+)\)$').firstMatch(content);
    if (readMatch != null) {
      return '已读取 ${_compactPath(readMatch.group(1) ?? '')}';
    }
    final globMatch = RegExp(r"^Glob\('(.+)'\)$").firstMatch(content);
    if (globMatch != null) {
      return '已检查 ${globMatch.group(1)}';
    }
    final bashMatch = RegExp(r'^Bash\((.+)\)$').firstMatch(content);
    if (bashMatch != null) {
      return '已执行 ${bashMatch.group(1)}';
    }
    if (content.startsWith('└')) {
      return content.replaceFirst(RegExp(r'^└\s*'), '').trim();
    }
    final contentLower = content.toLowerCase();
    if (contentLower.startsWith('let me ') ||
        contentLower.startsWith('i will ') ||
        contentLower.startsWith("i'll ")) {
      return '';
    }
    return content;
  }

  String _compactPath(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '文件';
    final parts = normalized.split('/');
    return parts.isEmpty ? normalized : parts.last.replaceAll(')', '');
  }

  List<_IndexedTurn> _resultTurns(TaskSession task, {required int limit}) {
    final turns = <_IndexedTurn>[];
    for (var index = task.turns.length - 1; index >= 0; index--) {
      final turn = task.turns[index];
      if (turn.deliverable != null) {
        turns.add(_IndexedTurn(index: index, turn: turn));
        if (turns.length >= limit) {
          break;
        }
      }
    }
    return turns;
  }

  int _resultTurnCount(TaskSession task) {
    return task.turns.where((turn) => turn.deliverable != null).length;
  }

  String _displaySummaryText(String displaySummary) {
    final cleaned = const AgentOutputCleaner().clean(displaySummary).trim();
    if (cleaned.isEmpty) {
      return '';
    }
    final lines = cleaned
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .where((line) => !_looksLikeResultLogNoise(line))
        .toList(growable: false);
    return lines.isEmpty ? cleaned : lines.join('\n');
  }

  bool _looksLikeResultLogNoise(String line) {
    final trimmed = line.trim();
    final lower = trimmed.toLowerCase();
    return lower.startsWith('armin context governance') ||
        lower.startsWith('armin_diag:') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('thinking') ||
        const LineNoiseFilter().isUnreadable(trimmed) ||
        lower.contains("what's new") ||
        lower.contains('not login please auth') ||
        lower.contains('/release-notes for more') ||
        RegExp(r'^[▪▫]\s*(?:Read|Glob|Grep|Bash|Write|Edit|MultiEdit|List)\(',
                caseSensitive: false)
            .hasMatch(trimmed) ||
        trimmed.startsWith('└') ||
        trimmed.startsWith('│');
  }

  String _turnsSignature(TaskSession task) {
    return task.turns
        .map((t) => [
              t.turnIndex,
              t.status.name,
              t.userInput.hashCode,
              t.deliverable?.evidenceFingerprint ?? '',
            ].join(':'))
        .join('|');
  }

  Widget _buildResultSummary() {
    final outputs = _outputSummaries(widget.task);
    if (outputs.isEmpty) {
      return const Text('暂无结果');
    }
    return _buildOutputSummaries(outputs);
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
    });
  }

  bool _shouldBuildResultSummary(TaskSession task) =>
      _resultTurnCount(task) > 0;

  bool _shouldBuildResultContent(TaskSession task) =>
      _shouldBuildResultSummary(task) || _progressOutputSummary(task) != null;
}

String _emptyResultText(TaskStatus status) {
  return switch (status) {
    TaskStatus.running ||
    TaskStatus.pending ||
    TaskStatus.draft =>
      '任务仍在执行，暂无可展示的正式结果。',
    TaskStatus.needApproval ||
    TaskStatus.needAttention =>
      '任务正在等待你的处理，暂无可展示的正式结果。',
    TaskStatus.turnIdle => '本轮已结束，暂无可展示的正式结果。',
    TaskStatus.paused ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      '更新已暂停，暂无可展示的正式结果。',
    TaskStatus.completed ||
    TaskStatus.userCompleted ||
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped =>
      '暂无可展示的正式结果。',
  };
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
                      _outputExpanded ? '收起完整摘要' : '展开完整摘要',
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
    required this.hasLoopFacts,
    required this.showAiEvaluation,
    required this.followUpSuggestions,
  });

  final List<_TimelineItemData> visibleItems;
  final bool hasTurns;
  final bool hasLoopFacts;
  final bool showAiEvaluation;
  final List<LoopFollowUpSuggestion> followUpSuggestions;
}

class _LoopFactsCard extends StatelessWidget {
  const _LoopFactsCard({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final summary = _LoopFactsSummary.fromTask(task);
    return _InfoCard(
      title: 'Loop 事实',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _FactChip(label: 'Turn', value: '${summary.turnCount}'),
          if (summary.lastTurnIndex > 0)
            _FactChip(label: '最近', value: 'Turn ${summary.lastTurnIndex}'),
          _FactChip(label: '结果', value: summary.deliverableCount.toString()),
          _FactChip(label: '继续', value: summary.continueCount.toString()),
          _FactChip(label: '接受', value: summary.acceptedCount.toString()),
          _FactChip(label: '重做', value: summary.redoCount.toString()),
          _FactChip(
              label: '审批', value: summary.approvalRequestCount.toString()),
          _FactChip(
              label: '处理', value: summary.approvalResolvedCount.toString()),
          _FactChip(label: '完成', value: summary.completedCount.toString()),
          _FactChip(label: '失败', value: summary.failedCount.toString()),
          if (summary.approvalCustomResponseCount > 0)
            _FactChip(
              label: '补充',
              value: summary.approvalCustomResponseCount.toString(),
            ),
          if (summary.lastOutputSummaryLength > 0)
            _FactChip(
              label: '摘要',
              value: '${summary.lastOutputSummaryLength} 字',
            ),
          if (summary.lastWaitMs > 0)
            _FactChip(
              label: '耗时',
              value: _elapsedLabel(Duration(milliseconds: summary.lastWaitMs)),
            ),
          if (summary.loopSummaryText.isNotEmpty)
            _LoopSummaryText(summary.loopSummaryText),
        ],
      ),
    );
  }
}

class _LoopSummaryText extends StatelessWidget {
  const _LoopSummaryText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _LoopEvaluationCard extends StatelessWidget {
  const _LoopEvaluationCard({required this.future});

  final Future<LoopEvaluationSummary> future;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('loop-evaluation-card'),
      child: _InfoCard(
        title: '辅助判断',
        child: FutureBuilder<LoopEvaluationSummary>(
          future: future,
          builder: (context, snapshot) {
            final textTheme = Theme.of(context).textTheme;
            if (snapshot.connectionState != ConnectionState.done) {
              return Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ArminTheme.primary.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在基于本轮事实生成判断',
                    style: textTheme.bodySmall,
                  ),
                ],
              );
            }
            final summary = snapshot.data;
            final text = summary?.text.trim() ?? '暂时无法生成辅助判断。';
            final source = summary?.usedAi == true ? '端侧模型' : '规则判断';
            final nextAction = summary?.nextAction;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Column(
                key: ValueKey('$source:$text:${nextAction?.id ?? ''}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style:
                        textTheme.bodyMedium?.copyWith(color: ArminTheme.ink),
                  ),
                  if (nextAction != null) ...[
                    const SizedBox(height: 10),
                    _LoopNextActionView(action: nextAction),
                  ],
                  const SizedBox(height: 10),
                  _FactChip(label: '来源', value: source),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LoopNextActionView extends StatelessWidget {
  const _LoopNextActionView({required this.action});

  final LoopNextAction action;

  @override
  Widget build(BuildContext context) {
    final label = switch (action.policy) {
      LoopNextActionPolicy.autoAllowed => '低风险，可自动执行',
      LoopNextActionPolicy.assisted => '辅助草稿，需用户确认',
      LoopNextActionPolicy.confirmationRequired => '高风险，必须确认',
      LoopNextActionPolicy.manualOnly => '仅手动',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: ArminTheme.primary.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              action.title,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(action.reason),
            const SizedBox(height: 8),
            _FactChip(label: '执行策略', value: label),
          ],
        ),
      ),
    );
  }
}

class _FollowUpSuggestionsCard extends StatelessWidget {
  const _FollowUpSuggestionsCard({
    required this.suggestions,
    required this.onUseDraft,
  });

  final List<LoopFollowUpSuggestion> suggestions;
  final ValueChanged<LoopFollowUpSuggestion> onUseDraft;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: '建议后续指令',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < suggestions.length; index++) ...[
            if (index > 0) const SizedBox(height: 10),
            _FollowUpSuggestionTile(
              suggestion: suggestions[index],
              onUseDraft: onUseDraft,
            ),
          ],
        ],
      ),
    );
  }
}

class _FollowUpSuggestionTile extends StatelessWidget {
  const _FollowUpSuggestionTile({
    required this.suggestion,
    required this.onUseDraft,
  });

  final LoopFollowUpSuggestion suggestion;
  final ValueChanged<LoopFollowUpSuggestion> onUseDraft;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: ArminTheme.primary.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    suggestion.title,
                    style: textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => onUseDraft(suggestion),
                  icon: const Icon(Icons.edit_note_outlined, size: 18),
                  label: const Text('使用草稿'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(suggestion.reason, style: textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              suggestion.draft,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(color: ArminTheme.ink),
            ),
          ],
        ),
      ),
    );
  }
}

Map<String, Object?> _metricPayload(String payloadJson) {
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {
    return const {};
  }
  return const {};
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArminTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Text(
          '$label $value',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ArminTheme.ink,
              ),
        ),
      ),
    );
  }
}

class _LoopFactsSummary {
  const _LoopFactsSummary({
    required this.turnCount,
    required this.lastTurnIndex,
    required this.deliverableCount,
    required this.continueCount,
    required this.acceptedCount,
    required this.redoCount,
    required this.approvalRequestCount,
    required this.approvalResolvedCount,
    required this.approvalCustomResponseCount,
    required this.completedCount,
    required this.failedCount,
    required this.lastOutputSummaryLength,
    required this.lastWaitMs,
    required this.loopSummaryText,
  });

  final int turnCount;
  final int lastTurnIndex;
  final int deliverableCount;
  final int continueCount;
  final int acceptedCount;
  final int redoCount;
  final int approvalRequestCount;
  final int approvalResolvedCount;
  final int approvalCustomResponseCount;
  final int completedCount;
  final int failedCount;
  final int lastOutputSummaryLength;
  final int lastWaitMs;
  final String loopSummaryText;

  bool get hasFacts {
    return turnCount > 0 ||
        deliverableCount > 0 ||
        continueCount > 0 ||
        acceptedCount > 0 ||
        redoCount > 0 ||
        approvalRequestCount > 0 ||
        approvalResolvedCount > 0 ||
        approvalCustomResponseCount > 0 ||
        completedCount > 0 ||
        failedCount > 0;
  }

  factory _LoopFactsSummary.fromTask(TaskSession task) {
    var deliverableCount = 0;
    var continueCount = 0;
    var acceptedCount = 0;
    var redoCount = 0;
    var approvalRequestCount = 0;
    var approvalResolvedCount = 0;
    var approvalCustomResponseCount = 0;
    var completedCount = 0;
    var failedCount = 0;
    var lastOutputSummaryLength = 0;
    var lastWaitMs = 0;
    var loopSummaryText = '';
    for (final event in task.metricEvents) {
      final payload = _metricPayload(event.payloadJson);
      if (event.eventType == LoopEvaluation.metricEventType) {
        final evaluation = LoopEvaluation.fromJson(payload);
        if (evaluation.metrics.hasDeliverable) {
          deliverableCount += 1;
        }
        lastOutputSummaryLength = evaluation.metrics.outputSummaryLength;
        lastWaitMs = evaluation.metrics.waitMs;
      }
      if (event.eventType == LoopResultSummary.metricEventType) {
        loopSummaryText = LoopResultSummary.fromJson(payload).summaryText;
      }
      if (event.eventType == LoopUserAction.metricEventType) {
        final action = LoopUserAction.fromJson(payload);
        switch (action.kind) {
          case LoopUserActionKind.continueTask:
            continueCount += 1;
          case LoopUserActionKind.acceptResult:
            acceptedCount += 1;
          case LoopUserActionKind.markCompleted:
            completedCount += 1;
          case LoopUserActionKind.markFailed:
            failedCount += 1;
          case LoopUserActionKind.rejectOrRedo:
            redoCount += 1;
        }
      }
      if (event.eventType == LoopApprovalEvent.metricEventType) {
        final approvalEvent = LoopApprovalEvent.fromJson(payload);
        switch (approvalEvent.kind) {
          case LoopApprovalEventKind.requested:
            approvalRequestCount += 1;
          case LoopApprovalEventKind.approved ||
                LoopApprovalEventKind.rejected ||
                LoopApprovalEventKind.optionSelected:
            approvalResolvedCount += 1;
          case LoopApprovalEventKind.customResponse:
            approvalCustomResponseCount += 1;
        }
      }
    }
    return _LoopFactsSummary(
      turnCount: task.turns.length,
      lastTurnIndex: task.turns.lastOrNull?.turnIndex ?? 0,
      deliverableCount: deliverableCount,
      continueCount: continueCount,
      acceptedCount: acceptedCount,
      redoCount: redoCount,
      approvalRequestCount: approvalRequestCount,
      approvalResolvedCount: approvalResolvedCount,
      approvalCustomResponseCount: approvalCustomResponseCount,
      completedCount: completedCount,
      failedCount: failedCount,
      lastOutputSummaryLength: lastOutputSummaryLength,
      lastWaitMs: lastWaitMs,
      loopSummaryText: loopSummaryText,
    );
  }
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
    required this.status,
    required this.workState,
    required this.onViewResult,
  });

  final TaskSession task;
  final TaskStatus status;
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
    final nextAction = _nextActionForTask(widget.status, widget.workState);
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
            status: widget.status,
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
      status: widget.status,
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
      if (turn.deliverable != null) {
        return _IndexedTurn(index: index, turn: turn);
      }
    }
    return null;
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
  const _AddContextPanel({required this.task, required this.status});

  final TaskSession task;
  final TaskStatus status;

  @override
  State<_AddContextPanel> createState() => _AddContextPanelState();
}

class _AddContextPanelState extends State<_AddContextPanel> {
  static const _voiceCommandProcessor = VoiceTaskCommandProcessor();

  @override
  Widget build(BuildContext context) {
    final enabled = _runtimeControlStateFromTask(widget.status) !=
            RuntimeControlState.stopped ||
        widget.status == TaskStatus.runtimeLost;
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
      status: widget.status,
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
    required this.status,
    required this.workState,
    required this.onAddContext,
    required this.onViewResult,
    required this.onResume,
    required this.onMarkCompleted,
  });

  final TaskSession task;
  final TaskStatus status;
  final WorkState? workState;
  final VoidCallback onAddContext;
  final VoidCallback onViewResult;
  final VoidCallback onResume;
  final VoidCallback onMarkCompleted;

  @override
  Widget build(BuildContext context) {
    final action = _primaryTaskActionFor(status, workState);
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
  const _AdvancedDebugPanel({required this.task, required this.status});

  final TaskSession task;
  final TaskStatus status;

  @override
  State<_AdvancedDebugPanel> createState() => _AdvancedDebugPanelState();
}

class _AdvancedDebugPanelState extends State<_AdvancedDebugPanel> {
  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final controlState = _runtimeControlStateFromTask(widget.status);
    final canResolveRuntimeLost = widget.status == TaskStatus.runtimeLost;
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
        _LazyInfoCard(
          title: 'Terminal',
          collapsedText: '远端会话 ${task.host.tmuxSessionName}',
          builder: (context) => SelectableText(
            'tmux attach -t ${task.host.tmuxSessionName}\n'
            'tmux capture-pane -p -t ${task.host.tmuxSessionName} -S -200',
            style: Theme.of(context).textTheme.bodySmall,
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

String _runtimeGoalText(TaskSession task) {
  return _cleanSnippet(task.userText, maxChars: 80);
}

String _runtimeElapsedText(TaskSession task, TaskStatus status) {
  if (_isTaskLive(status)) {
    final startedAt = task.startedAt ?? task.createdAt;
    return _elapsedLabel(DateTime.now().difference(startedAt));
  }
  final value = task.completedAt ?? task.updatedAt;
  return _timeLabel(value);
}

String _runtimeNextText(
  TaskSession task,
  TaskStatus status,
  WorkState? workState,
) {
  final latestDeliverable = task.turns.lastOrNull?.deliverable;
  return switch (runtimePhaseForTaskStatus(status)) {
    WorkPhase.needsApproval => '等待你选择审批结果',
    WorkPhase.turnIdle ||
    WorkPhase.needsInstruction =>
      latestDeliverable == null ? '补充下一步指令' : '验收结果或继续下一轮',
    WorkPhase.working => '继续观察 Agent 输出',
    WorkPhase.quieting => status == TaskStatus.paused ? '恢复任务' : '重新监听远端会话',
    WorkPhase.completed || WorkPhase.needsReview => '查看并确认结果',
    WorkPhase.failed => '查看风险并决定是否重试',
    WorkPhase.stopped => '查看历史或重新执行',
    WorkPhase.idle => status == TaskStatus.pending ? '等待计划时间启动' : '准备启动任务',
    WorkPhase.needsDecision => '等待你的决定',
  };
}

String _runtimeRiskText(TaskStatus status, WorkState? workState) {
  final approval = workState?.approval;
  if (approval?.state == ApprovalState.pending) {
    return '需要审批';
  }
  return switch (runtimePhaseForTaskStatus(status)) {
    WorkPhase.failed => '运行需要检查',
    WorkPhase.quieting => status == TaskStatus.paused ? '任务暂停' : '监听断开',
    WorkPhase.needsInstruction => '等待输入',
    WorkPhase.turnIdle => '等待验收',
    WorkPhase.working => '无用户阻塞',
    WorkPhase.completed || WorkPhase.needsReview => '等待验收',
    WorkPhase.stopped => '已停止',
    WorkPhase.idle => '未开始',
    WorkPhase.needsApproval || WorkPhase.needsDecision => '需要介入',
  };
}

String _runtimePhaseLabel(WorkPhase phase, TaskStatus status) {
  return switch (phase) {
    WorkPhase.idle => status == TaskStatus.pending ? 'Scheduled' : 'Idle',
    WorkPhase.working => 'Executing',
    WorkPhase.quieting => status == TaskStatus.paused ? 'Paused' : 'Detached',
    WorkPhase.turnIdle => 'Review',
    WorkPhase.needsApproval => 'Approval',
    WorkPhase.needsDecision => 'Decision',
    WorkPhase.needsReview => 'Review',
    WorkPhase.needsInstruction => 'Waiting',
    WorkPhase.completed => 'Finished',
    WorkPhase.failed => 'Risk',
    WorkPhase.stopped => 'Stopped',
  };
}

IconData _runtimeFocusIcon(WorkPhase phase, TaskStatus status) {
  return switch (phase) {
    WorkPhase.working => Icons.bolt_outlined,
    WorkPhase.needsApproval || WorkPhase.needsDecision => Icons.rule_outlined,
    WorkPhase.turnIdle ||
    WorkPhase.needsInstruction ||
    WorkPhase.needsReview =>
      Icons.touch_app_outlined,
    WorkPhase.quieting =>
      status == TaskStatus.paused ? Icons.pause_outlined : Icons.wifi_off,
    WorkPhase.completed => Icons.check_circle_outline,
    WorkPhase.failed => Icons.error_outline,
    WorkPhase.stopped => Icons.stop_circle_outlined,
    WorkPhase.idle => Icons.schedule_outlined,
  };
}

List<_RuntimeTimelineStepViewModel> _runtimeStepsFor(
  TaskSession task,
  TaskStatus status,
  WorkState? workState,
) {
  final phase = runtimePhaseForTaskStatus(status);
  final hasStarted = task.startedAt != null ||
      task.turns.isNotEmpty ||
      status != TaskStatus.draft;
  final hasResult = task.turns.any((turn) => turn.deliverable != null);
  final terminal = !_isTaskLive(status);
  final blocked = phase == WorkPhase.needsApproval ||
      phase == WorkPhase.needsInstruction ||
      phase == WorkPhase.failed ||
      status == TaskStatus.runtimeLost;
  return [
    _RuntimeTimelineStepViewModel(
      label: 'SSH Connected',
      state: hasStarted
          ? _RuntimeTimelineStepState.done
          : _RuntimeTimelineStepState.idle,
    ),
    _RuntimeTimelineStepViewModel(
      label: 'Planning',
      state: hasStarted
          ? _RuntimeTimelineStepState.done
          : _RuntimeTimelineStepState.active,
    ),
    _RuntimeTimelineStepViewModel(
      label: 'Executing',
      state: phase == WorkPhase.working || phase == WorkPhase.quieting
          ? _RuntimeTimelineStepState.active
          : hasStarted
              ? _RuntimeTimelineStepState.done
              : _RuntimeTimelineStepState.idle,
    ),
    _RuntimeTimelineStepViewModel(
      label: 'Review',
      state: blocked
          ? _RuntimeTimelineStepState.blocked
          : hasResult ||
                  phase == WorkPhase.turnIdle ||
                  phase == WorkPhase.needsReview
              ? _RuntimeTimelineStepState.active
              : _RuntimeTimelineStepState.idle,
    ),
    _RuntimeTimelineStepViewModel(
      label: 'Finished',
      state: terminal
          ? _RuntimeTimelineStepState.done
          : _RuntimeTimelineStepState.idle,
    ),
  ];
}

String _firstNonEmpty(List<String> values) {
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

String _detailStatusLabel(TaskStatus status, [WorkState? workState]) {
  if (workState != null && workState.headline.trim().isNotEmpty) {
    return workState.headline.trim();
  }
  switch (runtimePhaseForTaskStatus(status)) {
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
  return switch (runtimePhaseForTaskStatus(status)) {
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

String _statusTimingText(TaskSession task, TaskStatus status) {
  if (status == TaskStatus.pending && task.scheduledFor != null) {
    return _scheduledTaskLabel(task.scheduledFor!);
  }
  if (task.completedAt != null) {
    return '更新于 ${_timeLabel(task.completedAt!)}';
  }
  if (_isTaskLive(status)) {
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

String _currentSituationText(
  TaskSession task,
  TaskStatus status, [
  WorkState? workState,
]) {
  if (status == TaskStatus.pending && task.scheduledFor != null) {
    return '${_scheduledTaskLabel(task.scheduledFor!)}。';
  }
  if (workState == null) {
    return '正在同步任务状态。';
  }
  final statusText = workState.statusText.trim();
  if (statusText.isNotEmpty) return statusText;
  return switch (runtimePhaseForTaskStatus(status)) {
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
  switch (runtimePhaseForTaskStatus(status)) {
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
  switch (runtimePhaseForTaskStatus(status)) {
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

String _scheduledTaskLabel(DateTime scheduledFor) {
  final now = DateTime.now();
  if (!scheduledFor.isAfter(now)) {
    return '计划已到点，正在准备启动';
  }
  return '计划于 ${_timeLabel(scheduledFor)} 执行';
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
