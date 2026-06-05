import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../history/screens/task_history_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../agent/services/codex_output_cleaner.dart';
import '../models/task_session.dart';
import '../services/semantic_snippet_builder.dart';
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
                              'Your task inbox for AI agents.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        key: const ValueKey('home-settings-button'),
                        tooltip: '设置',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => _openSettings(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InboxSummary(
                    needsAttentionCount: groups.needsAttention.length,
                    inProgressCount: groups.inProgress.length,
                  ),
                  const SizedBox(height: 22),
                  if (state.tasks.isEmpty)
                    _EmptyInbox(onCreate: () => _openNewTask(context))
                  else ...[
                    _TaskSection(
                      title: 'Needs Attention',
                      emptyText: 'No task needs you right now.',
                      tasks: groups.needsAttention,
                      onOpenTask: _openTask,
                      onAddContext: _showAddContextForTask,
                    ),
                    _TaskSection(
                      title: 'In Progress',
                      emptyText: 'No task is running right now.',
                      tasks: groups.inProgress,
                      onOpenTask: _openTask,
                      onAddContext: _showAddContextForTask,
                    ),
                    _TaskSection(
                      title: 'Recently Completed',
                      emptyText: 'No completed task yet.',
                      tasks: groups.recentlyCompleted,
                      onOpenTask: _openTask,
                      onAddContext: _showAddContextForTask,
                    ),
                  ],
                ],
              ),
      ),
      bottomNavigationBar: _HomeBottomActions(
        onNewTask: () => _openNewTask(context),
        onAddContext: () => _addContextFromHome(context),
        onHistory: () => _openHistory(context),
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

class _InboxSummary extends StatelessWidget {
  const _InboxSummary({
    required this.needsAttentionCount,
    required this.inProgressCount,
  });

  final int needsAttentionCount;
  final int inProgressCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F8F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDCECE6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.inbox_outlined, color: ArminTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$needsAttentionCount need attention · $inProgressCount running',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeBottomActions extends StatelessWidget {
  const _HomeBottomActions({
    required this.onNewTask,
    required this.onAddContext,
    required this.onHistory,
  });

  final VoidCallback onNewTask;
  final VoidCallback onAddContext;
  final VoidCallback onHistory;
  static const _buttonHeight = 72.0;

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
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: _buttonHeight,
                  child: OutlinedButton(
                    key: const ValueKey('home-add-context-button'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: onAddContext,
                    child: const _BottomActionContent(
                      icon: Icons.add_comment_outlined,
                      label: 'Add Context',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: _buttonHeight,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: onHistory,
                    child: const _BottomActionContent(
                      icon: Icons.history_outlined,
                      label: 'History',
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

class _TaskSection extends StatelessWidget {
  const _TaskSection({
    required this.title,
    required this.emptyText,
    required this.tasks,
    required this.onOpenTask,
    required this.onAddContext,
  });

  final String title;
  final String emptyText;
  final List<TaskSession> tasks;
  final void Function(BuildContext context, String taskId) onOpenTask;
  final void Function(BuildContext context, TaskSession task) onAddContext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: title),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            _SectionEmptyText(text: emptyText)
          else
            for (final task in tasks.take(4))
              _InboxTaskCard(
                task: task,
                onOpen: () => onOpenTask(context, task.id),
                onAddContext: () => onAddContext(context, task),
              ),
        ],
      ),
    );
  }
}

class _InboxTaskCard extends StatelessWidget {
  const _InboxTaskCard({
    required this.task,
    required this.onOpen,
    required this.onAddContext,
  });

  final TaskSession task;
  final VoidCallback onOpen;
  final VoidCallback onAddContext;

  @override
  Widget build(BuildContext context) {
    final variant = _cardVariantFor(task.status);
    final statusTone = _statusTone(variant);
    return Card(
      color: _cardBackground(variant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: _cardBorderColor(variant), width: 1.2),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _taskTitle(task),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  Text(
                    _taskFreshnessLabel(task),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _HumanStatusPill(
                label: _humanStatusLabel(task.status),
                color: statusTone,
                emphasized: variant == _TaskCardVariant.needsAttention,
              ),
              const SizedBox(height: 10),
              Text(
                _latestUsefulUpdate(task),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Text(
                _nextActionLabel(task.status),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: ArminTheme.ink.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _primaryActionColor(variant),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: onOpen,
                    child: Text(_primaryActionLabel(task.status)),
                  ),
                  OutlinedButton(
                    onPressed: onAddContext,
                    child: Text(_secondaryActionLabel(task.status)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HumanStatusPill extends StatelessWidget {
  const _HumanStatusPill({
    required this.label,
    required this.color,
    required this.emphasized,
  });

  final String label;
  final Color color;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SectionEmptyText extends StatelessWidget {
  const _SectionEmptyText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

enum _TaskCardVariant {
  needsAttention,
  inProgress,
  completed,
}

_TaskCardVariant _cardVariantFor(TaskStatus status) {
  return switch (_inboxGroupFor(status)) {
    _TaskInboxGroup.needsAttention => _TaskCardVariant.needsAttention,
    _TaskInboxGroup.inProgress => _TaskCardVariant.inProgress,
    _TaskInboxGroup.recentlyCompleted => _TaskCardVariant.completed,
  };
}

String _humanStatusLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => 'Needs your decision',
    TaskStatus.needAttention => 'Needs your attention',
    TaskStatus.turnIdle => 'Waiting for your next instruction',
    TaskStatus.paused => 'Paused',
    TaskStatus.observerDetached => 'Updates paused',
    TaskStatus.runtimeLost => 'Connection paused',
    TaskStatus.running => 'Running',
    TaskStatus.pending || TaskStatus.draft => 'Waiting to start',
    TaskStatus.completed || TaskStatus.userCompleted => 'Ready to review',
    TaskStatus.failed || TaskStatus.userFailed => 'Needs review',
    TaskStatus.stopped => 'Stopped',
  };
}

String _nextActionLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval ||
    TaskStatus.needAttention =>
      'Next: Review strategy',
    TaskStatus.turnIdle => 'Next: Continue with instruction',
    TaskStatus.paused => 'Next: Resume or stop',
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      'Next: Reconnect if needed',
    TaskStatus.running => 'No action needed now',
    TaskStatus.pending || TaskStatus.draft => 'Next: Wait for execution',
    TaskStatus.completed || TaskStatus.userCompleted => 'Next: Review result',
    TaskStatus.failed || TaskStatus.userFailed => 'Next: Review issue',
    TaskStatus.stopped => 'Next: View final output',
  };
}

String _primaryActionLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval ||
    TaskStatus.needAttention ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      'Review',
    TaskStatus.turnIdle || TaskStatus.paused => 'Continue',
    TaskStatus.completed || TaskStatus.userCompleted => 'View result',
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped =>
      'View details',
    TaskStatus.running || TaskStatus.pending || TaskStatus.draft => 'Open',
  };
}

String _secondaryActionLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.completed || TaskStatus.userCompleted => 'Continue',
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped =>
      'Continue',
    TaskStatus.running ||
    TaskStatus.pending ||
    TaskStatus.draft =>
      'Add context',
    _ => 'Add context',
  };
}

Color _statusTone(_TaskCardVariant variant) {
  return switch (variant) {
    _TaskCardVariant.needsAttention => Colors.orange.shade800,
    _TaskCardVariant.inProgress => ArminTheme.primary,
    _TaskCardVariant.completed => Colors.green.shade700,
  };
}

Color _cardBackground(_TaskCardVariant variant) {
  return switch (variant) {
    _TaskCardVariant.needsAttention => const Color(0xFFFFFAF1),
    _TaskCardVariant.inProgress => Colors.white,
    _TaskCardVariant.completed => const Color(0xFFF8FAF8),
  };
}

Color _cardBorderColor(_TaskCardVariant variant) {
  return switch (variant) {
    _TaskCardVariant.needsAttention => Colors.orange.shade200,
    _TaskCardVariant.inProgress => ArminTheme.border,
    _TaskCardVariant.completed => Colors.green.shade100,
  };
}

Color _primaryActionColor(_TaskCardVariant variant) {
  return switch (variant) {
    _TaskCardVariant.needsAttention => Colors.orange.shade800,
    _TaskCardVariant.inProgress => ArminTheme.primary,
    _TaskCardVariant.completed => Colors.green.shade700,
  };
}

String _taskTitle(TaskSession task) {
  final title = task.displayTitle.trim();
  if (title.isNotEmpty && title != '未命名任务') {
    return title;
  }
  return _snippetFrom(task.userText, maxChars: 48, fallback: 'Untitled task');
}

String _latestUsefulUpdate(TaskSession task) {
  final latestTurn = _latestTurnOutput(task);
  final candidates = [
    task.result?.summary ?? '',
    task.summary ?? '',
    latestTurn,
    task.shortSummary,
    task.userText,
  ];
  for (final candidate in candidates) {
    final snippet = _snippetFrom(candidate, maxChars: 150);
    if (snippet.isNotEmpty) {
      return snippet;
    }
  }
  return 'Task is ready for its next update.';
}

String _latestTurnOutput(TaskSession task) {
  for (final turn in task.turns.reversed) {
    final cleaned = turn.cleanedOutput.trim();
    if (cleaned.isNotEmpty) {
      return cleaned;
    }
    final raw = turn.rawOutput.trim();
    if (raw.isNotEmpty) {
      return raw;
    }
  }
  return '';
}

String _snippetFrom(
  String source, {
  required int maxChars,
  String fallback = '',
}) {
  final cleaned = const CodexOutputCleaner().clean(source);
  final text = const SemanticSnippetBuilder()
      .build(cleaned,
          contentType: SnippetContentType.agentSummary, maxChars: maxChars)
      .visibleText
      .trim();
  return text.isEmpty ? fallback : text;
}

String _taskFreshnessLabel(TaskSession task) {
  return _timeLabel(task.updatedAt);
}

String _timeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
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
