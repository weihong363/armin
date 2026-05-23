import 'dart:async';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
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
    expect(store.task!.status, TaskStatus.paused);
    expect(store.task!.rawLog, contains('Task paused by user.'));
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
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.rawLog, contains('Task resumed by user.'));
  });

  test('resumeTask uses current host password for stored task snapshots',
      () async {
    final task = _task(status: TaskStatus.paused).copyWith(
      host: _task(status: TaskStatus.paused).host.copyWith(password: ''),
    );
    final currentHost = task.host.copyWith(password: 'secure-password');
    final store = _TaskStore(task, hosts: [currentHost]);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resumeTask(task);

    expect(agent.lastResumeRequest?.password, 'secure-password');
    expect(store.task!.status, TaskStatus.running);
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
    expect(agent.cleanedUp, isTrue);
    expect(store.task!.status, TaskStatus.stopped);
    expect(store.task!.completedAt, isNotNull);
    expect(store.task!.rawLog, contains('Task stopped by user.'));
  });

  test('updateTaskStatus can mark hung task failed', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.updateTaskStatus(task, TaskStatus.failed);

    expect(store.task!.status, TaskStatus.failed);
    expect(store.task!.completedAt, isNotNull);
    expect(store.task!.shortSummary, '用户手动标记为失败');
  });

  test('deleteTask removes task from store', () async {
    final task = _task(status: TaskStatus.userCompleted);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.deleteTask(task.id);

    expect(store.deletedTaskId, task.id);
    expect(state.tasks, isEmpty);
  });

  test('deleteTask rejects non-terminal active tasks', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(state.deleteTask(task.id), throwsStateError);

    expect(store.deletedTaskId, isNull);
    expect(state.tasks.single.id, task.id);
  });

  test('resolveApproval sends raw decision and marks task running', () async {
    final task = _task(status: TaskStatus.needApproval).copyWith(
      approval: const ApprovalRequest(
        reason: 'Need command approval',
        command: 'rm tmp.txt',
        risk: 'medium',
      ),
      approvalRequests: const [
        ApprovalRequest(
          reason: 'Need command approval',
          command: 'rm tmp.txt',
          risk: 'medium',
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resolveApproval(task, approved: true);
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastFollowUp, startsWith('APPROVAL_DECISION:'));
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.approval, isNull);
    expect(store.task!.approvalRequests.single.status, 'approved');
    expect(store.task!.rawLog, contains('Approval approved by user.'));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(agent.lastExecuteRequest?.prompt, isEmpty);
  });

  test('disconnectTask cancels active execution and records failed status',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _HangingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await state.disconnectTask(task);

    expect(agent.cancelled, isTrue);
    expect(store.task!.status, TaskStatus.failed);
    expect(store.task!.rawLog, contains('Disconnected from SSH session'));
    expect(store.task!.shortSummary, contains('用户已断开连接'));
  });

  test('completed execution cleans up tmux session after result is saved',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _CompletingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.completed);
    expect(agent.cleanedUp, isTrue);
  });

  test('turn idle update does not complete or clean up task', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _TurnIdleAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.completedAt, isNull);
    expect(agent.cleanedUp, isFalse);
  });

  test('user marked completed cleans up tmux session', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.markTaskCompleted(task);

    expect(store.task!.status, TaskStatus.userCompleted);
    expect(store.task!.completedAt, isNotNull);
    expect(agent.cleanedUp, isTrue);
  });

  test('failed execution cleans up tmux session after error is saved',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _FailingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.failed);
    expect(store.task!.rawLog, contains('ssh failed'));
    expect(agent.cleanedUp, isTrue);
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
  _TaskStore(this.task, {List<HostConfig>? hosts}) : _hosts = hosts;

  TaskSession? task;
  String? deletedTaskId;
  final List<HostConfig>? _hosts;

  @override
  Future<List<HostConfig>> loadHosts() async {
    return _hosts ?? [if (task != null) task!.host];
  }

  @override
  Future<List<TaskSession>> loadTasks() async => [if (task != null) task!];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {
    this.task = task;
  }

  @override
  Future<void> deleteTask(String taskId) async {
    deletedTaskId = taskId;
    if (task?.id == taskId) {
      task = null;
    }
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {}

  @override
  Future<void> deleteProjectPath(String projectPathId) async {}
}

class _ControlAgent implements AgentSessionService {
  bool paused = false;
  bool resumed = false;
  bool stopped = false;
  bool cleanedUp = false;
  String? lastFollowUp;
  AgentControlRequest? lastResumeRequest;
  AgentExecutionRequest? lastExecuteRequest;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    lastExecuteRequest = request;
  }

  @override
  Future<void> pause(AgentControlRequest request) async {
    paused = true;
  }

  @override
  Future<void> resume(AgentControlRequest request) async {
    resumed = true;
    lastResumeRequest = request;
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    lastFollowUp = request.instruction;
  }

  @override
  Future<void> stop(AgentControlRequest request) async {
    stopped = true;
    await cleanup(request);
  }

  @override
  Future<void> cleanup(AgentControlRequest request) async {
    cleanedUp = true;
  }

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'ok');
  }
}

class _CompletingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'done',
      result: TaskResult(
        status: 'success',
        summary: 'done',
        changedFiles: [],
        validation: [],
        risks: [],
        nextActions: [],
      ),
      done: true,
    );
  }
}

class _FailingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    throw StateError('ssh failed');
  }
}

class _TurnIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'hello',
      cleanedOutput: 'hello',
      turnIdle: true,
      done: true,
    );
  }
}

class _HangingAgent extends _ControlAgent {
  bool cancelled = false;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    final controller = StreamController<AgentExecutionUpdate>(
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
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
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}
