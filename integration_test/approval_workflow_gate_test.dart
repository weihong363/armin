import 'dart:convert';

import 'package:armin/app.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/runtime/models/approval_state.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Approval workflow runtime gate on emulator-5554.
///
/// This suite uses the production SSH/tmux/Runtime/SQLite path with the
/// deterministic qodercli-test approval mode. It validates durable approval
/// facts and recovery without depending on real qodercli wording.
///
/// 前提条件：
///   1. seed-config.sh 已配置 host（含 SSH 密码）
///   2. qodercli-test 在宿主机 [_testAgentCommand] 路径可用
///   3. [_testProjectPath] 在宿主机存在

const _seedHostId = 'host-local-mac';
const _testProjectPath =
    '/Users/ironion/workspace/armin-test/countdown_widgets';
const _testAgentCommand =
    '/Users/ironion/workspace/armin/scripts/qodercli-test';
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
    await configureTestHost(state);
  }

  Future<void> restartAppState(WidgetTester tester) async {
    await state.drainForTest();
    state.dispose();
    state = ArminAppState.run(voiceService: const _SilentVoiceService());
    await tester.pumpWidget(ArminApp(state: state));
    await waitUntil(
      tester,
      description: 'ArminAppState ready after restart',
      predicate: () => state.ready,
    );
    await configureTestHost(state);
  }

  Future<String> startTask(
    String mode,
    String marker, {
    AgentApprovalMode approvalMode = AgentApprovalMode.safe,
  }) async {
    final host = testHost(state);
    final now = DateTime.now();
    final taskId = 'approval-${now.microsecondsSinceEpoch}';
    final prompt = testPrompt(mode, marker);
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
    state.startTaskExecution(task, executionRequest(task, approvalMode));
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

  group('approval request facts', () {
    testWidgets('enters needApproval and records requested fact',
        (tester) async {
      await pumpApp(tester);
      const marker = 'APPROVAL-GATE-REQUEST';
      final taskId = await startTask('approval', marker);

      final pending = await waitForTask(
        tester,
        state,
        taskId,
        description: 'approval request pending',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );

      expect(state.taskStatus(pending), TaskStatus.needApproval);
      final wf = state.workState(taskId);
      expect(wf?.approval, isNotNull);
      expect(wf!.approval!.question, isNotEmpty);

      final approvalEvents = _approvalFacts(pending);
      expect(approvalEvents, isNotEmpty,
          reason: 'Expected at least one loop_approval_event');
      expect(
        approvalEvents.any((e) => e.kind == LoopApprovalEventKind.requested),
        isTrue,
        reason: 'Expected loop_approval_event with kind=requested',
      );
    });
  });

  group('approval resolution facts', () {
    testWidgets('approve records approved fact and task converges',
        (tester) async {
      await pumpApp(tester);
      const marker = 'APPROVAL-GATE-APPROVE';
      final taskId = await startTask('approval', marker);

      final pending = await waitForTask(
        tester,
        state,
        taskId,
        description: 'approve gate pending approval',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );

      await state.resolveApproval(pending, approved: true);
      await waitForRemoteMarker(tester, state, taskId, marker);

      // 状态收敛
      await waitUntil(
        tester,
        description: 'approval resolved',
        predicate: () =>
            state.runtimeDiagnostics(taskId)?.approvalState ==
            ApprovalState.resolved,
      );

      final after = currentTask(state, taskId);
      expect(state.taskStatus(after), isNot(TaskStatus.needApproval));

      final approvalEvents = _approvalFacts(after);
      expect(
        approvalEvents.any((e) => e.kind == LoopApprovalEventKind.approved),
        isTrue,
        reason: 'Expected loop_approval_event with kind=approved',
      );
      final requestedIds = approvalEvents
          .where((e) => e.kind == LoopApprovalEventKind.requested)
          .map((e) => e.approvalId)
          .toSet();
      final approvedIds = approvalEvents
          .where((e) => e.kind == LoopApprovalEventKind.approved)
          .map((e) => e.approvalId)
          .toSet();
      expect(
        approvedIds.intersection(requestedIds),
        isNotEmpty,
        reason: 'Approved event should share approvalId with a requested event',
      );
    });

    testWidgets('reject records rejected fact', (tester) async {
      await pumpApp(tester);
      const marker = 'APPROVAL-GATE-REJECT';
      final taskId = await startTask('approval', marker);

      await waitForTask(
        tester,
        state,
        taskId,
        description: 'reject gate pending approval',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );

      final pending = currentTask(state, taskId);
      await state.resolveApproval(pending, approved: false);

      await tester.pump(const Duration(seconds: 3));
      final after = currentTask(state, taskId);

      final approvalEvents = _approvalFacts(after);
      expect(
        approvalEvents.any((e) => e.kind == LoopApprovalEventKind.rejected),
        isTrue,
        reason: 'Expected loop_approval_event with kind=rejected',
      );
    });
  });

  group('approval recovery', () {
    testWidgets('pending approval and requested fact survive AppState restart',
        (tester) async {
      await pumpApp(tester);
      const marker = 'APPROVAL-GATE-RECOVERY';
      final taskId = await startTask('approval', marker);

      final pending = await waitForTask(
        tester,
        state,
        taskId,
        description: 'recovery gate pending approval',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );

      final beforeFacts = _approvalFacts(pending);
      final beforeRequestedCount = beforeFacts
          .where((e) => e.kind == LoopApprovalEventKind.requested)
          .length;
      expect(beforeRequestedCount, greaterThan(0));

      await restartAppState(tester);

      final restored = currentTask(state, taskId);
      expect(state.taskStatus(restored), TaskStatus.needApproval);
      expect(state.workState(taskId)?.approval?.state, ApprovalState.pending);

      final restoredFacts = _approvalFacts(restored);
      final restoredRequestedCount = restoredFacts
          .where((e) => e.kind == LoopApprovalEventKind.requested)
          .length;
      expect(restoredRequestedCount, beforeRequestedCount,
          reason: 'AppState restart should not duplicate requested facts.');

      await state.resolveApproval(restored, approved: true);
      await waitForRemoteMarker(tester, state, taskId, marker);
      await waitUntil(
        tester,
        description: 'recovered approval resolved',
        predicate: () =>
            state.runtimeDiagnostics(taskId)?.approvalState ==
            ApprovalState.resolved,
      );
      final afterApprove = currentTask(state, taskId);
      final afterFacts = _approvalFacts(afterApprove);
      expect(
        afterFacts.any((e) => e.kind == LoopApprovalEventKind.approved),
        isTrue,
        reason: 'Approved fact should be recorded',
      );
      final afterRequestedCount = afterFacts
          .where((e) => e.kind == LoopApprovalEventKind.requested)
          .length;
      expect(afterRequestedCount, beforeRequestedCount,
          reason: 'requested event count should not change after approve');
    });
  });

  group('multi-turn approval isolation', () {
    testWidgets('two turns each own their approval facts', (tester) async {
      await pumpApp(tester);
      const firstMarker = 'APPROVAL-GATE-T1';
      const secondMarker = 'APPROVAL-GATE-T2';
      final taskId = await startTask('approval', firstMarker);

      final pending1 = await waitForTask(
        tester,
        state,
        taskId,
        description: 'turn 1 pending approval',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );
      await state.resolveApproval(pending1, approved: true);
      await waitForRemoteMarker(tester, state, taskId, firstMarker);
      await waitUntil(
        tester,
        description: 'turn 1 approval resolved',
        predicate: () =>
            state.runtimeDiagnostics(taskId)?.approvalState ==
            ApprovalState.resolved,
      );

      final afterT1 = currentTask(state, taskId);
      await state.sendFollowUp(afterT1, testPrompt('approval', secondMarker));
      final pending2 = await waitForTask(
        tester,
        state,
        taskId,
        description: 'turn 2 pending approval',
        timeout: const Duration(seconds: 60),
        predicate: (task) =>
            task.turns.length == 2 &&
            state.taskStatus(task) == TaskStatus.needApproval &&
            state.workState(taskId)?.approval?.state == ApprovalState.pending,
      );
      await state.resolveApproval(pending2, approved: true);
      await waitForRemoteMarker(tester, state, taskId, secondMarker);

      final finalTask = currentTask(state, taskId);
      final allFacts = _approvalFacts(finalTask);

      final t1Facts = allFacts.where((e) => e.turnIndex == 1).toList();
      final t2Facts = allFacts.where((e) => e.turnIndex == 2).toList();

      expect(t1Facts, isNotEmpty, reason: 'Turn 1 should have approval facts');
      expect(t2Facts, isNotEmpty, reason: 'Turn 2 should have approval facts');

      final t1TurnIds = t1Facts.map((e) => e.turnId).toSet();
      final t2TurnIds = t2Facts.map((e) => e.turnId).toSet();
      expect(
        t1TurnIds.intersection(t2TurnIds),
        isEmpty,
        reason: 'Turn 1 and Turn 2 approval facts must have different turnIds',
      );

      expect(
        t1Facts.any((e) => e.kind == LoopApprovalEventKind.requested),
        isTrue,
      );
      expect(
        t1Facts.any((e) => e.kind == LoopApprovalEventKind.approved),
        isTrue,
      );
      expect(
        t2Facts.any((e) => e.kind == LoopApprovalEventKind.requested),
        isTrue,
      );
      expect(
        t2Facts.any((e) => e.kind == LoopApprovalEventKind.approved),
        isTrue,
      );
    });
  });
}

// ── Helpers ────────────────────────────────────────────────────────

List<LoopApprovalEvent> _approvalFacts(TaskSession task) {
  return task.metricEvents
      .where((e) => e.eventType == LoopApprovalEvent.metricEventType)
      .map((e) {
        try {
          return LoopApprovalEvent.fromJson(
            (jsonDecode(e.payloadJson) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          return null;
        }
      })
      .whereType<LoopApprovalEvent>()
      .toList();
}

Future<void> configureTestHost(ArminAppState state) async {
  final seeded =
      state.hosts.where((host) => host.id == _seedHostId).firstOrNull;
  final password = seeded?.password ?? _testSshPassword;
  if (password.isEmpty) {
    throw TestFailure(
      'Missing SSH password for $_seedHostId. Run seed-config.sh or pass '
      '--dart-define=ARMINTEST_SSH_PASSWORD.',
    );
  }
  final host = seeded ?? testSeedHost();
  final needsUpdate = seeded == null ||
      seeded.agentCommand != _testAgentCommand ||
      seeded.password != password ||
      seeded.projectPath != _testProjectPath;
  if (needsUpdate) {
    await state.saveHost(
      host.copyWith(
        agentCommand: _testAgentCommand,
        password: password,
        projectPath: _testProjectPath,
      ),
    );
  }
  if (!state.projectPaths.any((path) => path.path == _testProjectPath)) {
    await state.saveProjectPath(testProject());
  }
}

HostConfig testHost(ArminAppState state) {
  return state.hosts.firstWhere((host) => host.id == _seedHostId);
}

HostConfig testSeedHost() {
  final now = DateTime.now().toUtc();
  return HostConfig(
    id: _seedHostId,
    name: 'Local Mac',
    host: '192.168.1.10',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: _testProjectPath,
    tmuxSessionName: 'armin-codex',
    agentCommand: _testAgentCommand,
    createdAt: now,
    updatedAt: now,
    isDefault: true,
    tmuxCommand: '/opt/homebrew/bin/tmux',
    pathPrepend: '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global/bin:'
        '\$HOME/.npm-packages/bin:\$HOME/.local/bin',
    shellWrapper: ShellWrapper.zshLogin,
    machineType: HostMachineType.macAppleSilicon,
  );
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

String testPrompt(String mode, String marker) {
  return 'QODER_TEST_MODE=$mode QODER_TEST_MARKER=$marker '
      'QODER_TEST_DURATION=10';
}

TaskSession buildTask({
  required String taskId,
  required HostConfig host,
  required String prompt,
  required AgentApprovalMode approvalMode,
  required DateTime now,
}) {
  return TaskSession(
    id: taskId,
    host: host,
    title: 'Approval workflow gate task',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Approval workflow gate task',
    userText: prompt,
    context: '',
    constraints: const {},
    finalPrompt: prompt,
    secretRecords: const [],
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
        payloadJson: '{"source":"approval_workflow_gate"}',
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

Future<RemoteTaskProbe> waitForRemoteMarker(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
  String marker, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final task = currentTask(state, taskId);
    final probe = await probeTask(state, task);
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

// ── Silent voice service ──────────────────────────────────────────

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
