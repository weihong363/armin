import 'package:flutter/material.dart';

import '../../core/models/task_status.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, super.key});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TaskStatus.completed => Colors.green.shade700,
      TaskStatus.failed => Colors.red.shade700,
      TaskStatus.needApproval => Colors.orange.shade800,
      TaskStatus.running => Colors.blue.shade700,
      TaskStatus.pending => Colors.blueGrey.shade700,
      TaskStatus.draft => Colors.grey.shade700,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          status.label,
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
