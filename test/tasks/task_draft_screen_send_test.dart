import 'dart:async';

import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/screens/task_draft_screen.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('real agent draft screen hides mock scenario selector',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    expect(find.text('Mock 执行结果'), findsNothing);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('send requires SSH password before creating task',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: '')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('请先在 Host 配置中填写 SSH password。'), findsOneWidget);
  });

  testWidgets('send requires project path before creating task',
      (tester) async {
    final store = _TaskStore(
      hosts: [_host(password: 'secret-password')],
      projectPaths: const [],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('请先配置并选择 Project Path。'), findsOneWidget);
  });

  testWidgets('send passes SSH password to agent request', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.password, 'secret-password');
    expect(agent.lastRequest?.projectPath, '/tmp/armin-task');
    expect(agent.lastRequest?.privateKeyPem, isNull);
    expect(store.savedTasks.last.host.projectPath, '/tmp/armin-task');
  });

  testWidgets('send normalizes home based project path', (tester) async {
    final store = _TaskStore(
      hosts: [_host(password: 'secret-password')],
      projectPaths: [_projectPath(path: '~workspace/momo')],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.projectPath, '~/workspace/momo');
    expect(store.savedTasks.last.host.projectPath, '~/workspace/momo');
  });

  testWidgets('send opens task detail before agent finishes', (tester) async {
    final waitBeforeResult = Completer<void>();
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(
      waitBeforeResult: waitBeforeResult,
    );
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(find.text('任务详情'), findsOneWidget);
    expect(agent.lastRequest, isNotNull);
    expect(store.savedTasks.last.status, TaskStatus.running);
    expect(agent.lastRequest!.tmuxSessionName, startsWith('armin-codex-'));
    expect(store.savedTasks.last.host.tmuxSessionName,
        agent.lastRequest!.tmuxSessionName);

    waitBeforeResult.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('SSH failure marks task failed and keeps raw log',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(error: StateError('ssh failed'));
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, isNotEmpty);
    expect(store.savedTasks.last.status, TaskStatus.failed);
    expect(store.savedTasks.last.rawLog, contains('ssh failed'));
    expect(store.savedTasks.last.shortSummary, contains('SSH 执行失败'));
  });

  testWidgets('done update without result marks task turn idle',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(doneWithoutResult: true);
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, isNotEmpty);
    expect(store.savedTasks.last.status, TaskStatus.turnIdle);
    expect(store.savedTasks.last.completedAt, isNull);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _TaskStore store,
  required _CaptureAgentSessionService agent,
}) async {
  final state = ArminAppState(
    store: store,
    agentSessionService: agent,
    voiceService: MockVoiceService(),
  );
  await state.load();
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: TaskDraftScreen()),
    ),
  );
  await tester.pump();
}

HostConfig _host({required String password}) {
  final now = DateTime(2026, 5, 17);
  return HostConfig(
    id: 'host-1',
    name: 'Dev',
    host: '127.0.0.1',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: '',
    tmuxSessionName: 'armin-codex',
    agentCommand: 'codex',
    createdAt: now,
    updatedAt: now,
    password: password,
  );
}

class _TaskStore implements TaskHistoryStore {
  _TaskStore({
    required List<HostConfig> hosts,
    List<ProjectPathConfig>? projectPaths,
  })  : _hosts = hosts,
        _projectPaths = projectPaths?.toList() ?? [_projectPath()];

  final List<HostConfig> _hosts;
  final List<ProjectPathConfig> _projectPaths;
  final List<TaskSession> savedTasks = [];

  @override
  Future<List<HostConfig>> loadHosts() async => List.unmodifiable(_hosts);

  @override
  Future<List<TaskSession>> loadTasks() async => List.unmodifiable(savedTasks);

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
    final index = savedTasks.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      savedTasks[index] = task;
      return;
    }
    savedTasks.add(task);
  }

  @override
  Future<void> deleteTask(String taskId) async {
    savedTasks.removeWhere((task) => task.id == taskId);
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async {
    return List.unmodifiable(_projectPaths);
  }

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    final index = _projectPaths.indexWhere((item) => item.id == projectPath.id);
    if (index >= 0) {
      _projectPaths[index] = projectPath;
      return;
    }
    _projectPaths.add(projectPath);
  }

  @override
  Future<void> deleteProjectPath(String projectPathId) async {
    _projectPaths.removeWhere((item) => item.id == projectPathId);
  }
}

ProjectPathConfig _projectPath({String path = '/tmp/armin-task'}) {
  final now = DateTime(2026, 5, 17);
  return ProjectPathConfig(
    id: 'project-1',
    name: 'Armin',
    path: path,
    createdAt: now,
    updatedAt: now,
    isDefault: true,
  );
}

class _CaptureAgentSessionService implements AgentSessionService {
  _CaptureAgentSessionService({
    this.error,
    this.doneWithoutResult = false,
    this.waitBeforeResult,
  });

  final Object? error;
  final bool doneWithoutResult;
  final Completer<void>? waitBeforeResult;
  AgentExecutionRequest? lastRequest;

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'ok');
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    lastRequest = request;
    if (error != null) {
      throw error!;
    }
    if (doneWithoutResult) {
      yield const AgentExecutionUpdate(
        rawOutput: 'SSH session ended without readable result.',
        done: true,
      );
      return;
    }
    if (waitBeforeResult != null) {
      await waitBeforeResult!.future;
    }
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

  @override
  Future<void> pause(AgentControlRequest request) async {}

  @override
  Future<void> resume(AgentControlRequest request) async {}

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}

  @override
  Future<void> cleanup(AgentControlRequest request) async {}
}
