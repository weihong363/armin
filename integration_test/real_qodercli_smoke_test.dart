import 'package:armin/app.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Real qodercli smoke — verify that Armin auto-enters turnIdle when the
/// agent produces final output and only spinner/context keeps changing.
///
/// Unlike qodercli-test, real qodercli naturally emits thinking, tool calls,
/// and spinner frames before and after the final answer. This test validates
/// that Armin's monitor correctly distinguishes "semantic output complete"
/// from "TUI chrome still refreshing".

const _seedHostId = 'host-local-mac';
const _testProjectPath =
    '/Users/ironion/workspace/armin-test/countdown_widgets';
const _realAgentCommand = r'$HOME/.local/bin/qodercli';
const _pollInterval = Duration(milliseconds: 250);
const _testSshPassword = String.fromEnvironment('ARMINTEST_SSH_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ArminAppState state;
  final taskIds = <String>[];

  Future<void> pumpApp(WidgetTester tester) async {
    state = ArminAppState.run(voiceService: const _SilentVoiceService());
    await tester.pumpWidget(ArminApp(state: state));
    await waitUntil(
      tester,
      description: 'ArminAppState ready',
      predicate: () => state.ready,
    );
    await configureRealHost(state);
  }

  Future<String> startTask(String marker) async {
    final host = testHost(state);
    final now = DateTime.now();
    final taskId = 'real-${now.microsecondsSinceEpoch}';
    final prompt = 'Do not modify files.\n'
        'Read pubspec.yaml only.\n'
        'Final answer only:\n'
        '$marker status=PASS project=countdown_widgets files_changed=0';
    final taskHost = host.copyWith(
      projectPath: _testProjectPath,
      tmuxSessionName: 'armin-$taskId',
    );
    final task = TaskSession(
      id: taskId,
      host: taskHost,
      title: 'Real qodercli smoke',
      createdAt: now,
      updatedAt: now,
      startedAt: now,
      rawSttText: '',
      cleanedDraft: 'Real qodercli smoke',
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
          payloadJson: '{"source":"real_qodercli_smoke"}',
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
    taskIds.add(taskId);
    return taskId;
  }

  tearDown(() async {
    for (final taskId in taskIds.reversed) {
      final task = state.tasks.where((t) => t.id == taskId).firstOrNull;
      if (task == null) continue;
      try {
        await state.agentSessionService.cleanup(controlRequest(state, task));
      } catch (_) {}
      final latest = state.tasks.where((t) => t.id == taskId).firstOrNull;
      if (latest != null && !_isTerminal(state.taskStatus(latest))) {
        await state.updateTaskStatus(latest, TaskStatus.stopped);
      }
    }
    taskIds.clear();
    await state.drainForTest();
    state.dispose();
  });

  // ── Real qodercli short task → auto turnIdle ──────────────────────
  testWidgets('real qodercli auto-enters turnIdle after final output',
      (tester) async {
    await pumpApp(tester);

    final marker =
        'ARMIN_REAL_TURNIDLE_${DateTime.now().millisecondsSinceEpoch}';
    final taskId = await startTask(marker);

    // Wait for task to start running
    await waitForTaskStatus(tester, state, taskId, TaskStatus.running,
        timeout: const Duration(seconds: 30));

    // Wait for task to auto-converge to turnIdle
    final stopwatch = Stopwatch()..start();
    final settled = await waitForTask(
      tester,
      state,
      taskId,
      description: 'real qodercli turnIdle after final output',
      timeout: const Duration(seconds: 90),
      predicate: (task) =>
          state.taskStatus(task) == TaskStatus.turnIdle &&
          task.turns.last.deliverable != null &&
          task.turns.last.deliverable!.displaySummary.isNotEmpty,
    );
    stopwatch.stop();

    // Verify auto-convergence: should settle without manual refresh
    expect(state.taskStatus(settled), TaskStatus.turnIdle);
    expect(state.workState(taskId)?.phase, WorkPhase.turnIdle);

    // Verify result card has the unique marker and is not polluted
    final deliverable = settled.turns.last.deliverable!;
    expect(deliverable.displaySummary, contains('status=PASS'));
    expect(deliverable.displaySummary, isNot(contains('Thinking')));
    expect(deliverable.evidenceFingerprint, isNotEmpty);

    // Verify tmux session was created
    final session = settled.host.tmuxSessionName;
    expect(session, startsWith('armin-'));
    expect(session, contains(taskId));

    // Remote session should still exist (Armin keeps it for follow-up)
    final probe = await probeTask(state, settled);
    expect(probe.sessionExists, isTrue);
  });
}

// ── Helpers ────────────────────────────────────────────────────────

Future<void> configureRealHost(ArminAppState state) async {
  final seeded =
      state.hosts.where((host) => host.id == _seedHostId).firstOrNull;
  final password = seeded?.password ?? _testSshPassword;
  if (password.isEmpty) {
    throw TestFailure(
      'Missing SSH password for $_seedHostId. Run seed-config.sh or pass '
      '--dart-define=ARMINTEST_SSH_PASSWORD.',
    );
  }
  final host = seeded ?? _testSeedHost();
  final needsUpdate = seeded == null ||
      seeded.agentCommand != _realAgentCommand ||
      seeded.password != password ||
      seeded.projectPath != _testProjectPath;
  if (needsUpdate) {
    await state.saveHost(
      host.copyWith(
        agentCommand: _realAgentCommand,
        password: password,
        projectPath: _testProjectPath,
      ),
    );
  }
  if (!state.projectPaths.any((path) => path.path == _testProjectPath)) {
    await state.saveProjectPath(_testProject());
  }
}

HostConfig testHost(ArminAppState state) {
  return state.hosts.firstWhere((host) => host.id == _seedHostId);
}

HostConfig _testSeedHost() {
  final now = DateTime.now().toUtc();
  return HostConfig(
    id: _seedHostId,
    name: 'Local Mac',
    host: '10.0.2.2',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: _testProjectPath,
    tmuxSessionName: 'armin-codex',
    agentCommand: _realAgentCommand,
    createdAt: now,
    updatedAt: now,
    isDefault: true,
    tmuxCommand: '/opt/homebrew/bin/tmux',
    pathPrepend: '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global-bin:'
        '\$HOME/.npm-packages/bin:\$HOME/.local/bin',
    shellWrapper: ShellWrapper.zshLogin,
    machineType: HostMachineType.macAppleSilicon,
  );
}

ProjectPathConfig _testProject() {
  final now = DateTime.now().toUtc();
  return ProjectPathConfig(
    id: 'project-gate-test',
    name: 'gate-test',
    path: _testProjectPath,
    createdAt: now,
    updatedAt: now,
  );
}

AgentControlRequest controlRequest(ArminAppState state, TaskSession task) {
  final host = testHost(state);
  return AgentControlRequest(
    host: host.host,
    port: host.port,
    username: host.username,
    password: host.password,
    tmuxSessionName: task.host.tmuxSessionName,
    tmuxCommand: host.tmuxCommand,
    pathPrepend: host.pathPrepend,
    shellWrapper: host.shellWrapper,
  );
}

Future<RemoteTaskProbe> probeTask(
  ArminAppState state,
  TaskSession task,
) {
  final service = state.agentSessionService;
  if (service is! RemoteTaskProbeService) {
    throw TestFailure('AgentSessionService does not support remote probes.');
  }
  return (service as RemoteTaskProbeService)
      .probeRemoteState(controlRequest(state, task));
}

Future<void> waitUntil(
  WidgetTester tester, {
  required String description,
  required bool Function() predicate,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await tester.pump(_pollInterval);
  }
  throw TestFailure('Timed out waiting for $description.');
}

Future<TaskSession> waitForTask(
  WidgetTester tester,
  ArminAppState state,
  String taskId, {
  required String description,
  required bool Function(TaskSession task) predicate,
  Duration timeout = const Duration(seconds: 30),
}) async {
  TaskSession? match;
  await waitUntil(
    tester,
    description: description,
    timeout: timeout,
    predicate: () {
      match = state.tasks.where((task) => task.id == taskId).firstOrNull;
      return match != null && predicate(match!);
    },
  );
  return match!;
}

Future<TaskSession> waitForTaskStatus(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
  TaskStatus status, {
  Duration timeout = const Duration(seconds: 30),
}) {
  return waitForTask(
    tester,
    state,
    taskId,
    description: '$taskId status ${status.name}',
    timeout: timeout,
    predicate: (task) => state.taskStatus(task) == status,
  );
}

bool _isTerminal(TaskStatus status) {
  return switch (status) {
    TaskStatus.completed ||
    TaskStatus.userCompleted ||
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.stopped ||
    TaskStatus.runtimeLost =>
      true,
    _ => false,
  };
}

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();
  @override
  bool get isAvailable => true;
  @override
  Future<String> listenOnce() async => '';
  @override
  Future<void> speakSummary(String s) async {}
  @override
  Future<void> pauseSpeaking() async {}
  @override
  Future<void> stopSpeaking() async {}
  @override
  Future<void> startListening({void Function(String)? onPartial}) async {}
  @override
  Future<String> stopListening() async => '';
}
