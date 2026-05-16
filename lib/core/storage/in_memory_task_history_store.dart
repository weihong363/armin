import '../../features/agent/parsers/task_result.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/metric_event.dart';
import '../../features/tasks/models/secret_entry.dart';
import '../../features/tasks/models/task_constraint.dart';
import '../../features/tasks/models/task_session.dart';
import '../models/task_status.dart';
import 'task_history_store.dart';

class InMemoryTaskHistoryStore implements TaskHistoryStore {
  InMemoryTaskHistoryStore() {
    _hosts.add(HostConfig.mock());
    _tasks.add(_mockTask(_hosts.first));
  }

  final List<HostConfig> _hosts = [];
  final List<TaskSession> _tasks = [];

  @override
  Future<List<HostConfig>> loadHosts() async => List.unmodifiable(_hosts);

  @override
  Future<List<TaskSession>> loadTasks() async => List.unmodifiable(_tasks);

  @override
  Future<void> saveHost(HostConfig host) async {
    final index = _hosts.indexWhere((item) => item.id == host.id);
    if (index >= 0) {
      _hosts[index] = host;
      return;
    }
    _hosts.add(host);
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    final index = _tasks.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      _tasks[index] = task;
      return;
    }
    _tasks.insert(0, task);
  }

  TaskSession _mockTask(HostConfig host) {
    final now = DateTime.now();
    return TaskSession(
      id: 'task-mock-1',
      host: host,
      title: 'Inspect login failure',
      status: TaskStatus.completed,
      createdAt: now.subtract(const Duration(minutes: 18)),
      updatedAt: now.subtract(const Duration(minutes: 15)),
      rawSttText: '嗯 帮我先看看登录为什么失败，先别大改，跑一下测试，别提交',
      cleanedDraft: '帮我先看看登录为什么失败，先别大改，跑一下测试，别提交',
      userText: '帮我先看看登录为什么失败，先别大改，跑一下测试，别提交',
      context: 'Android first MVP mock item.',
      constraints: const {
        TaskConstraint.analyzeOnly,
        TaskConstraint.minimalChange,
        TaskConstraint.runTestsAfterChanges,
        TaskConstraint.noGitCommit,
      },
      finalPrompt: 'Mock prompt archived for Phase 1.',
      secretRecords: const [
        SecretRedactedRecord(
          name: 'GITHUB_TOKEN',
          usage: 'Only if GitHub API is needed',
          placeholder: 'GITHUB_TOKEN: [REDACTED]',
          oneTimeOnly: true,
        ),
      ],
      rawLog:
          'Mock agent accepted task.\nTASK_RESULT_START\n...\nTASK_RESULT_END',
      shortSummary: 'Mock login failure investigation completed.',
      startedAt: now.subtract(const Duration(minutes: 18)),
      completedAt: now.subtract(const Duration(minutes: 15)),
      summary: 'Mock login failure investigation completed.',
      metricEvents: [
        MetricEvent.create(
          taskId: 'task-mock-1',
          eventType: 'task_created',
          payloadJson: '{"source":"mock"}',
          now: now.subtract(const Duration(minutes: 18)),
        ),
        MetricEvent.create(
          taskId: 'task-mock-1',
          eventType: 'task_completed',
          payloadJson: '{"result_status":"success"}',
          now: now.subtract(const Duration(minutes: 15)),
        ),
      ],
      result: const TaskResult(
        status: 'success',
        summary: 'Mock login failure investigation completed.',
        changedFiles: ['lib/features/tasks/screens/task_draft_screen.dart'],
        validation: ['Mock validation passed.'],
        risks: ['SSH is not wired in Phase 1.'],
        nextActions: ['Implement SSHAgentSessionService in Phase 2.'],
      ),
    );
  }
}
