import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../agent/services/codex_output_cleaner.dart';
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
                _readableSummary(task),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Text(
                _hostLabel(task),
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

class _FeaturedTaskCard extends StatefulWidget {
  const _FeaturedTaskCard({required this.task, required this.onTap});

  final TaskSession task;
  final VoidCallback onTap;

  @override
  State<_FeaturedTaskCard> createState() => _FeaturedTaskCardState();
}

class _FeaturedTaskCardState extends State<_FeaturedTaskCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _FeaturedTaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.completedAt != widget.task.completedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    final progressValue = _progressValue(task.status);
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
        onTap: widget.onTap,
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
                    '${_durationPrefix(task)} ${_durationLabel(task)}',
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
                _readableSummary(task),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(
                    '执行进度',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _progressLabel(task.status),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value:
                      task.status == TaskStatus.running ? null : progressValue,
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

String _readableSummary(TaskSession task) {
  final summary = const CodexOutputCleaner().clean(task.shortSummary);
  return summary.isEmpty ? task.userText : summary;
}

class _DarkBadge extends StatelessWidget {
  const _DarkBadge({required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      TaskStatus.running => '运行中',
      TaskStatus.paused => '已暂停',
      TaskStatus.stopped => '已停止',
      TaskStatus.completed => '已完成',
      TaskStatus.userCompleted => '已完成',
      TaskStatus.needApproval => '需确认',
      TaskStatus.turnIdle => '等待继续',
      TaskStatus.needAttention => '需处理',
      TaskStatus.observerDetached => '已断开监听',
      TaskStatus.runtimeLost => '运行丢失',
      TaskStatus.failed => '失败',
      TaskStatus.userFailed => '失败',
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

double _progressValue(TaskStatus status) {
  return switch (status) {
    TaskStatus.completed => 1,
    TaskStatus.userCompleted => 1,
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost ||
    TaskStatus.stopped =>
      1,
    TaskStatus.paused => 0.5,
    TaskStatus.running || TaskStatus.needApproval => 0.34,
    TaskStatus.turnIdle || TaskStatus.needAttention => 0.72,
    TaskStatus.observerDetached => 0.72,
    TaskStatus.pending || TaskStatus.draft => 0,
  };
}

String _progressLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.running => '运行中',
    TaskStatus.needApproval => '等待确认',
    TaskStatus.turnIdle => '等待继续',
    TaskStatus.needAttention => '需处理',
    TaskStatus.observerDetached => '已断开监听',
    TaskStatus.paused => '已暂停',
    TaskStatus.completed => '100%',
    TaskStatus.userCompleted => '100%',
    TaskStatus.failed => '失败',
    TaskStatus.userFailed => '失败',
    TaskStatus.runtimeLost => '运行丢失',
    TaskStatus.stopped => '已停止',
    TaskStatus.pending => '等待开始',
    TaskStatus.draft => '草稿',
  };
}

String _durationPrefix(TaskSession task) {
  if (task.completedAt == null &&
      (task.status == TaskStatus.running ||
          task.status == TaskStatus.pending ||
          task.status == TaskStatus.paused ||
          task.status == TaskStatus.needApproval ||
          task.status == TaskStatus.turnIdle ||
          task.status == TaskStatus.needAttention ||
          task.status == TaskStatus.observerDetached)) {
    return '已运行';
  }
  return '总耗时';
}

String _hostLabel(TaskSession task) {
  final projectPath = task.host.projectPath.trim();
  if (projectPath.isEmpty) {
    return task.host.name;
  }
  return '${task.host.name} / $projectPath';
}
