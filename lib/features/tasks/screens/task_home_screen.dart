import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../history/screens/task_history_screen.dart';
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
  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final groups = _groupTasks(state.tasks);
    final attentionEvents = _attentionEventsFor(state.tasks);
    final activityItems = _activityItemsFor(state.tasks);
    final completedCount = _completedSummaryCount(state.tasks);

    return Scaffold(
      body: SafeArea(
        child: !state.ready
            ? const Center(child: CircularProgressIndicator())
            : ListView(
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
                              style: Theme.of(context).textTheme.bodyMedium,
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
                  if (state.tasks.isEmpty)
                    _EmptyInbox(onCreate: () => _openNewTask(context))
                  else ...[
                    _WaitingForYouSection(
                      events: attentionEvents,
                      onOpenTask: _openTask,
                      onViewAll: () => _openTaskList(
                        context,
                        title: 'Waiting For You',
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
      bottomNavigationBar: _HomeBottomActions(
        onNewTask: () => _openNewTask(context),
        onAddContext: () => _addContextFromHome(context),
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
    final activeTasks = _activeContextTasks(AppStateScope.read(context).tasks);
    if (activeTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a task before adding context.')),
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
                'Select Task',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Choose where this context should be added.',
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
                  subtitle: Text(_humanStatusLabel(task.status)),
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
      onSubmit: (sheetContext, instruction, command) async {
        await AppStateScope.read(sheetContext).sendFollowUp(task, instruction);
        if (sheetContext.mounted) {
          ScaffoldMessenger.of(sheetContext).showSnackBar(
            SnackBar(content: Text('Context added to ${task.displayTitle}.')),
          );
        }
      },
    );
  }

  List<TaskSession> _activeContextTasks(List<TaskSession> tasks) {
    return [
      for (final task in tasks)
        if (_isContextReady(task.status)) task,
    ];
  }

  bool _isContextReady(TaskStatus status) {
    return switch (status) {
      TaskStatus.running ||
      TaskStatus.paused ||
      TaskStatus.needApproval ||
      TaskStatus.turnIdle ||
      TaskStatus.needAttention =>
        true,
      _ => false,
    };
  }

  void _openTask(BuildContext context, String taskId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: taskId),
      ),
    );
  }

  void _openNewTask(BuildContext context, {String initialTaskText = ''}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(initialTaskText: initialTaskText),
      ),
    );
  }
}

_TaskInboxGroups _groupTasks(List<TaskSession> tasks) {
  final needsAttention = <TaskSession>[];
  final inProgress = <TaskSession>[];
  final recentlyCompleted = <TaskSession>[];

  for (final task in tasks) {
    switch (_inboxGroupFor(task.status)) {
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

// UI-only mapping: collapse existing runtime statuses into inbox sections.
_TaskInboxGroup _inboxGroupFor(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval ||
    TaskStatus.needAttention ||
    TaskStatus.turnIdle ||
    TaskStatus.paused ||
    TaskStatus.observerDetached =>
      _TaskInboxGroup.needsAttention,
    TaskStatus.draft ||
    TaskStatus.pending ||
    TaskStatus.running =>
      _TaskInboxGroup.inProgress,
    TaskStatus.completed ||
    TaskStatus.userCompleted ||
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped ||
    TaskStatus.runtimeLost =>
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
    final noun = attentionCount == 1 ? 'task' : 'tasks';
    return '$attentionCount $noun need you';
  }
  if (workingCount > 0) {
    return 'Everything is moving';
  }
  if (activeCount == 0) {
    return 'Create a task and let it run';
  }
  return 'No work needs you right now';
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
  });

  final TaskSession task;
  final String title;
  final String description;
  final IconData icon;
  final Color color;
}

List<_AttentionEvent> _attentionEventsFor(List<TaskSession> tasks) {
  final events = [
    for (final task in tasks)
      if (_attentionEventFor(task) != null) _attentionEventFor(task)!,
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

_AttentionEvent? _attentionEventFor(TaskSession task) {
  return switch (task.status) {
    TaskStatus.needApproval => _AttentionEvent(
        task: task,
        reason: 'This task needs your decision.',
        primaryAction: 'Review',
        priority: 0,
      ),
    TaskStatus.turnIdle => _AttentionEvent(
        task: task,
        reason: 'Waiting for your instruction.',
        primaryAction: 'Continue',
        priority: 2,
      ),
    TaskStatus.needAttention => _AttentionEvent(
        task: task,
        reason: _needAttentionReason(task),
        primaryAction: 'Review',
        priority: 1,
      ),
    TaskStatus.failed || TaskStatus.userFailed => _AttentionEvent(
        task: task,
        reason: 'Review the issue before continuing.',
        primaryAction: 'Review Issue',
        priority: 3,
      ),
    TaskStatus.paused => _AttentionEvent(
        task: task,
        reason: 'Paused and waiting for you.',
        primaryAction: 'Resume',
        priority: 4,
      ),
    _ => null,
  };
}

String _needAttentionReason(TaskSession task) {
  if (task.terminalPrompt != null) {
    return 'Waiting for your choice.';
  }
  return 'This task needs your attention.';
}

List<_ActivityItem> _activityItemsFor(List<TaskSession> tasks) {
  final items = [
    for (final task in tasks)
      if (_activityItemFor(task) != null) _activityItemFor(task)!,
  ]..sort((a, b) => b.task.updatedAt.compareTo(a.task.updatedAt));
  return items;
}

int _completedSummaryCount(List<TaskSession> tasks) {
  return tasks
      .where(
        (task) =>
            task.status == TaskStatus.completed ||
            task.status == TaskStatus.userCompleted,
      )
      .length;
}

_ActivityItem? _activityItemFor(TaskSession task) {
  final attention = _attentionEventFor(task);
  if (attention != null) {
    return _ActivityItem(
      task: task,
      title: 'Task needs attention',
      description: attention.reason,
      icon: Icons.priority_high_rounded,
      color: Colors.orange.shade800,
    );
  }
  return switch (task.status) {
    TaskStatus.completed || TaskStatus.userCompleted => _ActivityItem(
        task: task,
        title: 'Task completed',
        description: 'Ready to review.',
        icon: Icons.task_alt_outlined,
        color: Colors.green.shade700,
      ),
    TaskStatus.running => _ActivityItem(
        task: task,
        title: task.turns.length > 1 ? 'Task continued' : 'Task resumed',
        description: 'Work is moving.',
        icon: Icons.play_circle_outline,
        color: ArminTheme.primary,
      ),
    TaskStatus.observerDetached => _ActivityItem(
        task: task,
        title: 'Updates paused',
        description: 'Reconnect when you want to follow progress again.',
        icon: Icons.wifi_off_outlined,
        color: Colors.blueGrey.shade700,
      ),
    TaskStatus.runtimeLost => _ActivityItem(
        task: task,
        title: 'Connection paused',
        description: 'The remote session is no longer available.',
        icon: Icons.link_off_outlined,
        color: Colors.blueGrey.shade700,
      ),
    TaskStatus.stopped => _ActivityItem(
        task: task,
        title: 'Task stopped',
        description: 'Review details when needed.',
        icon: Icons.stop_circle_outlined,
        color: Colors.grey.shade700,
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
          tooltip: 'Work Activity Feed',
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
      title: 'Waiting For You',
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
                      child: Text('View all ${events.length} waiting tasks'),
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
          'Everything is moving.',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'No work needs your attention right now.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          'Work keeps moving after you leave.',
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
    final noun = tasks.length == 1 ? 'task is' : 'tasks are';
    return _HomeSection(
      title: 'Running',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ArminTheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${tasks.length} $noun running'),
              const SizedBox(height: 8),
              for (final task in tasks.take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    onTap: () => onOpenTask(context, task.id),
                    child: Text(
                      '- ${_taskTitle(task)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              TextButton(
                onPressed: onViewRunning,
                child: const Text('View running'),
              ),
            ],
          ),
        ),
      ),
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
    final noun = count == 1 ? 'task' : 'tasks';
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
                child: Text('Recently completed'),
              ),
              Text('$count $noun ready to review'),
              const SizedBox(width: 10),
              TextButton(
                onPressed: onViewHistory,
                child: const Text('History'),
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
                      label: 'New Task',
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
                  tooltip: 'Add context',
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
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: tasks.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final task = tasks[index];
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: Text(
                  _taskTitle(task),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_humanStatusLabel(task.status)),
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
    final attentionCount =
        items.where((item) => _attentionEventFor(item.task) != null).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Work Activity Feed ($attentionCount)'),
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
          'Everything is moving.\n\nNo work needs your attention right now.',
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

String _humanStatusLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => 'Needs your decision',
    TaskStatus.needAttention => 'Needs your attention',
    TaskStatus.turnIdle => 'Waiting for your instruction',
    TaskStatus.paused => 'Paused',
    TaskStatus.observerDetached => 'Updates paused',
    TaskStatus.runtimeLost => 'Connection paused',
    TaskStatus.running => 'Working',
    TaskStatus.pending || TaskStatus.draft => 'Queued',
    TaskStatus.completed || TaskStatus.userCompleted => 'Ready to review',
    TaskStatus.failed || TaskStatus.userFailed => 'Needs review',
    TaskStatus.stopped => 'Stopped',
  };
}

String _taskTitle(TaskSession task) {
  final title = task.displayTitle.trim();
  if (title.isNotEmpty && title != '未命名任务') {
    return title;
  }
  final text = task.userText.trim();
  if (text.isEmpty) {
    return 'Untitled task';
  }
  return text.length <= 48 ? text : '${text.substring(0, 48)}...';
}

String _relativeTimeLabel(DateTime value) {
  final elapsed = DateTime.now().difference(value);
  if (elapsed.inDays > 0) {
    return '${elapsed.inDays}d ago';
  }
  if (elapsed.inHours > 0) {
    return '${elapsed.inHours}h ago';
  }
  if (elapsed.inMinutes > 0) {
    return '${elapsed.inMinutes}m ago';
  }
  return 'just now';
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
                'No active tasks yet.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Create a task, send it to your local or China-friendly Agent, then come back when it needs your input.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              const Text('Create first task'),
            ],
          ),
        ),
      ),
    );
  }
}
