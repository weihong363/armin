import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/services/armin_app_state.dart' show HomeTaskSnapshot;
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../models/task_recurrence.dart';
import '../models/task_session.dart';
import '../services/system_calendar_service.dart';

class ScheduledTasksScreen extends StatelessWidget {
  const ScheduledTasksScreen({
    this.calendarService = const NativeSystemCalendarService(),
    super.key,
  });

  final SystemCalendarService calendarService;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.read(context);
    return Scaffold(
      appBar: AppBar(title: const Text('计划任务')),
      body: ValueListenableBuilder<HomeTaskSnapshot>(
        valueListenable: state.homeSnapshot,
        builder: (context, snapshot, _) {
          final tasks = snapshot.tasks
              .where((task) => task.scheduledFor != null)
              .toList(growable: false)
            ..sort((a, b) => a.scheduledFor!.compareTo(b.scheduledFor!));
          if (!snapshot.ready) {
            return const Center(child: CircularProgressIndicator());
          }
          if (tasks.isEmpty) {
            return const _EmptySchedule();
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              final showDate = index == 0 ||
                  !_sameDay(tasks[index - 1].scheduledFor!, task.scheduledFor!);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showDate) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Text(
                        _dateLabel(task.scheduledFor!),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                  _ScheduledTaskTile(
                    task: task,
                    onAddToCalendar: () => _addToCalendar(context, task),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TaskDetailScreen(taskId: task.id),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addToCalendar(BuildContext context, TaskSession task) async {
    final permission = await calendarService.requestPermission();
    if (!context.mounted) return;
    if (permission != SystemCalendarPermission.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要日历权限才能同步计划任务。')),
      );
      return;
    }
    await AppStateScope.read(context).saveTask(
      task.copyWith(calendarSyncEnabled: true),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已同步到系统日历。')),
    );
  }
}

class _ScheduledTaskTile extends StatelessWidget {
  const _ScheduledTaskTile({
    required this.task,
    required this.onTap,
    required this.onAddToCalendar,
  });

  final TaskSession task;
  final VoidCallback onTap;
  final VoidCallback onAddToCalendar;

  @override
  Widget build(BuildContext context) {
    final scheduledFor = task.scheduledFor!;
    return Card(
      color: ArminTheme.scheduledSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ArminTheme.scheduled),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('scheduled-task-${task.id}'),
        leading: const Icon(
          Icons.schedule_outlined,
          color: ArminTheme.scheduled,
        ),
        title: Text(task.displayTitle,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${_timeLabel(scheduledFor)} · ${_recurrenceLabel(task.recurrence)}'),
        trailing: IconButton(
          key: ValueKey('scheduled-task-calendar-${task.id}'),
          tooltip: '添加到系统日历',
          icon: const Icon(Icons.event_available_outlined),
          onPressed: onAddToCalendar,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _EmptySchedule extends StatelessWidget {
  const _EmptySchedule();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_available_outlined, size: 40),
            const SizedBox(height: 12),
            Text('暂无计划任务', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('创建任务时设置首次执行时间，即会显示在这里。'),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dateLabel(DateTime value) {
  final now = DateTime.now();
  if (_sameDay(value, now)) return '今天';
  if (_sameDay(value, now.add(const Duration(days: 1)))) return '明天';
  return '${value.month}月${value.day}日';
}

String _timeLabel(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _recurrenceLabel(TaskRecurrence recurrence) => switch (recurrence) {
      TaskRecurrence.once => '仅一次',
      TaskRecurrence.daily => '每天',
      TaskRecurrence.weekly => '每周',
    };
