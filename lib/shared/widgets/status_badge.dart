import 'package:flutter/material.dart';

import '../../core/models/task_status.dart';
import '../theme/armin_theme.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, super.key});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TaskStatus.completed => Colors.green.shade700,
      TaskStatus.userCompleted => Colors.green.shade700,
      TaskStatus.failed => Colors.red.shade700,
      TaskStatus.userFailed => Colors.red.shade700,
      TaskStatus.runtimeLost => Colors.red.shade800,
      TaskStatus.needApproval => Colors.orange.shade800,
      TaskStatus.needAttention => Colors.orange.shade800,
      TaskStatus.turnIdle => Colors.teal.shade700,
      TaskStatus.running => ArminTheme.primary,
      TaskStatus.paused => Colors.orange.shade700,
      TaskStatus.stopped => Colors.red.shade700,
      TaskStatus.pending => Colors.blueGrey.shade700,
      TaskStatus.draft => Colors.grey.shade700,
    };
    final label = switch (status) {
      TaskStatus.completed => '已完成',
      TaskStatus.userCompleted => '已完成',
      TaskStatus.failed => '失败',
      TaskStatus.userFailed => '失败',
      TaskStatus.runtimeLost => '运行丢失',
      TaskStatus.needApproval => '需确认',
      TaskStatus.needAttention => '需处理',
      TaskStatus.turnIdle => '等待继续',
      TaskStatus.running => '运行中',
      TaskStatus.paused => '已暂停',
      TaskStatus.stopped => '已停止',
      TaskStatus.pending => '等待中',
      TaskStatus.draft => '草稿',
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
