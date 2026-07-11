import 'dart:convert';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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

  setUp(() async {
    state = ArminAppState.run(voiceService: const _SilentVoiceService());
    await state.load();
    await _configureRealHost(state);
  });

  tearDown(() async {
    for (final taskId in taskIds.reversed) {
      final task = state.tasks.where((task) => task.id == taskId).firstOrNull;
      if (task == null) continue;
      try {
        await state.agentSessionService.cleanup(_controlRequest(state, task));
      } catch (_) {}
      final latest = state.tasks.where((task) => task.id == taskId).firstOrNull;
      if (latest != null && !_isTerminal(state.taskStatus(latest))) {
        await state.updateTaskStatus(latest, TaskStatus.stopped);
      }
    }
    taskIds.clear();
    await state.drainForTest();
    state.dispose();
  });

  testWidgets('real qodercli YOLO approves once and auto follow-ups',
      (tester) async {
    const firstMarker = 'ARMIN_YOLO_REAL_D1';
    final taskId = await _startTask(
      state,
      marker: firstMarker,
      prompt: '''
Create a temporary file named .armin_yolo_autopilot_tmp in the project root,
then delete it before the final answer. Do not commit anything.
Do not run tests in this first turn.
Final answer must include:
$firstMarker status=PASS temp_cleaned=true files_changed=0 next=WAIT
''',
    );
    taskIds.add(taskId);

    final running = await _waitForTask(
      tester,
      state,
      taskId,
      description: 'turn 1 running',
      timeout: const Duration(seconds: 30),
      predicate: (task) => state.taskStatus(task) == TaskStatus.running,
    );
    expect(running.host.tmuxSessionName, startsWith('armin-'));

    await _waitForAutoApproval(
      tester,
      state,
      taskId,
      timeout: const Duration(seconds: 90),
    );

    final first = await _waitForTurnDeliverable(
      tester,
      state,
      taskId,
      turnIndex: 0,
      timeout: const Duration(seconds: 240),
    );
    final firstTurn = first.turns[0];
    expect(firstTurn.deliverable?.displaySummary, isNotEmpty);
    final firstRemote = await state.agentSessionService.captureLog(
      _controlRequest(state, first),
    );
    expect(firstRemote, contains(firstMarker));

    final afterAuto = await _waitForTask(
      tester,
      state,
      taskId,
      description: 'autopilot follow-up turn',
      timeout: const Duration(seconds: 45),
      predicate: (task) =>
          task.turns.length >= 2 &&
          _loopAutoActions(task).any(
            (event) => event.state == LoopAutoActionState.sent,
          ),
    );
    expect(afterAuto.turns[1].userInput.trim(), isNotEmpty);
    expect(afterAuto.turns[1].userInput, contains('测试'));
    expect(afterAuto.turns[1].userInput, contains('未运行原因'));
    expect(afterAuto.turns[1].userInput,
        contains('ARMIN_AUTOPILOT_REQUEST_TEST_EVIDENCE_T2'));
    expect(afterAuto.host.tmuxSessionName, first.host.tmuxSessionName);

    final second = await _waitForTask(
      tester,
      state,
      taskId,
      description: 'autopilot follow-up settled',
      timeout: const Duration(seconds: 240),
      predicate: (task) =>
          task.turns.length >= 2 &&
          task.turns[1].deliverable != null &&
          state.taskStatus(task) != TaskStatus.running,
    );
    expect(second.turns[1].deliverable?.displaySummary,
        isNot(contains(firstMarker)));
    expect(second.turns[1].deliverable?.displaySummary, isNotEmpty);
    final secondRemote = await state.agentSessionService.captureLog(
      _controlRequest(state, second),
    );
    expect(secondRemote, contains('ARMIN_AUTOPILOT_REQUEST_TEST_EVIDENCE_T2'));

    final probe = await _probeTask(state, second);
    expect(probe.sessionExists, isTrue);
  });
}

Future<String> _startTask(
  ArminAppState state, {
  required String marker,
  required String prompt,
}) async {
  final host = _testHost(state);
  final now = DateTime.now();
  final taskId = 'yolo-${now.microsecondsSinceEpoch}';
  final taskHost = host.copyWith(
    projectPath: _testProjectPath,
    tmuxSessionName: 'armin-$taskId',
    agentCommand: _realAgentCommand,
  );
  final task = TaskSession(
    id: taskId,
    host: taskHost,
    title: 'Real qodercli YOLO autopilot $marker',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Real qodercli YOLO autopilot',
    userText: prompt,
    context: '',
    constraints: const {TaskConstraint.runTestsAfterChanges},
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
        payloadJson: '{"source":"real_qodercli_yolo_autopilot"}',
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
  return taskId;
}

Future<void> _waitForAutoApproval(
  WidgetTester tester,
  ArminAppState state,
  String taskId, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final task = state.tasks.where((task) => task.id == taskId).firstOrNull;
    if (task != null &&
        task.metricEvents
            .any((event) => event.eventType == 'approval_auto_approved')) {
      return;
    }
    await tester.pump(_pollInterval);
  }
  final task = state.tasks.where((task) => task.id == taskId).firstOrNull;
  final remote = task == null
      ? 'missing task'
      : await state.agentSessionService
          .captureLog(_controlRequest(state, task));
  throw TestFailure(
    'Timed out waiting for Armin auto approval. This usually means qodercli '
    'bypassed approval before Armin could observe it, or no terminal approval '
    'was triggered.\nremoteTail=${_tail(remote)}',
  );
}

Future<TaskSession> _waitForTurnDeliverable(
  WidgetTester tester,
  ArminAppState state,
  String taskId, {
  required int turnIndex,
  required Duration timeout,
}) async {
  TaskSession? latest;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    latest = state.tasks.where((task) => task.id == taskId).firstOrNull;
    final turn = latest?.turns.elementAtOrNull(turnIndex);
    if (turn?.deliverable != null) {
      return latest!;
    }
    await tester.pump(_pollInterval);
  }
  final task =
      latest ?? state.tasks.where((task) => task.id == taskId).firstOrNull;
  final remote = task == null
      ? 'missing task'
      : await state.agentSessionService
          .captureLog(_controlRequest(state, task));
  throw TestFailure(
    'Timed out waiting for turn ${turnIndex + 1} deliverable. '
    'remoteTail=${_tail(remote)}',
  );
}

Future<TaskSession> _waitForTask(
  WidgetTester tester,
  ArminAppState state,
  String taskId, {
  required String description,
  required bool Function(TaskSession task) predicate,
  Duration timeout = const Duration(seconds: 30),
}) async {
  TaskSession? match;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    match = state.tasks.where((task) => task.id == taskId).firstOrNull;
    if (match != null && predicate(match)) {
      return match;
    }
    await tester.pump(_pollInterval);
  }
  final task =
      match ?? state.tasks.where((task) => task.id == taskId).firstOrNull;
  final remote = task == null
      ? 'missing task'
      : await state.agentSessionService
          .captureLog(_controlRequest(state, task));
  final status = task == null ? 'missing' : state.taskStatus(task).name;
  final turns = task?.turns.length ?? 0;
  throw TestFailure(
    'Timed out waiting for $description. '
    'status=$status turns=$turns remoteTail=${_tail(remote)}',
  );
}

Future<void> _configureRealHost(ArminAppState state) async {
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

HostConfig _testHost(ArminAppState state) {
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
    id: 'project-real-qodercli-yolo',
    name: 'real-qodercli-yolo',
    path: _testProjectPath,
    createdAt: now,
    updatedAt: now,
  );
}

AgentControlRequest _controlRequest(ArminAppState state, TaskSession task) {
  final host = _testHost(state);
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

Future<RemoteTaskProbe> _probeTask(
  ArminAppState state,
  TaskSession task,
) {
  final service = state.agentSessionService;
  if (service is! RemoteTaskProbeService) {
    throw TestFailure('AgentSessionService does not support remote probes.');
  }
  return (service as RemoteTaskProbeService)
      .probeRemoteState(_controlRequest(state, task));
}

List<LoopAutoAction> _loopAutoActions(TaskSession task) {
  return task.metricEvents
      .where((event) => event.eventType == LoopAutoAction.metricEventType)
      .map((event) => LoopAutoAction.fromJson(
            jsonDecode(event.payloadJson) as Map<String, Object?>,
          ))
      .toList(growable: false);
}

String _tail(String value, {int limit = 1800}) {
  final trimmed = value.trim();
  if (trimmed.length <= limit) {
    return trimmed;
  }
  return trimmed.substring(trimmed.length - limit);
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
