import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../hosts/screens/host_list_screen.dart';
import '../models/task_session.dart';
import 'task_draft_screen.dart';
import '../widgets/task_card.dart';

class TaskHomeScreen extends StatelessWidget {
  const TaskHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final currentTask = _currentTask(state.tasks);
    final recentTasks = state.tasks
        .where((task) => task.id != currentTask?.id)
        .toList(growable: false);

    return Scaffold(
      body: SafeArea(
        child: !state.ready
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
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
                              'AI coding agent Shell',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Hosts',
                        icon: const Icon(Icons.settings_outlined),
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
                  const SizedBox(height: 28),
                  const _SectionHeader(title: '当前任务'),
                  const SizedBox(height: 12),
                  if (currentTask == null)
                    _EmptyCurrentTask(
                      onCreate: () => _openNewTask(context),
                    )
                  else
                    TaskCard(
                      task: currentTask,
                      featured: true,
                      onTap: () => _openTask(context, currentTask.id),
                    ),
                  Row(
                    children: [
                      const _SectionHeader(title: '最近任务'),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _openNewTask(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新任务'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final task in recentTasks)
                    TaskCard(
                      task: task,
                      onTap: () => _openTask(context, task.id),
                    ),
                ],
              ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: SizedBox(
        width: 70,
        height: 70,
        child: FloatingActionButton(
          backgroundColor: ArminTheme.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          onPressed: () => _openNewTask(context),
          child: const Icon(Icons.mic, size: 32),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        height: 76,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            label: '主机',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '我',
          ),
        ],
        onDestinationSelected: (index) {
          if (index == 2) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const HostListScreen(),
              ),
            );
          }
        },
      ),
    );
  }

  TaskSession? _currentTask(List<TaskSession> tasks) {
    for (final task in tasks) {
      if (task.status == TaskStatus.running ||
          task.status == TaskStatus.needApproval) {
        return task;
      }
    }
    return tasks.isEmpty ? null : tasks.first;
  }

  void _openTask(BuildContext context, String taskId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: taskId),
      ),
    );
  }

  void _openNewTask(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TaskDraftScreen(),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _EmptyCurrentTask extends StatelessWidget {
  const _EmptyCurrentTask({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: InkWell(
        onTap: onCreate,
        borderRadius: BorderRadius.circular(14),
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.mic_none_outlined, color: ArminTheme.primary),
              SizedBox(width: 12),
              Expanded(child: Text('暂无运行任务，点击创建新的委派任务')),
            ],
          ),
        ),
      ),
    );
  }
}
