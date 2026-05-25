import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/hosts/screens/host_list_screen.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host list shows password missing state for this run',
      (tester) async {
    await _pumpHostList(tester, host: _host(password: ''));

    expect(find.textContaining('本次运行未设置 SSH 密码'), findsOneWidget);
  });

  testWidgets('host list shows password ready state for this run',
      (tester) async {
    await _pumpHostList(tester, host: _host(password: 'secret-password'));

    expect(find.textContaining('本次运行已准备 SSH 密码'), findsOneWidget);
  });

  testWidgets('host list can duplicate host config', (tester) async {
    await _pumpHostList(tester, host: _host(password: 'secret-password'));

    await tester.tap(find.byTooltip('主机操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制配置'));
    await tester.pumpAndSettle();

    expect(find.text('添加主机'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Dev Copy'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'armin-codex-copy'),
      findsOneWidget,
    );
    expect(
        find.widgetWithText(TextFormField, 'secret-password'), findsOneWidget);
  });
}

Future<void> _pumpHostList(
  WidgetTester tester, {
  required HostConfig host,
}) async {
  final state = ArminAppState(
    store: _HostStore(host),
    agentSessionService: MockAgentSessionService(),
    voiceService: MockVoiceService(),
  );
  await state.load();
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: HostListScreen()),
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
    projectPath: '/tmp/armin',
    tmuxSessionName: 'armin-codex',
    agentCommand: 'codex',
    createdAt: now,
    updatedAt: now,
    password: password,
  );
}

class _HostStore implements TaskHistoryStore {
  _HostStore(this.host);

  final HostConfig host;

  @override
  Future<List<HostConfig>> loadHosts() async => [host];

  @override
  Future<List<TaskSession>> loadTasks() async => [];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {}

  @override
  Future<void> deleteTask(String taskId) async {}

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {}

  @override
  Future<void> deleteProjectPath(String projectPathId) async {}
}
