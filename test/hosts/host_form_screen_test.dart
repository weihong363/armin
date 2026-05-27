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

    await tester.enterText(find.widgetWithText(TextFormField, '主机名称'), 'Dev');
    await _enterIpAddress(tester, const ['127', '0', '0', '1']);
    await tester.enterText(
        find.widgetWithText(TextFormField, '用户名'), 'ironion');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'SSH 密码'), 'secret-password');
    await tester.scrollUntilVisible(
      find.text('保存主机'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存主机'));
    await tester.pumpAndSettle();

    // Reload hosts to get the latest data
    await state.load();

    final saved = state.hosts.firstWhere((host) => host.name == 'Dev');
    expect(saved.authType, HostAuthType.password);
    expect(saved.host, '127.0.0.1');
    expect(saved.projectPath, isEmpty);
    expect(saved.password, 'secret-password');
    expect(saved.privateKeyPath, isEmpty);
    expect(saved.tmuxCommand, 'tmux');
    expect(saved.pathPrepend, isEmpty);
    expect(saved.shellWrapper, ShellWrapper.none);
    expect(saved.machineType, HostMachineType.generic);
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
    expect(find.text('tmux 会话名称'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'SSH 密码'), findsOneWidget);
    expect(
      find.text('如果 tmux 在 SSH 应用中可用、但在 Armin 中不可用，请在这里设置 tmux 路径或补充 PATH。'),
      findsOneWidget,
    );
    expect(find.text('主机类型'), findsOneWidget);
  });

  testWidgets('host type applies default tmux command path', (tester) async {
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

    await tester.scrollUntilVisible(
      find.text('主机类型'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('通用 / 自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('macOS Apple Silicon').last);
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextFormField, '/opt/homebrew/bin/tmux'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(
        TextFormField,
        '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextFormField, r'$HOME/.npm-global/bin/codex'),
      findsOneWidget,
    );
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
        find.widgetWithText(TextFormField, '用户名'), 'ironion');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'SSH 密码'), 'secret-password');
    await tester.scrollUntilVisible(
      find.text('测试 SSH 连接'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('测试 SSH 连接'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.host, '127.0.0.1');
    expect(agent.lastRequest?.username, 'ironion');
    expect(agent.lastRequest?.password, 'secret-password');
    expect(agent.lastRequest?.tmuxCommand, 'tmux');
    expect(agent.lastRequest?.agentCommand, 'codex');
    expect(agent.lastRequest?.pathPrepend, isEmpty);
    expect(agent.lastRequest?.shellWrapper, ShellWrapper.none);
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
        find.widgetWithText(TextFormField, '用户名'), 'ironion');
    await tester.scrollUntilVisible(
      find.text('测试 SSH 连接'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('测试 SSH 连接'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(find.text('请填写有效主机 IP、用户名和 SSH 密码。'), findsOneWidget);
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
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    return const AgentInstructionDiscoveryResult(paths: []);
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
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}

  @override
  Future<void> cleanup(AgentControlRequest request) async {}

  @override
  Future<String> captureLog(AgentControlRequest request) async => '';
}
