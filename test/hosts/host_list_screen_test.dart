import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/hosts/screens/host_list_screen.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('host list shows missing secure password state', (tester) async {
    await _pumpHostList(tester, host: _host(password: ''));

    expect(find.textContaining('未保存 SSH 密码'), findsOneWidget);
  });

  testWidgets('host list shows secure password state', (tester) async {
    await _pumpHostList(tester, host: _host(password: 'secret-password'));

    expect(find.textContaining('SSH 密码已安全保存'), findsOneWidget);
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
        find.widgetWithText(TextFormField, 'secret-password'), findsOneWidget);
  });

  testWidgets('host delete is blocked while active task uses host',
      (tester) async {
    final host = _host(password: 'secret-password');
    await _pumpHostList(
      tester,
      host: host,
      tasks: [_task(host: host, status: TaskStatus.running)],
    );

    await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('无法删除主机'), findsOneWidget);
    expect(find.textContaining('请先将它们停止或完成'), findsOneWidget);
    expect(find.text('Dev'), findsOneWidget);
  });
}

Future<void> _pumpHostList(
  WidgetTester tester, {
  required HostConfig host,
  List<TaskSession> tasks = const [],
}) async {
  final state = ArminAppState(
    store: _HostStore(host, tasks: tasks),
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

TaskSession _task({
  required HostConfig host,
  required TaskStatus status,
}) {
  final now = DateTime(2026, 5, 17);
  return TaskSession(
    id: 'task-1',
    host: host,
    title: 'Active Task',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Active Task',
    userText: 'Active Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Active Task',
    secretRecords: const [],
    rawLog: '',
  );
}

class _HostStore extends TaskHistoryStore {
  _HostStore(HostConfig host, {this.tasks = const []}) : hosts = [host];

  final List<HostConfig> hosts;
  final List<TaskSession> tasks;

  @override
  Future<List<HostConfig>> loadHosts() async => List.unmodifiable(hosts);

  @override
  Future<List<TaskSession>> loadTasks() async => List.unmodifiable(tasks);

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> deleteHost(String hostId) async {
    hosts.removeWhere((item) => item.id == hostId);
  }

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
