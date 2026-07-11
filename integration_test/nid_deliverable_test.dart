import 'package:armin/app.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// NID: deliverable verification on Needs Input state.
const _seedHostId = 'host-local-mac';
const _testProjectPath = '/Users/ironion/workspace/armin-test/countdown_widgets';
const _realAgentCommand = r'$HOME/.local/bin/qodercli';
const _pollInterval = Duration(milliseconds: 250);
const _testSshPassword = String.fromEnvironment('ARMINTEST_SSH_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late ArminAppState state;

  tearDown(() async {/* keep data for manual UI inspection */});

  testWidgets('NID deliverable verification', (tester) async {
    state = ArminAppState.run(voiceService: const _SilentVoiceService());
    await tester.pumpWidget(ArminApp(state: state));
    await _wait(tester, 'ready', () => state.ready);
    await _configureHost(state);

    const marker = 'ARMIN_NEEDS_INPUT_DELIVERABLE';
    const prompt =
        'Read pubspec.yaml, lib/, and test/. Do not modify files.\n\n'
        'Output a concise Chinese project introduction, key widgets, '
        'test coverage, and acceptance conclusion.\n\n'
        'Final answer must include exactly this marker:\n'
        '$marker status=PASS files_changed=0 next=WAIT';
    final now = DateTime.now();
    final taskId = 'nid-${now.microsecondsSinceEpoch}';
    final host = state.hosts.firstWhere((h) => h.id == _seedHostId);
    final task = TaskSession(
      id: taskId,
      host: host.copyWith(
        projectPath: _testProjectPath,
        tmuxSessionName: 'armin-$taskId',
      ),
      title: 'NID Test',
      createdAt: now,
      updatedAt: now,
      startedAt: now,
      rawSttText: '',
      cleanedDraft: 'NID Test',
      userText: prompt,
      context: '',
      constraints: const {},
      finalPrompt: prompt,
      secretRecords: const [],
      approvalMode: AgentApprovalMode.aggressive,
      turns: [
        NativeOutputTurn(
          id: 'turn-$taskId-1',
          taskId: taskId,
          turnIndex: 1,
          userInput: prompt,
          rawOutput: '',
          cleanedOutput: '',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.running,
        ),
      ],
      metricEvents: [
        MetricEvent.create(
          taskId: taskId,
          eventType: 'task_created',
          payloadJson: '{"source":"nid_test"}',
          now: now,
        ),
        MetricEvent.create(
          taskId: taskId,
          eventType: 'task_started',
          payloadJson: '{"agent_command":"$_realAgentCommand"}',
          now: now,
        ),
      ],
    );
    await state.saveTask(task);
    state.startTaskExecution(
      task,
      AgentExecutionRequest(
        prompt: task.userText,
        hostId: task.host.id,
        host: task.host.host,
        port: task.host.port,
        username: task.host.username,
        password: task.host.password,
        tmuxSessionName: task.host.tmuxSessionName,
        projectPath: task.host.projectPath,
        agentCommand: task.host.agentCommand,
        pathPrepend: task.host.pathPrepend,
        shellWrapper: task.host.shellWrapper,
        tmuxCommand: task.host.tmuxCommand,
        approvalConfig: const AgentApprovalConfig(
          agentType: AgentType.qoder,
          mode: AgentApprovalMode.aggressive,
        ),
      ),
    );

    // Wait for running
    TaskSession? latest;
    await _wait(tester, 'running', () {
      latest = state.tasks.where((t) => t.id == taskId).firstOrNull;
      return latest != null && state.taskStatus(latest!) == TaskStatus.running;
    }, timeout: const Duration(seconds: 30));

    // Wait for settled (turnIdle or needAttention)
    await _wait(tester, 'settled', () {
      latest = state.tasks.where((t) => t.id == taskId).firstOrNull;
      if (latest == null) return false;
      final s = state.taskStatus(latest!);
      return (s == TaskStatus.turnIdle || s == TaskStatus.needAttention) &&
          latest!.turns.isNotEmpty;
    }, timeout: const Duration(seconds: 180));

    final settled = latest!;
    final lastTurn = settled.turns.last;

    // NID-01: deliverable must exist
    final d = lastTurn.deliverable;
    expect(d, isNotNull,
        reason: 'NID-01: deliverable must exist on Needs Input');
    expect(d!.displaySummary, isNotEmpty);
    expect(d.displaySummary, contains('status=PASS'));
    expect(d.displaySummary, contains(marker));

    // NID-02: not raw terminal spam
    expect(d.displaySummary, isNot(contains('Thinking')));
    expect(d.displaySummary, isNot(contains('Armin context governance')));

    // NID-03: no manual refresh used (never called refreshTasks)
    // NID-04: app is still alive
    expect(state.ready, isTrue);
  });
}

// ── Helpers ────────────────────────────────────────────────────────

Future<void> _configureHost(ArminAppState state) async {
  final seeded = state.hosts.where((h) => h.id == _seedHostId).firstOrNull;
  final password = seeded?.password ?? _testSshPassword;
  if (password.isEmpty) throw TestFailure('Missing SSH password');
  final host = seeded ?? HostConfig(
    id: _seedHostId,
    name: 'Local Mac',
    host: '10.0.2.2',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: _testProjectPath,
    tmuxSessionName: 'armin-codex',
    agentCommand: _realAgentCommand,
    createdAt: DateTime.now().toUtc(),
    updatedAt: DateTime.now().toUtc(),
    isDefault: true,
    tmuxCommand: '/opt/homebrew/bin/tmux',
    pathPrepend:
        '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global-bin:'
        '\$HOME/.npm-packages/bin:\$HOME/.local/bin',
    shellWrapper: ShellWrapper.zshLogin,
    machineType: HostMachineType.macAppleSilicon,
  );
  final needsUpdate = seeded == null ||
      seeded.agentCommand != _realAgentCommand ||
      seeded.password != password ||
      seeded.projectPath != _testProjectPath;
  if (needsUpdate) {
    await state.saveHost(host.copyWith(
      agentCommand: _realAgentCommand,
      password: password,
      projectPath: _testProjectPath,
    ));
  }
  if (!state.projectPaths.any((p) => p.path == _testProjectPath)) {
    await state.saveProjectPath(ProjectPathConfig(
      id: 'project-gate-test',
      name: 'gate-test',
      path: _testProjectPath,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
  }
}

Future<void> _wait(
  WidgetTester tester,
  String desc,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await tester.pump(_pollInterval);
  }
  throw TestFailure('Timed out: $desc');
}

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();
  @override bool get isAvailable => true;
  @override Future<String> listenOnce() async => '';
  @override Future<void> speakSummary(String s) async {}
  @override Future<void> pauseSpeaking() async {}
  @override Future<void> stopSpeaking() async {}
  @override Future<void> startListening({void Function(String)? onPartial}) async {}
  @override Future<String> stopListening() async => '';
}
