import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../core/services/armin_app_state.dart' show HomeTaskSnapshot;
import '../../../shared/scroll/armin_scroll_behavior.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../history/screens/task_history_screen.dart';
import '../../runtime/models/resolved_runtime_state.dart';
import '../../runtime/models/work_state.dart';
import '../../settings/screens/settings_screen.dart';
import '../models/task_session.dart';
import '../widgets/add_context_sheet.dart';
import 'task_draft_screen.dart';

class TaskHomeScreen extends StatefulWidget {
  const TaskHomeScreen({super.key});

  @override
  State<TaskHomeScreen> createState() => _TaskHomeScreenState();
}

class _TaskHomeScreenState extends State<TaskHomeScreen> {
  static const _refreshTriggerDistance = 120.0;
  static const _topRefreshGestureHeight = 200.0;
  static const _maxTopPullOffset = 48.0;
  static const _dragUpdateThreshold = 4.0;

  bool _pageAtTop = true;
  bool _refreshTracking = false;
  bool _refreshArmed = false;
  bool _refreshing = false;
  double _refreshDragDistance = 0.0;
  double _lastRefreshPaintDistance = 0.0;

  double get _topPullOffset =>
      math.min(_refreshDragDistance * 0.35, _maxTopPullOffset);

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.read(context);

    return Scaffold(
      body: ValueListenableBuilder<HomeTaskSnapshot>(
        valueListenable: state.homeSnapshot,
        builder: (context, snapshot, _) => _buildHomeBody(context, snapshot),
      ),
      bottomNavigationBar: _HomeBottomActions(
        onNewTask: () => _openNewTask(context),
        onAddContext: () => _addContextFromHome(context),
      ),
    );
  }

  Widget _buildHomeBody(BuildContext context, HomeTaskSnapshot snapshot) {
    final state = AppStateScope.read(context);
    TaskStatus statusFor(TaskSession task) => state.taskStatus(task);
    WorkState? workStateFor(TaskSession task) {
      return resolveRuntimeState(
        task,
        taskStatus: statusFor(task),
        workState: state.workState(task.id),
      ).toWorkState(task.id);
    }

    final groups = _groupTasks(snapshot.tasks, statusFor, workStateFor);
    final attentionEvents =
        _attentionEventsFor(snapshot.tasks, statusFor, workStateFor);
    final activityItems =
        _activityItemsFor(snapshot.tasks, statusFor, workStateFor);
    final completedCount = snapshot.tasks.length;
    final activeCount = _activeTaskCount(snapshot.tasks, statusFor);
    final maxActive = state.maxActiveTasks;
    final atLimit = activeCount >= maxActive;

    return SafeArea(
      child: !snapshot.ready
          ? const Center(child: CircularProgressIndicator())
          : Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: (_) => _finishGesture(context),
              onPointerCancel: (_) => _resetGesture(),
              child: Stack(
                children: [
                  Transform.translate(
                    offset: Offset(0, _topPullOffset),
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleScrollNotification,
                      child: ListView(
                        physics: const ArminScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 148),
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  color: ArminTheme.mint,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.auto_awesome,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Armin',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(fontSize: 26),
                                    ),
                                    Text(
                                      _homeStatusLine(
                                        attentionCount: attentionEvents.length,
                                        workingCount: groups.inProgress.length,
                                        activeCount: attentionEvents.length +
                                            groups.inProgress.length,
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                    Text(
                                      atLimit
                                          ? '活跃 $activeCount/$maxActive · 已达上限'
                                          : '活跃 $activeCount/$maxActive',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: atLimit
                                                ? Colors.orange.shade700
                                                : ArminTheme.muted,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              _ActivityIconButton(
                                count: attentionEvents.length,
                                onPressed: () => _openActivityFeed(
                                  context,
                                  activityItems,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                key: const ValueKey('home-settings-button'),
                                tooltip: '设置',
                                icon: const Icon(Icons.settings_outlined),
                                onPressed: () => _openSettings(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          if (snapshot.tasks.isEmpty)
                            _EmptyInbox(onCreate: () => _openNewTask(context))
                          else ...[
                            _WaitingForYouSection(
                              events: attentionEvents,
                              onOpenTask: _openTask,
                              onViewAll: () => _openTaskList(
                                context,
                                title: '等待你处理',
                                tasks: attentionEvents
                                    .map((event) => event.task)
                                    .toList(growable: false),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _RunningSummarySection(
                              tasks: groups.inProgress,
                              onOpenTask: _openTask,
                              onViewRunning: () => _openTaskList(
                                context,
                                title: 'Running',
                                tasks: groups.inProgress,
                              ),
                            ),
                            if (completedCount > 0)
                              _CompletedSummaryRow(
                                count: completedCount,
                                onViewHistory: () => _openHistory(context),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_refreshArmed || _refreshing)
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
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  void _openHistory(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TaskHistoryScreen()),
    );
  }

  void _openActivityFeed(
    BuildContext context,
    List<_ActivityItem> activityItems,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WorkActivityFeedScreen(
          items: activityItems,
          onOpenTask: _openTask,
        ),
      ),
    );
  }

  void _openTaskList(
    BuildContext context, {
    required String title,
    required List<TaskSession> tasks,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TaskListScreen(
          title: title,
          tasks: tasks,
          onOpenTask: _openTask,
        ),
      ),
    );
  }

  Future<void> _addContextFromHome(BuildContext context) async {
    final state = AppStateScope.read(context);
    TaskStatus statusFor(TaskSession task) => state.taskStatus(task);
    WorkState? workStateFor(TaskSession task) {
      return resolveRuntimeState(
        task,
        taskStatus: statusFor(task),
        workState: state.workState(task.id),
      ).toWorkState(task.id);
    }

    final activeTasks =
        _activeContextTasks(state.tasks, statusFor, workStateFor);
    if (activeTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先创建任务再添加上下文。')),
      );
      return;
    }
    final task = activeTasks.length == 1
        ? activeTasks.single
        : await _selectTaskForContext(context, activeTasks);
    if (!context.mounted || task == null) {
      return;
    }
    _showAddContextForTask(context, task);
  }

  Future<TaskSession?> _selectTaskForContext(
    BuildContext context,
    List<TaskSession> tasks,
  ) {
    final state = AppStateScope.read(context);
    return showModalBottomSheet<TaskSession>(
      context: context,
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择任务',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '选择要将上下文添加到哪个任务',
                style: Theme.of(sheetContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              for (final task in tasks)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    task.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _humanStatusLabel(
                      state.taskStatus(task),
                      resolveRuntimeState(
                        task,
                        taskStatus: state.taskStatus(task),
                        workState: state.workState(task.id),
                      ).toWorkState(task.id),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(sheetContext).pop(task),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showAddContextForTask(BuildContext context, TaskSession task) {
    AddContextSheet.show(
      context,
      task: task,
      status: AppStateScope.read(context).taskStatus(task),
      onSubmit: (sheetContext, instruction, command) async {
        await AppStateScope.read(sheetContext).sendFollowUp(task, instruction);
        if (sheetContext.mounted) {
          ScaffoldMessenger.of(sheetContext).showSnackBar(
            SnackBar(content: Text('上下文已添加到 ${task.displayTitle}。')),
          );
        }
      },
    );
  }

  List<TaskSession> _activeContextTasks(
    List<TaskSession> tasks,
    TaskStatus Function(TaskSession task) statusFor,
    WorkState? Function(TaskSession task) workStateFor,
  ) {
    return [
      for (final task in tasks)
        if (_isContextReady(statusFor(task), workStateFor(task))) task,
    ];
  }

  bool _isContextReady(TaskStatus status, [WorkState? workState]) {
    return switch (workState?.phase ?? runtimePhaseForTaskStatus(status)) {
      WorkPhase.working ||
      WorkPhase.quieting ||
      WorkPhase.needsApproval ||
      WorkPhase.needsDecision ||
      WorkPhase.needsInstruction ||
      WorkPhase.needsReview ||
      WorkPhase.turnIdle =>
        true,
      _ => false,
    };
  }

  /// Active tasks for the user-facing limit: excludes terminal AND
  /// disconnected/idle states (paused, observerDetached, runtimeLost)
  /// that still count for internal reconcile/bridge tracking.
  static int _activeTaskCount(
    List<TaskSession> tasks,
    TaskStatus Function(TaskSession task) statusFor,
  ) {
    return tasks
        .where((task) => switch (statusFor(task)) {
              TaskStatus.completed ||
              TaskStatus.userCompleted ||
              TaskStatus.failed ||
              TaskStatus.userFailed ||
              TaskStatus.stopped ||
              TaskStatus.paused ||
              TaskStatus.observerDetached ||
              TaskStatus.runtimeLost =>
                false,
              _ => true,
            })
        .length;
  }

  void _openTask(BuildContext context, String taskId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: taskId),
      ),
    );
  }

  void _openNewTask(BuildContext context, {String initialTaskText = ''}) {
    final state = AppStateScope.read(context);
    final activeCount = _activeTaskCount(state.tasks, state.taskStatus);
    if (activeCount >= state.maxActiveTasks) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('活跃任务已达上限（$activeCount/${state.maxActiveTasks}）。'
              '请先完成或停止一些任务后再创建新任务。'),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(initialTaskText: initialTaskText),
      ),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _pageAtTop = notification.metrics.extentBefore == 0;
    }
    return false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    final canStart = _pageAtTop &&
        event.localPosition.dy <= _topRefreshGestureHeight &&
        !_refreshing;
    _refreshTracking = canStart;
    _refreshDragDistance = 0;
    _lastRefreshPaintDistance = 0;
    _refreshArmed = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_refreshTracking || event.delta.dy <= 0) {
      return;
    }
    final nextDistance = _refreshDragDistance + event.delta.dy;
    final wasArmed = _refreshArmed;
    final nextArmed = nextDistance >= _refreshTriggerDistance;
    final movedEnough = (nextDistance - _lastRefreshPaintDistance).abs() >=
        _dragUpdateThreshold;
    if (!movedEnough && wasArmed == nextArmed) {
      _refreshDragDistance = nextDistance;
      return;
    }
    setState(() {
      _refreshDragDistance = nextDistance;
      _lastRefreshPaintDistance = nextDistance;
      _refreshArmed = nextArmed;
    });
  }

  Future<void> _finishGesture(BuildContext context) async {
    if (!_refreshTracking) {
      return;
    }
    final shouldRefresh = _refreshDragDistance >= _refreshTriggerDistance;
    _refreshTracking = false;
    if (!shouldRefresh) {
      _resetGesture();
      return;
    }
    setState(() {
      _refreshing = true;
      _refreshArmed = true;
      _refreshDragDistance = _refreshTriggerDistance;
      _lastRefreshPaintDistance = _refreshTriggerDistance;
    });
    try {
      await AppStateScope.read(context).refreshTasks();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('刷新失败：\$error')),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _refreshing = false;
      _refreshArmed = false;
      _refreshDragDistance = 0;
      _lastRefreshPaintDistance = 0;
    });
  }

  void _resetGesture() {
    if (!mounted) {
      return;
    }
    setState(() {
      _refreshTracking = false;
      _refreshArmed = false;
      _refreshDragDistance = 0;
      _lastRefreshPaintDistance = 0;
    });
  }
}

_TaskInboxGroups _groupTasks(
  List<TaskSession> tasks,
  TaskStatus Function(TaskSession task) statusFor,
  WorkState? Function(TaskSession task) workStateFor,
) {
  final needsAttention = <TaskSession>[];
  final inProgress = <TaskSession>[];
  final recentlyCompleted = <TaskSession>[];

  for (final task in tasks) {
    switch (_inboxGroupFor(statusFor(task), workStateFor(task))) {
      case _TaskInboxGroup.needsAttention:
        needsAttention.add(task);
      case _TaskInboxGroup.inProgress:
        inProgress.add(task);
      case _TaskInboxGroup.recentlyCompleted:
        recentlyCompleted.add(task);
    }
  }

  return _TaskInboxGroups(
    needsAttention: needsAttention,
    inProgress: inProgress,
    recentlyCompleted: recentlyCompleted,
  );
}

// UI-only mapping: collapse runtime work phases into inbox sections.
_TaskInboxGroup _inboxGroupFor(TaskStatus status, [WorkState? workState]) {
  return switch (workState?.phase ?? runtimePhaseForTaskStatus(status)) {
    WorkPhase.needsApproval ||
    WorkPhase.needsDecision ||
    WorkPhase.needsInstruction ||
    WorkPhase.needsReview ||
    WorkPhase.turnIdle =>
      _TaskInboxGroup.needsAttention,
    WorkPhase.idle ||
    WorkPhase.working ||
    WorkPhase.quieting =>
      status == TaskStatus.paused || status == TaskStatus.observerDetached
          ? _TaskInboxGroup.needsAttention
          : _TaskInboxGroup.inProgress,
    WorkPhase.completed ||
    WorkPhase.failed ||
    WorkPhase.stopped =>
      _TaskInboxGroup.recentlyCompleted,
  };
}

enum _TaskInboxGroup {
  needsAttention,
  inProgress,
  recentlyCompleted,
}

class _TaskInboxGroups {
  const _TaskInboxGroups({
    required this.needsAttention,
    required this.inProgress,
    required this.recentlyCompleted,
  });

  final List<TaskSession> needsAttention;
  final List<TaskSession> inProgress;
  final List<TaskSession> recentlyCompleted;
}

String _homeStatusLine({
  required int attentionCount,
  required int workingCount,
  required int activeCount,
}) {
  if (attentionCount > 0) {
    return '$attentionCount 项任务需要你';
  }
  if (workingCount > 0) {
    return '一切都在推进中';
  }
  if (activeCount == 0) {
    return '创建任务，让它去跑';
  }
  return '当前没有需要你处理的事项';
}

class _AttentionEvent {
  const _AttentionEvent({
    required this.task,
    required this.reason,
    required this.primaryAction,
    required this.priority,
  });

  final TaskSession task;
  final String reason;
  final String primaryAction;
  final int priority;
}

class _ActivityItem {
  const _ActivityItem({
    required this.task,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.needsAttention,
  });

  final TaskSession task;
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final bool needsAttention;
}

List<_AttentionEvent> _attentionEventsFor(
  List<TaskSession> tasks,
  TaskStatus Function(TaskSession task) statusFor,
  WorkState? Function(TaskSession task) workStateFor,
) {
  final events = [
    for (final task in tasks)
      if (_attentionEventFor(task, statusFor(task), workStateFor(task)) != null)
        _attentionEventFor(task, statusFor(task), workStateFor(task))!,
  ];
  events.sort((a, b) {
    final priority = a.priority.compareTo(b.priority);
    if (priority != 0) {
      return priority;
    }
    return a.task.updatedAt.compareTo(b.task.updatedAt);
  });
  return events;
}

_AttentionEvent? _attentionEventFor(
  TaskSession task,
  TaskStatus status, [
  WorkState? workState,
]) {
  return switch (workState?.phase ?? runtimePhaseForTaskStatus(status)) {
    WorkPhase.needsApproval => _AttentionEvent(
        task: task,
        reason: _workStateReason(workState, '这个任务需要你做决定'),
        primaryAction: '查看',
        priority: 0,
      ),
    WorkPhase.needsDecision => _AttentionEvent(
        task: task,
        reason: _workStateReason(workState, '这个任务需要你做决定'),
        primaryAction: '查看',
        priority: 1,
      ),
    WorkPhase.turnIdle || WorkPhase.needsInstruction => _AttentionEvent(
        task: task,
        reason: _workStateReason(workState, '等待你的指示'),
        primaryAction: '继续',
        priority: 2,
      ),
    WorkPhase.needsReview => _AttentionEvent(
        task: task,
        reason: _workStateReason(workState, _needAttentionReason(workState)),
        primaryAction: '查看',
        priority: 1,
      ),
    WorkPhase.failed => _AttentionEvent(
        task: task,
        reason: '继续之前请先检查问题',
        primaryAction: '检查问题',
        priority: 3,
      ),
    WorkPhase.quieting when status == TaskStatus.paused => _AttentionEvent(
        task: task,
        reason: '已暂停，等待你处理',
        primaryAction: '恢复',
        priority: 4,
      ),
    _ => null,
  };
}

String _needAttentionReason(WorkState? workState) {
  if (workState?.approval != null) {
    return '等待你的选择';
  }
  return '这个任务需要你关注';
}

List<_ActivityItem> _activityItemsFor(
  List<TaskSession> tasks,
  TaskStatus Function(TaskSession task) statusFor,
  WorkState? Function(TaskSession task) workStateFor,
) {
  final items = [
    for (final task in tasks)
      if (_activityItemFor(task, statusFor(task), workStateFor(task)) != null)
        _activityItemFor(task, statusFor(task), workStateFor(task))!,
  ]..sort((a, b) => b.task.updatedAt.compareTo(a.task.updatedAt));
  return items;
}

_ActivityItem? _activityItemFor(
  TaskSession task,
  TaskStatus status, [
  WorkState? workState,
]) {
  final attention = _attentionEventFor(task, status, workState);
  if (attention != null) {
    return _ActivityItem(
      task: task,
      title: '任务需要关注',
      description: attention.reason,
      icon: Icons.priority_high_rounded,
      color: Colors.orange.shade800,
      needsAttention: true,
    );
  }
  return switch (workState?.phase ?? runtimePhaseForTaskStatus(status)) {
    WorkPhase.completed => _ActivityItem(
        task: task,
        title: '任务已完成',
        description: '可以查看了',
        icon: Icons.task_alt_outlined,
        color: Colors.green.shade700,
        needsAttention: false,
      ),
    WorkPhase.working => _ActivityItem(
        task: task,
        title: task.turns.length > 1 ? '任务继续' : '任务已恢复',
        description: '工作正在推进',
        icon: Icons.play_circle_outline,
        color: ArminTheme.primary,
        needsAttention: false,
      ),
    WorkPhase.quieting when status == TaskStatus.observerDetached =>
      _ActivityItem(
        task: task,
        title: '更新已暂停',
        description: '重新连接以继续追踪进度',
        icon: Icons.wifi_off_outlined,
        color: Colors.blueGrey.shade700,
        needsAttention: false,
      ),
    WorkPhase.quieting when status == TaskStatus.runtimeLost => _ActivityItem(
        task: task,
        title: '连接已暂停',
        description: '远端会话已不可用',
        icon: Icons.link_off_outlined,
        color: Colors.blueGrey.shade700,
        needsAttention: false,
      ),
    WorkPhase.stopped => _ActivityItem(
        task: task,
        title: '任务已停止',
        description: '需要时可查看详情',
        icon: Icons.stop_circle_outlined,
        color: Colors.grey.shade700,
        needsAttention: false,
      ),
    _ => null,
  };
}

class _ActivityIconButton extends StatelessWidget {
  const _ActivityIconButton({
    required this.count,
    required this.onPressed,
  });

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton.filledTonal(
          key: const ValueKey('home-activity-feed-button'),
          tooltip: '工作动态',
          icon: const Icon(Icons.notifications_none_outlined),
          onPressed: onPressed,
        ),
        if (count > 0)
          Positioned(
            right: -2,
            top: -2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.orange.shade800,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WaitingForYouSection extends StatelessWidget {
  const _WaitingForYouSection({
    required this.events,
    required this.onOpenTask,
    required this.onViewAll,
  });

  final List<_AttentionEvent> events;
  final void Function(BuildContext context, String taskId) onOpenTask;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    return _HomeSection(
      title: '等待你处理',
      child: events.isEmpty
          ? const _AttentionEmptyState()
          : Column(
              children: [
                for (final event in events.take(3))
                  _CompactTaskCard(
                    title: _taskTitle(event.task),
                    state: event.reason,
                    time: _relativeTimeLabel(event.task.updatedAt),
                    actionLabel: event.primaryAction,
                    emphasized: true,
                    onOpen: () => onOpenTask(context, event.task.id),
                  ),
                if (events.length > 3)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onViewAll,
                      child: Text('查看全部 ${events.length} 项等待任务'),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _AttentionEmptyState extends StatelessWidget {
  const _AttentionEmptyState();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '一切都在推进中',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '当前没有需要你关注的事项',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '工作会在你离开后继续推进',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ArminTheme.ink.withValues(alpha: 0.62),
              ),
        ),
      ],
    );
  }
}

class _RunningSummarySection extends StatelessWidget {
  const _RunningSummarySection({
    required this.tasks,
    required this.onOpenTask,
    required this.onViewRunning,
  });

  final List<TaskSession> tasks;
  final void Function(BuildContext context, String taskId) onOpenTask;
  final VoidCallback onViewRunning;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const SizedBox.shrink();
    }
    final visibleTasks =
        tasks.length == 1 ? tasks : tasks.take(2).toList(growable: false);
    final useGrid = tasks.length > 1;
    return _HomeSection(
      title: '运行中',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (useGrid)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final task in visibleTasks) ...[
                  Expanded(
                    child: _RunningTaskCard(
                      task: task,
                      compact: true,
                      onOpen: () => onOpenTask(context, task.id),
                    ),
                  ),
                  if (task != visibleTasks.last) const SizedBox(width: 10),
                ],
              ],
            )
          else
            _RunningTaskCard(
              task: visibleTasks.first,
              compact: false,
              onOpen: () => onOpenTask(context, visibleTasks.first.id),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onViewRunning,
              child: Text(
                tasks.length > visibleTasks.length
                    ? '查看全部 ${tasks.length} 项运行中'
                    : '查看运行中',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunningTaskCard extends StatelessWidget {
  const _RunningTaskCard({
    required this.task,
    required this.compact,
    required this.onOpen,
  });

  final TaskSession task;
  final bool compact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: ArminTheme.border),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: compact ? 104 : 76,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 14,
              12,
              compact ? 12 : 14,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _taskTitle(task),
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _RunningDot(),
                    const SizedBox(width: 6),
                    Text(
                      '正在执行',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: ArminTheme.ink.withValues(alpha: 0.66),
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RunningDot extends StatelessWidget {
  const _RunningDot();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: ArminTheme.primary,
        shape: BoxShape.circle,
      ),
      child: SizedBox(width: 8, height: 8),
    );
  }
}

class _CompletedSummaryRow extends StatelessWidget {
  const _CompletedSummaryRow({
    required this.count,
    required this.onViewHistory,
  });

  final int count;
  final VoidCallback onViewHistory;

  @override
  Widget build(BuildContext context) {
    final noun = count == 1 ? '项任务' : '项任务';
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ArminTheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text('历史任务'),
              ),
              Text('$count $noun'),
              const SizedBox(width: 10),
              TextButton(
                onPressed: onViewHistory,
                child: const Text('查看全部'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeBottomActions extends StatelessWidget {
  const _HomeBottomActions({
    required this.onNewTask,
    required this.onAddContext,
  });

  final VoidCallback onNewTask;
  final VoidCallback onAddContext;
  static const _buttonHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: ArminTheme.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: _buttonHeight,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: onNewTask,
                    child: const _BottomActionContent(
                      icon: Icons.add_task_outlined,
                      label: '新建任务',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                height: _buttonHeight,
                child: IconButton.outlined(
                  key: const ValueKey('home-add-context-button'),
                  tooltip: '添加上下文',
                  onPressed: onAddContext,
                  icon: const Icon(Icons.add_comment_outlined),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomActionContent extends StatelessWidget {
  const _BottomActionContent({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 4),
        Text(
          label,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.visible,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: title),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _CompactTaskCard extends StatelessWidget {
  const _CompactTaskCard({
    required this.title,
    required this.state,
    required this.time,
    required this.actionLabel,
    required this.emphasized,
    required this.onOpen,
  });

  final String title;
  final String state;
  final String time;
  final String actionLabel;
  final bool emphasized;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: emphasized ? const Color(0xFFFFFAF1) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: emphasized ? Colors.orange.shade200 : ArminTheme.border,
          width: emphasized ? 1.1 : 1,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight:
                                emphasized ? FontWeight.w800 : FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      time.isEmpty ? state : '$state · $time',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: ArminTheme.ink.withValues(alpha: 0.68),
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      emphasized ? Colors.orange.shade800 : ArminTheme.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: onOpen,
                child: Text(actionLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskListScreen extends StatelessWidget {
  const _TaskListScreen({
    required this.title,
    required this.tasks,
    required this.onOpenTask,
  });

  final String title;
  final List<TaskSession> tasks;
  final void Function(BuildContext context, String taskId) onOpenTask;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.read(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: tasks.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final task = tasks[index];
            final status = state.taskStatus(task);
            final workState = resolveRuntimeState(
              task,
              taskStatus: status,
              workState: state.workState(task.id),
            ).toWorkState(task.id);
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: Text(
                  _taskTitle(task),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_humanStatusLabel(status, workState)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onOpenTask(context, task.id),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WorkActivityFeedScreen extends StatelessWidget {
  const _WorkActivityFeedScreen({
    required this.items,
    required this.onOpenTask,
  });

  final List<_ActivityItem> items;
  final void Function(BuildContext context, String taskId) onOpenTask;

  @override
  Widget build(BuildContext context) {
    final attentionCount = items.where((item) => item.needsAttention).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('工作动态 ($attentionCount)'),
      ),
      body: SafeArea(
        child: items.isEmpty
            ? const _ActivityFeedEmptyState()
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _ActivityFeedItem(
                    item: item,
                    onOpen: () => onOpenTask(context, item.task.id),
                  );
                },
              ),
      ),
    );
  }
}

class _ActivityFeedEmptyState extends StatelessWidget {
  const _ActivityFeedEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          '一切都在推进中\n\n当前没有需要你关注的事项',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ActivityFeedItem extends StatelessWidget {
  const _ActivityFeedItem({
    required this.item,
    required this.onOpen,
  });

  final _ActivityItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(item.icon, color: item.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.task.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _relativeTimeLabel(item.task.updatedAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: ArminTheme.ink.withValues(alpha: 0.56),
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

String _workStateReason(WorkState? workState, String fallback) {
  final text = workState?.statusText.trim() ?? '';
  if (text.isEmpty) {
    return fallback;
  }
  return text.replaceAll('\n', ' · ');
}

String _humanStatusLabel(TaskStatus status, [WorkState? workState]) {
  final headline = workState?.headline.trim();
  if (headline != null && headline.isNotEmpty) {
    return headline;
  }
  return switch (workState?.phase ?? runtimePhaseForTaskStatus(status)) {
    WorkPhase.idle => '排队中',
    WorkPhase.working => '工作中',
    WorkPhase.quieting => status == TaskStatus.runtimeLost ? '连接已暂停' : '更新已暂停',
    WorkPhase.turnIdle => '等待你的指示',
    WorkPhase.needsApproval || WorkPhase.needsDecision => '需要你做决定',
    WorkPhase.needsReview => '需要查看',
    WorkPhase.needsInstruction => '需要你的指令',
    WorkPhase.completed => '可查看',
    WorkPhase.failed => '需要查看',
    WorkPhase.stopped => '已停止',
  };
}

String _taskTitle(TaskSession task) {
  final title = task.displayTitle.trim();
  if (title.isNotEmpty && title != '未命名任务') {
    return title;
  }
  final text = task.userText.trim();
  if (text.isEmpty) {
    return '未命名任务';
  }
  return text.length <= 48 ? text : '${text.substring(0, 48)}...';
}

String _relativeTimeLabel(DateTime value) {
  final elapsed = DateTime.now().difference(value);
  if (elapsed.inDays > 0) {
    return '${elapsed.inDays} 天前';
  }
  if (elapsed.inHours > 0) {
    return '${elapsed.inHours} 小时前';
  }
  if (elapsed.inMinutes > 0) {
    return '${elapsed.inMinutes} 分钟前';
  }
  return '刚刚';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: InkWell(
        onTap: onCreate,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.task_alt_outlined, color: ArminTheme.primary),
              const SizedBox(height: 12),
              Text(
                '还没有活跃任务',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '创建任务，发送到本地或可访问的 Agent，任务需要你时再回来处理',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              const Text('创建第一个任务'),
            ],
          ),
        ),
      ),
    );
  }
}
