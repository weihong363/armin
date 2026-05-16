import 'package:flutter/material.dart';

import '../../../shared/widgets/status_badge.dart';
import '../models/task_session.dart';

class TaskCard extends StatelessWidget {
  const TaskCard({
    required this.task,
    required this.onTap,
    super.key,
  });

  final TaskSession task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
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
                  StatusBadge(status: task.status),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                task.shortSummary.isEmpty ? task.userText : task.shortSummary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              Text(
                '${task.host.name} · ${task.host.projectPath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'followups 0 · approvals ${task.approvalRequests.length} · '
                'events ${task.metricEvents.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
