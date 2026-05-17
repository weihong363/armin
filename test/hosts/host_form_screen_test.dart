import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/hosts/screens/host_form_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host form saves password auth config in memory', (tester) async {
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: HostFormScreen()),
      ),
    );

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Host name'), 'Dev');
    await _enterIpAddress(tester, const ['127', '0', '0', '1']);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'), 'ironion');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'SSH password'), 'secret-password');
    await tester.scrollUntilVisible(
      find.text('Save Host'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save Host'));
    await tester.pumpAndSettle();

    // Reload hosts to get the latest data
    await state.load();

    final saved = state.hosts.firstWhere((host) => host.name == 'Dev');
    expect(saved.authType, HostAuthType.password);
    expect(saved.host, '127.0.0.1');
    expect(saved.projectPath, isEmpty);
    expect(saved.password, 'secret-password');
    expect(saved.privateKeyPath, isEmpty);
  });

  testWidgets('host form only shows password auth fields', (tester) async {
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: HostFormScreen()),
      ),
    );

    expect(find.text('Auth type'), findsNothing);
    expect(find.text('Private key path'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'SSH password'), findsOneWidget);
  });

  testWidgets('host form tests SSH connection with current password',
      (tester) async {
    final agent = _ConnectionTestAgent();
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: agent,
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: HostFormScreen()),
      ),
    );

    await _enterIpAddress(tester, const ['127', '0', '0', '1']);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'), 'ironion');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'SSH password'), 'secret-password');
    await tester.scrollUntilVisible(
      find.text('Test SSH Connection'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Test SSH Connection'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.host, '127.0.0.1');
    expect(agent.lastRequest?.username, 'ironion');
    expect(agent.lastRequest?.password, 'secret-password');
    expect(find.text('SSH connection succeeded.'), findsOneWidget);
  });

  testWidgets('host form does not test SSH connection without password',
      (tester) async {
    final agent = _ConnectionTestAgent();
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: agent,
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: HostFormScreen()),
      ),
    );

    await _enterIpAddress(tester, const ['127', '0', '0', '1']);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'), 'ironion');
    await tester.scrollUntilVisible(
      find.text('Test SSH Connection'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Test SSH Connection'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(find.text('Host, username, and SSH password are required.'),
        findsOneWidget);
  });
}

Future<void> _enterIpAddress(
  WidgetTester tester,
  List<String> segments,
) async {
  for (var index = 0; index < segments.length; index++) {
    await tester.enterText(
      find.byKey(ValueKey('host-ip-segment-$index')),
      segments[index],
    );
  }
}

class _ConnectionTestAgent implements AgentSessionService {
  AgentConnectionTestRequest? lastRequest;

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    lastRequest = request;
    return const AgentConnectionTestResult(
      success: true,
      message: 'SSH connection succeeded.',
    );
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {}

  @override
  Future<void> pause(AgentControlRequest request) async {}

  @override
  Future<void> resume(AgentControlRequest request) async {}

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}
}
