import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../../runtime/models/work_state.dart';
import '../models/task_session.dart';
import '../services/semantic_snippet_builder.dart';

class TaskCard extends StatelessWidget {
  const TaskCard({
    required this.task,
    required this.onTap,
    this.featured = false,
    this.workState,
    super.key,
  });

  final TaskSession task;
  final VoidCallback onTap;
  final bool featured;
  final WorkState? workState;

  @override
  Widget build(BuildContext context) {
    final effectiveWorkState = _effectiveWorkStateFor(task, workState);
    if (featured) {
      return _FeaturedTaskCard(
        task: task,
        workState: effectiveWorkState,
        onTap: onTap,
      );
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
                      task.displayTitle,
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
              _StatusPill(status: task.status, workState: effectiveWorkState),
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
  const _FeaturedTaskCard({
    required this.task,
    required this.workState,
    required this.onTap,
  });

  final TaskSession task;
  final WorkState? workState;
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
        oldWidget.workState?.phase != widget.workState?.phase ||
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
    final workState = widget.workState;
    final progressValue = _progressValue(task.status, workState);
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
                  _DarkBadge(status: task.status, workState: workState),
                  const Spacer(),
                  Text(
                    '${_durationPrefix(task, workState)} ${_durationLabel(task)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                task.displayTitle,
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
                    _progressLabel(task.status, workState),
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
                      _workPhaseFor(workState, task.status) == WorkPhase.working
                          ? null
                          : progressValue,
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
        switch (_workPhaseFor(widget.workState, task.status)) {
          WorkPhase.idle ||
          WorkPhase.working ||
          WorkPhase.quieting ||
          WorkPhase.turnIdle ||
          WorkPhase.needsApproval ||
          WorkPhase.needsDecision ||
          WorkPhase.needsReview ||
          WorkPhase.needsInstruction =>
            true,
          WorkPhase.completed || WorkPhase.failed || WorkPhase.stopped => false,
        };
  }
}

String _readableSummary(TaskSession task) {
  final summary = const AgentOutputCleaner().clean(task.shortSummary);
  final text = summary.isEmpty ? task.userText : summary;
  return const SemanticSnippetBuilder()
      .build(text, contentType: SnippetContentType.agentSummary, maxChars: 140)
      .visibleText;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.workState});

  final TaskStatus status;
  final WorkState? workState;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _statusColor(status, workState).withValues(alpha: 0.12),
        border: Border.all(
          color: _statusColor(status, workState).withValues(alpha: 0.28),
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, color: _statusColor(status, workState), size: 8),
            const SizedBox(width: 6),
            Text(
              _statusLabel(status, workState),
              style: TextStyle(
                color: _statusColor(status, workState),
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

class _DarkBadge extends StatelessWidget {
  const _DarkBadge({required this.status, required this.workState});

  final TaskStatus status;
  final WorkState? workState;

  @override
  Widget build(BuildContext context) {
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
              _statusLabel(status, workState),
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

double _progressValue(TaskStatus status, [WorkState? workState]) {
  return switch (_workPhaseFor(workState, status)) {
    WorkPhase.idle => 0,
    WorkPhase.working => 0.34,
    WorkPhase.quieting => 0.5,
    WorkPhase.needsApproval ||
    WorkPhase.needsDecision ||
    WorkPhase.needsInstruction ||
    WorkPhase.needsReview ||
    WorkPhase.turnIdle =>
      0.72,
    WorkPhase.completed || WorkPhase.failed || WorkPhase.stopped => 1,
  };
}

String _progressLabel(TaskStatus status, [WorkState? workState]) {
  return switch (_workPhaseFor(workState, status)) {
    WorkPhase.idle => '等待开始',
    WorkPhase.working => '运行中',
    WorkPhase.quieting => status == TaskStatus.runtimeLost ? '连接暂停' : '更新暂停',
    WorkPhase.turnIdle => '等待继续',
    WorkPhase.needsApproval || WorkPhase.needsDecision => '等待确认',
    WorkPhase.needsReview || WorkPhase.needsInstruction => '需处理',
    WorkPhase.completed => '100%',
    WorkPhase.failed => '失败',
    WorkPhase.stopped => '已停止',
  };
}

String _durationPrefix(TaskSession task, [WorkState? workState]) {
  if (task.completedAt == null &&
      switch (_workPhaseFor(workState, task.status)) {
        WorkPhase.idle ||
        WorkPhase.working ||
        WorkPhase.quieting ||
        WorkPhase.turnIdle ||
        WorkPhase.needsApproval ||
        WorkPhase.needsDecision ||
        WorkPhase.needsReview ||
        WorkPhase.needsInstruction =>
          true,
        WorkPhase.completed || WorkPhase.failed || WorkPhase.stopped => false,
      }) {
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

WorkPhase _workPhaseFor(WorkState? workState, TaskStatus fallbackStatus) {
  if (workState != null) {
    return workState.phase;
  }
  return switch (fallbackStatus) {
    TaskStatus.draft || TaskStatus.pending => WorkPhase.idle,
    TaskStatus.running => WorkPhase.working,
    TaskStatus.paused => WorkPhase.quieting,
    TaskStatus.needApproval => WorkPhase.needsApproval,
    TaskStatus.turnIdle => WorkPhase.turnIdle,
    TaskStatus.needAttention => WorkPhase.needsInstruction,
    TaskStatus.observerDetached || TaskStatus.runtimeLost => WorkPhase.quieting,
    TaskStatus.userCompleted || TaskStatus.completed => WorkPhase.completed,
    TaskStatus.userFailed || TaskStatus.failed => WorkPhase.failed,
    TaskStatus.stopped => WorkPhase.stopped,
  };
}

WorkState? _effectiveWorkStateFor(TaskSession task, WorkState? workState) {
  if (workState == null) {
    return null;
  }
  final phase = workState.phase;
  if (phase == WorkPhase.idle &&
      task.status != TaskStatus.draft &&
      task.status != TaskStatus.pending) {
    return null;
  }
  if (phase == WorkPhase.working &&
      task.status != TaskStatus.running &&
      task.status != TaskStatus.pending) {
    return null;
  }
  if ((phase == WorkPhase.completed ||
          phase == WorkPhase.failed ||
          phase == WorkPhase.stopped) &&
      !_isTaskTerminal(task.status)) {
    return null;
  }
  return workState;
}

bool _isTaskTerminal(TaskStatus status) {
  return switch (status) {
    TaskStatus.completed ||
    TaskStatus.userCompleted ||
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped ||
    TaskStatus.runtimeLost =>
      true,
    _ => false,
  };
}

String _statusLabel(TaskStatus status, [WorkState? workState]) {
  final headline = workState?.headline.trim();
  if (headline != null && headline.isNotEmpty) {
    return headline;
  }
  return switch (_workPhaseFor(workState, status)) {
    WorkPhase.idle => '等待中',
    WorkPhase.working => '运行中',
    WorkPhase.quieting => status == TaskStatus.runtimeLost ? '连接暂停' : '更新暂停',
    WorkPhase.turnIdle => '等待继续',
    WorkPhase.needsApproval || WorkPhase.needsDecision => '需确认',
    WorkPhase.needsReview => '需查看',
    WorkPhase.needsInstruction => '需处理',
    WorkPhase.completed => '已完成',
    WorkPhase.failed => '失败',
    WorkPhase.stopped => '已停止',
  };
}

Color _statusColor(TaskStatus status, [WorkState? workState]) {
  return switch (_workPhaseFor(workState, status)) {
    WorkPhase.needsApproval ||
    WorkPhase.needsDecision ||
    WorkPhase.needsReview ||
    WorkPhase.needsInstruction ||
    WorkPhase.turnIdle =>
      Colors.orange.shade700,
    WorkPhase.failed => Colors.red.shade700,
    WorkPhase.completed => Colors.green.shade700,
    WorkPhase.stopped => Colors.grey.shade700,
    WorkPhase.quieting => Colors.blueGrey.shade700,
    WorkPhase.idle || WorkPhase.working => ArminTheme.primary,
  };
}
