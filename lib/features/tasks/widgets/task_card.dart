import 'package:flutter/material.dart';

import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../../shared/widgets/status_badge.dart';
import '../models/task_session.dart';

class TaskCard extends StatelessWidget {
  const TaskCard({
    required this.task,
    required this.onTap,
    this.featured = false,
    super.key,
  });

  final TaskSession task;
  final VoidCallback onTap;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    if (featured) {
      return _FeaturedTaskCard(task: task, onTap: onTap);
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
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
                      task.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    _timeLabel(task.createdAt),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              StatusBadge(status: task.status),
              const SizedBox(height: 8),
              Text(
                task.shortSummary.isEmpty ? task.userText : task.shortSummary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Text(
                '${task.host.name} / ${task.host.projectPath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeaturedTaskCard extends StatelessWidget {
  const _FeaturedTaskCard({required this.task, required this.onTap});

  final TaskSession task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF103D35), Color(0xFF0A2F29)],
        ),
        boxShadow: [
          BoxShadow(
            color: ArminTheme.primary.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _DarkBadge(status: task.status),
                  const Spacer(),
                  Text(
                    _durationLabel(task),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                task.shortSummary.isEmpty ? task.userText : task.shortSummary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: task.status == TaskStatus.completed ? 1 : 0.34,
                  minHeight: 8,
                  color: ArminTheme.mint,
                  backgroundColor: Colors.white.withValues(alpha: 0.22),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.terminal_outlined,
                    color: Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    task.host.agentCommand,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(width: 18),
                  const Icon(
                    Icons.dns_outlined,
                    color: Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
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

class _DarkBadge extends StatelessWidget {
  const _DarkBadge({required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      TaskStatus.running => '运行中',
      TaskStatus.completed => '已完成',
      TaskStatus.needApproval => '需确认',
      TaskStatus.failed => '失败',
      TaskStatus.pending => '等待中',
      TaskStatus.draft => '草稿',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.circle, color: ArminTheme.mint, size: 8),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _timeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _durationLabel(TaskSession task) {
  final startedAt = task.startedAt ?? task.createdAt;
  final endedAt = task.completedAt ?? DateTime.now();
  final duration = endedAt.difference(startedAt);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (minutes <= 0) {
    return '${duration.inSeconds}s';
  }
  return '${minutes}m ${seconds}s';
}
