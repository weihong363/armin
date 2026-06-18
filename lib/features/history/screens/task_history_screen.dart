import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../tasks/widgets/task_card.dart';
import 'task_detail_screen.dart';

class TaskHistoryScreen extends StatelessWidget {
  const TaskHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final tasks = state.tasks;
    return Scaffold(
      appBar: AppBar(title: const Text('历史任务')),
      body: tasks.isEmpty
          ? const Center(child: Text('暂无历史任务'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                for (final task in tasks)
                  TaskCard(
                    task: task,
                    workState: state.workState(task.id),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TaskDetailScreen(taskId: task.id),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
