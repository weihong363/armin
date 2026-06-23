import 'package:armin/app.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/runtime/models/approval_state.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Phase 2.6 Runtime gate automation on emulator-5554.
///
/// This suite uses the production SSH/tmux/Runtime/SQLite path with a
/// deterministic interactive test agent. B07 remains a manual audio gate.
///
/// Prerequisites:
///   1. seed-config.sh has installed the host and SSH password.
///   2. This checkout is visible on the SSH host at [_testAgentCommand].
///   3. [_testProjectPath] exists on the SSH host.
const _seedHostId = 'host-local-mac';
const _testProjectPath =
    '/Users/ironion/workspace/armin-test/countdown_widgets';
const _testAgentCommand =
    '/Users/ironion/workspace/armin/scripts/qodercli-test';
const _pollInterval = Duration(milliseconds: 250);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ArminAppState state;
  final taskIds = <String>[];

  Future<void> pumpApp(WidgetTester tester) async {
    // Inject silent voice service so non-B07 gates never trigger real TTS.
    state = ArminAppState.run(voiceService: const _SilentVoiceService());
    await tester.pumpWidget(ArminApp(state: state));
    await waitUntil(
      tester,
      description: 'ArminAppState ready',
      predicate: () => state.ready,
    );
    await configureTestHost(state);
  }

  Future<String> startTask(
    String mode,
    String marker, {
    AgentApprovalMode approvalMode = AgentApprovalMode.safe,
    int durationSeconds = 10,
  }) async {
    final host = testHost(state);
    final now = DateTime.now();
    final taskId = 'gate-${now.microsecondsSinceEpoch}';
    final prompt = testPrompt(
      mode,
      marker,
      durationSeconds: durationSeconds,
    );
    final taskHost = host.copyWith(
      projectPath: _testProjectPath,
      tmuxSessionName: 'armin-$taskId',
    );
    final task = buildTask(
      taskId: taskId,
      host: taskHost,
      prompt: prompt,
      approvalMode: approvalMode,
      now: now,
    );
    await state.saveTask(task);
    state.startTaskExecution(
      task,
      executionRequest(task, approvalMode),
    );
    taskIds.add(taskId);
    return taskId;
  }

  tearDown(() async {
    // 1. Stop observers and clean up remote tmux sessions.
    for (final taskId in taskIds.reversed) {
      final task =
          state.tasks.where((item) => item.id == taskId).firstOrNull;
      if (task == null) continue;
      try {
        await state.agentSessionService.cleanup(controlRequest(state, task));
      } catch (_) {
        // Best-effort cleanup; preserve the original gate failure.
      }
      final latest =
          state.tasks.where((item) => item.id == taskId).firstOrNull;
      if (latest != null && !_isTerminal(latest.status)) {
        await state.updateTaskStatus(latest, TaskStatus.stopped);
      }
    }
    taskIds.clear();

    // 2. Drain pending observer subscriptions and Runtime sync chains
    //    so no async callback fires after dispose.
    await state.drainForTest();

    // 3. Dispose last.
    state.dispose();
  });

  group('B01 - automatic state convergence', () {
    testWidgets('settles while only volatile TUI chrome keeps changing',
        (tester) async {
      await pumpApp(tester);
      const marker = 'P26-B01-D1-AUTO';
      final taskId = await startTask('spinner-and-final', marker);

      await waitForTaskStatus(tester, state, taskId, TaskStatus.running);
      final remote = await waitForRemoteMarker(tester, state, taskId, marker);
      expect(remote.sessionExists, isTrue);

      final stopwatch = Stopwatch()..start();
      final settled = await waitForTask(
        tester,
        state,
        taskId,
        description: 'B01 turnIdle with current-turn deliverable',
        timeout: const Duration(seconds: 8),
        predicate: (task) =>
            task.status == TaskStatus.turnIdle &&
            deliverableContains(task, marker),
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
      expect(settled.turns.last.rawOutput, contains(marker));
      expect(state.workState(taskId)?.phase, WorkPhase.turnIdle);
    });
  });

  group('B02 - follow-up continuity', () {
    testWidgets('uses one task and tmux session for two turns', (tester) async {
      await pumpApp(tester);
      const firstMarker = 'P26-B02-D1-AUTO';
      const secondMarker = 'P26-B02-D2-AUTO';
      final taskId = await startTask('final', firstMarker);

      final first = await waitForDeliverable(
        tester,
        state,
        taskId,
        firstMarker,
      );
      final session = first.host.tmuxSessionName;
      await state.sendFollowUp(
        first,
        testPrompt('final', secondMarker),
      );
      await waitForTask(
        tester,
        state,
        taskId,
        description: 'B02 second turn running',
        predicate: (task) =>
            task.turns.length == 2 && task.status == TaskStatus.running,
      );
      final second = await waitForDeliverable(
        tester,
        state,
        taskId,
        secondMarker,
      );

      expect(second.host.tmuxSessionName, session);
      expect(second.turns, hasLength(2));
      expect(second.turns[0].deliverable?.displaySummary,
          allOf(contains(firstMarker), isNot(contains(secondMarker))));
      expect(second.turns[1].deliverable?.displaySummary,
          allOf(contains(secondMarker), isNot(contains(firstMarker))));
      expect(await remoteOutput(state, second), contains(secondMarker));

      await tester.pump(const Duration(seconds: 3));
      expect(currentTask(state, taskId).status, TaskStatus.turnIdle);
    });
  });

  group('B03 - native approval lifecycle', () {
    for (final mode in AgentApprovalMode.values) {
      testWidgets('${mode.name} resolves one terminal approval',
          (tester) async {
        await pumpApp(tester);
        final marker = 'P26-B03-${mode.name.toUpperCase()}-AUTO';
        final taskId = await startTask(
          'approval',
          marker,
          approvalMode: mode,
        );
        final pending = await waitForTask(
          tester,
          state,
          taskId,
          description: 'B03 ${mode.name} pending approval',
          predicate: (task) =>
              task.status == TaskStatus.needApproval &&
              state.workState(taskId)?.approval?.state == ApprovalState.pending,
        );
        final approval = state.workState(taskId)!.approval!;
        expect(approval.question, isNotEmpty);
        expect(approval.options, isNotEmpty);

        await state.resolveApproval(pending, approved: true);
        await waitForRemoteMarker(tester, state, taskId, marker);
        await waitUntil(
          tester,
          description: 'B03 ${mode.name} approval resolved',
          predicate: () =>
              state.runtimeDiagnostics(taskId)?.approvalState ==
              ApprovalState.resolved,
        );

        final currentApproval = state.workState(taskId)?.approval;
        expect(currentApproval?.state, isNot(ApprovalState.pending));
        expect(await remoteOutput(state, currentTask(state, taskId)),
            contains('Received choice:'));
      });
    }
  });

  group('B04 - task controls', () {
    testWidgets('pause/resume and detach/reconnect keep the same session',
        (tester) async {
      await pumpApp(tester);
      final taskId = await startTask(
        'spinner-only',
        'P26-B04-CONTROL-AUTO',
      );
      final running =
          await waitForTaskStatus(tester, state, taskId, TaskStatus.running);
      final session = running.host.tmuxSessionName;

      await state.pauseTask(running);
      await waitForTaskStatus(tester, state, taskId, TaskStatus.paused);
      expect((await probeTask(state, currentTask(state, taskId))).sessionExists,
          isTrue);

      await state.resumeTask(currentTask(state, taskId));
      await waitForTaskStatus(tester, state, taskId, TaskStatus.running);
      expect(currentTask(state, taskId).host.tmuxSessionName, session);

      await state.disconnectTask(currentTask(state, taskId));
      await waitForTaskStatus(
        tester,
        state,
        taskId,
        TaskStatus.observerDetached,
      );
      expect((await probeTask(state, currentTask(state, taskId))).sessionExists,
          isTrue);

      await state.reconnectTask(currentTask(state, taskId));
      await waitForTaskStatus(tester, state, taskId, TaskStatus.running);
      expect(currentTask(state, taskId).host.tmuxSessionName, session);
    });

    testWidgets('stop captures state and removes the tmux session',
        (tester) async {
      await pumpApp(tester);
      final taskId = await startTask('spinner-only', 'P26-B04-STOP-AUTO');
      final running =
          await waitForTaskStatus(tester, state, taskId, TaskStatus.running);

      await state.stopTask(running);
      expect(currentTask(state, taskId).status, TaskStatus.stopped);
      expect((await probeTask(state, currentTask(state, taskId))).sessionExists,
          isFalse);
    });

    for (final completed in [true, false]) {
      testWidgets(
          'mark ${completed ? 'completed' : 'failed'} persists and cleans',
          (tester) async {
        await pumpApp(tester);
        final marker =
            completed ? 'P26-B04-COMPLETE-AUTO' : 'P26-B04-FAILED-AUTO';
        final taskId = await startTask('spinner-only', marker);
        final running =
            await waitForTaskStatus(tester, state, taskId, TaskStatus.running);

        if (completed) {
          await state.markTaskCompleted(running);
        } else {
          await state.markTaskFailed(running);
        }
        final expected =
            completed ? TaskStatus.userCompleted : TaskStatus.userFailed;
        expect(currentTask(state, taskId).status, expected);
        expect(
            (await probeTask(state, currentTask(state, taskId))).sessionExists,
            isFalse);
      });
    }
  });

  group('B06 - per-turn deliverables', () {
    testWidgets('each turn owns its marker and evidence fingerprint',
        (tester) async {
      await pumpApp(tester);
      const firstMarker = 'P26-B06-D1-AUTO';
      const secondMarker = 'P26-B06-D2-AUTO';
      final taskId = await startTask('final', firstMarker);
      final first =
          await waitForDeliverable(tester, state, taskId, firstMarker);

      await state.sendFollowUp(first, testPrompt('final', secondMarker));
      final second =
          await waitForDeliverable(tester, state, taskId, secondMarker);
      final firstResult = second.turns[0].deliverable!;
      final secondResult = second.turns[1].deliverable!;

      expect(firstResult.displaySummary, contains(firstMarker));
      expect(firstResult.displaySummary, isNot(contains(secondMarker)));
      expect(secondResult.displaySummary, contains(secondMarker));
      expect(secondResult.displaySummary, isNot(contains(firstMarker)));
      expect(firstResult.evidenceFingerprint, isNotEmpty);
      expect(secondResult.evidenceFingerprint, isNotEmpty);
      expect(firstResult.evidenceFingerprint,
          isNot(secondResult.evidenceFingerprint));
      expect(secondResult.displaySummary, isNot(contains('QODER_TEST_MODE')));
    });
  });

  group('P06 - task detail responsiveness', () {
    testWidgets('tabs respond during streaming, settled and status changes',
        (tester) async {
      await pumpApp(tester);
      const marker = 'P26-P06-D1-AUTO';
      const followUpMarker = 'P26-P06-D2-AUTO';
      final taskId = await startTask(
        'slow-stream',
        marker,
        durationSeconds: 15,
      );
      await waitForTaskStatus(tester, state, taskId, TaskStatus.running);

      await tester.tap(find.text('P26-P06-D1-AUTO'));
      await tester.pump();
      expect(find.text('动态'), findsOneWidget);

      await runTabRounds(tester); // streaming
      await waitForDeliverable(tester, state, taskId, marker);
      await runTabRounds(tester); // settled / deliverable visible

      await state.sendFollowUp(
        currentTask(state, taskId),
        testPrompt('slow-stream', followUpMarker, durationSeconds: 15),
      );
      await waitForTask(
        tester,
        state,
        taskId,
        description: 'P06 follow-up status transition',
        predicate: (task) =>
            task.turns.length == 2 && task.status == TaskStatus.running,
      );
      await runTabRounds(tester); // running status transition

      await tester.pageBack();
      await tester.pump();
      expect(find.text('P26-P06-D1-AUTO'), findsWidgets);
      expect(currentTask(state, taskId).status, isNot(TaskStatus.failed));
    });
  });
}

Future<void> configureTestHost(ArminAppState state) async {
  final seeded =
      state.hosts.where((host) => host.id == _seedHostId).firstOrNull;
  if (seeded == null) {
    throw TestFailure('Missing seeded host $_seedHostId. Run seed-config.sh.');
  }
  if (seeded.password.isEmpty) {
    throw TestFailure('Missing SSH password for $_seedHostId.');
  }
  await state.saveHost(
    seeded.copyWith(
      agentCommand: _testAgentCommand,
      projectPath: _testProjectPath,
    ),
  );
  if (!state.projectPaths.any((path) => path.path == _testProjectPath)) {
    await state.saveProjectPath(testProject());
  }
}

HostConfig testHost(ArminAppState state) {
  return state.hosts.firstWhere((host) => host.id == _seedHostId);
}

ProjectPathConfig testProject() {
  final now = DateTime.now().toUtc();
  return ProjectPathConfig(
    id: 'project-gate-test',
    name: 'gate-test',
    path: _testProjectPath,
    createdAt: now,
    updatedAt: now,
  );
}

String testPrompt(String mode, String marker, {int durationSeconds = 10}) {
  return 'QODER_TEST_MODE=$mode QODER_TEST_MARKER=$marker '
      'QODER_TEST_DURATION=$durationSeconds';
}

TaskSession buildTask({
  required String taskId,
  required HostConfig host,
  required String prompt,
  required AgentApprovalMode approvalMode,
  required DateTime now,
}) {
  final marker =
      RegExp(r'QODER_TEST_MARKER=([^\s]+)').firstMatch(prompt)!.group(1)!;
  return TaskSession(
    id: taskId,
    host: host,
    title: marker,
    status: TaskStatus.running,
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: marker,
    userText: prompt,
    context: '',
    constraints: const {},
    finalPrompt: prompt,
    secretRecords: const [],
    rawLog: '',
    approvalMode: approvalMode,
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
        payloadJson: '{"source":"gate_test"}',
        now: now,
      ),
      MetricEvent.create(
        taskId: taskId,
        eventType: 'task_started',
        payloadJson: '{"agent_command":"${host.agentCommand}"}',
        now: now,
      ),
    ],
  );
}

AgentExecutionRequest executionRequest(
  TaskSession task,
  AgentApprovalMode approvalMode,
) {
  return AgentExecutionRequest(
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
    approvalConfig: AgentApprovalConfig(
      agentType: AgentTypeDetection.detect(task.host.agentCommand),
      mode: approvalMode,
    ),
  );
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
  TaskStatus status,
) {
  return waitForTask(
    tester,
    state,
    taskId,
    description: '$taskId status ${status.name}',
    predicate: (task) => task.status == status,
  );
}

Future<TaskSession> waitForDeliverable(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
  String marker,
) {
  return waitForTask(
    tester,
    state,
    taskId,
    description: '$taskId deliverable $marker',
    timeout: const Duration(seconds: 30),
    predicate: (task) =>
        task.status == TaskStatus.turnIdle && deliverableContains(task, marker),
  );
}

bool deliverableContains(TaskSession task, String marker) {
  final deliverable = task.turns.lastOrNull?.deliverable;
  return deliverable != null &&
      deliverable.displaySummary.contains(marker) &&
      deliverable.evidenceFingerprint.isNotEmpty;
}

TaskSession currentTask(ArminAppState state, String taskId) {
  return state.tasks.firstWhere((task) => task.id == taskId);
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

Future<String> remoteOutput(ArminAppState state, TaskSession task) {
  return state.agentSessionService.captureLog(controlRequest(state, task));
}

Future<RemoteTaskProbe> waitForRemoteMarker(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
  String marker,
) async {
  RemoteTaskProbe? probe;
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final task = currentTask(state, taskId);
    probe = await probeTask(state, task);
    if (probe.sessionExists && probe.snapshot.contains(marker)) return probe;
    await tester.pump(_pollInterval);
  }
  throw TestFailure('Timed out waiting for remote marker $marker.');
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

Future<void> runTabRounds(WidgetTester tester) async {
  for (var round = 0; round < 5; round++) {
    await expectResponsiveTab(tester, '产出', '结果 / 产出');
    await expectResponsiveTab(tester, '高级', '高级控制');
    await expectResponsiveTab(tester, '动态', '任务输出历史');
  }
}

Future<void> expectResponsiveTab(
  WidgetTester tester,
  String tabLabel,
  String expectedText,
) async {
  final stopwatch = Stopwatch()..start();
  await tester.tap(find.text(tabLabel));
  await tester.pump();
  expect(find.text(expectedText), findsWidgets);
  stopwatch.stop();
  expect(
    stopwatch.elapsed,
    lessThan(const Duration(seconds: 1)),
    reason: '$tabLabel did not respond within one second',
  );
}

// ── Silent voice service (no-op) for non-B07 gate tests ────────────

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => '';

  @override
  Future<void> speakSummary(String summary) async {}

  @override
  Future<void> pauseSpeaking() async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}
