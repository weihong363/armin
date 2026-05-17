import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pauseTask persists paused status', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.pauseTask(task);

    expect(agent.paused, isTrue);
    expect(store.task.status, TaskStatus.paused);
    expect(store.task.rawLog, contains('Task paused by user.'));
  });

  test('resumeTask persists running status', () async {
    final task = _task(status: TaskStatus.paused);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resumeTask(task);

    expect(agent.resumed, isTrue);
    expect(store.task.status, TaskStatus.running);
    expect(store.task.rawLog, contains('Task resumed by user.'));
  });

  test('stopTask persists stopped status', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.stopTask(task);

    expect(agent.stopped, isTrue);
    expect(store.task.status, TaskStatus.stopped);
    expect(store.task.completedAt, isNotNull);
    expect(store.task.rawLog, contains('Task stopped by user.'));
  });
}

TaskSession _task({required TaskStatus status}) {
  final now = DateTime(2026, 5, 17);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret-password',
    ),
    title: 'Task',
    status: status,
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Task',
    userText: 'Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Task',
    secretRecords: const [],
    rawLog: '',
  );
}

class _TaskStore implements TaskHistoryStore {
  _TaskStore(this.task);

  TaskSession task;

  @override
  Future<List<HostConfig>> loadHosts() async => [task.host];

  @override
  Future<List<TaskSession>> loadTasks() async => [task];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {
    this.task = task;
  }
}

class _ControlAgent implements AgentSessionService {
  bool paused = false;
  bool resumed = false;
  bool stopped = false;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {}

  @override
  Future<void> pause(AgentControlRequest request) async {
    paused = true;
  }

  @override
  Future<void> resume(AgentControlRequest request) async {
    resumed = true;
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {
    stopped = true;
  }

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'ok');
  }
}

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => '';

  @override
  Future<void> speakSummary(String summary) async {}

  @override
  Future<void> startListening({void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}
