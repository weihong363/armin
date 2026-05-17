import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
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
    await _enterProjectPath(tester, '/tmp/armin-task');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('请先在 Host 配置中填写 SSH password。'), findsOneWidget);
  });

  testWidgets('send requires project path before creating task',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('Project path is required.'), findsOneWidget);
  });

  testWidgets('send passes SSH password to agent request', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await _enterProjectPath(tester, '/tmp/armin-task');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.password, 'secret-password');
    expect(agent.lastRequest?.projectPath, '/tmp/armin-task');
    expect(agent.lastRequest?.privateKeyPem, isNull);
    expect(store.savedTasks.last.host.projectPath, '/tmp/armin-task');
  });

  testWidgets('SSH failure marks task failed and keeps raw log',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(error: StateError('ssh failed'));
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await _enterProjectPath(tester, '/tmp/armin-task');
    await tester.tap(find.text('发送给 Codex'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, isNotEmpty);
    expect(store.savedTasks.last.status, TaskStatus.failed);
    expect(store.savedTasks.last.rawLog, contains('ssh failed'));
    expect(find.textContaining('SSH 执行失败'), findsOneWidget);
  });
}

Future<void> _enterProjectPath(WidgetTester tester, String value) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Project path'),
    value,
  );
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
  _TaskStore({required List<HostConfig> hosts}) : _hosts = hosts;

  final List<HostConfig> _hosts;
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
}

class _CaptureAgentSessionService implements AgentSessionService {
  _CaptureAgentSessionService({this.error});

  final Object? error;
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
}
