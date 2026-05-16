import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../hosts/screens/host_list_screen.dart';
import 'task_draft_screen.dart';
import '../widgets/task_card.dart';

class TaskHomeScreen extends StatelessWidget {
  const TaskHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final runningTasks = state.tasks
        .where((task) => task.status == TaskStatus.running)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Armin'),
        actions: [
          IconButton(
            tooltip: 'Hosts',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const HostListScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: !state.ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Task Queue',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Voice-first delegation, full audit trail.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Host shortcut'),
                  subtitle: Text(
                    '${state.defaultHost.name} · ${state.defaultHost.projectPath}',
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const HostListScreen(),
                      ),
                    );
                  },
                ),
                if (runningTasks.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Running task',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final task in runningTasks)
                    TaskCard(
                      task: task,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TaskDetailScreen(taskId: task.id),
                          ),
                        );
                      },
                    ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Recent tasks',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final task in state.tasks)
                  TaskCard(
                    task: task,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TaskDetailScreen(taskId: task.id),
                        ),
                      );
                    },
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.mic_outlined),
        label: const Text('New Task'),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const TaskDraftScreen(),
            ),
          );
        },
      ),
    );
  }
}
