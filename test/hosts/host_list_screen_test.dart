import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/hosts/screens/host_list_screen.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host list shows password missing state for this run',
      (tester) async {
    await _pumpHostList(tester, host: _host(password: ''));

    expect(find.textContaining('SSH password not set for this run'),
        findsOneWidget);
  });

  testWidgets('host list shows password ready state for this run',
      (tester) async {
    await _pumpHostList(tester, host: _host(password: 'secret-password'));

    expect(
        find.textContaining('SSH password ready for this run'), findsOneWidget);
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
}
