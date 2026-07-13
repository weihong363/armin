import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/history/screens/task_detail_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/loop_runtime_protocol.dart';
import 'package:armin/features/tasks/services/prompt_template_builder.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _seedHostId = 'host-local-mac';
const _testProjectPath =
    '/Users/ironion/workspace/armin-test/countdown_widgets';
const _realAgentCommand = r'$HOME/.local/bin/qodercli';
const _pollInterval = Duration(milliseconds: 250);
const _testSshPassword = String.fromEnvironment('ARMINTEST_SSH_PASSWORD');
const _evidenceHoldSeconds =
    int.fromEnvironment('ARMINTEST_EVIDENCE_HOLD_SECONDS');
HostConfig? _configuredRealHost;

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

  testWidgets('real qodercli deliverable and follow-up regression',
      (tester) async {
    const firstMarker = 'ARMIN_REAL_QODER_REGRESSION_D1';
    const secondMarker = 'ARMIN_REAL_QODER_REGRESSION_D2';

    final taskId = await _startTask(
      state,
      marker: firstMarker,
      prompt: '''
Read pubspec.yaml. Do not modify files.
Output a concise Chinese project introduction, key widgets, test coverage, and acceptance conclusion.
Final answer must include:
$firstMarker status=PASS files_changed=0 next=WAIT
''',
    );
    taskIds.add(taskId);

    await _waitForTask(
      tester,
      state,
      taskId,
      description: 'turn 1 running',
      timeout: const Duration(seconds: 30),
      predicate: (task) => state.taskStatus(task) == TaskStatus.running,
    );

    final first = await _waitForDeliverable(
      tester,
      state,
      taskId,
      firstMarker,
      timeout: const Duration(seconds: 240),
    );
    final session = first.host.tmuxSessionName;
    debugPrint('ARMIN_EVIDENCE_SESSION case=DONE session=$session');
    expect(session, startsWith('armin-'));
    expect(
        state.taskStatus(first),
        isIn([
          TaskStatus.turnIdle,
          TaskStatus.needAttention,
        ]));
    expect(state.workState(taskId)?.phase, isNot(WorkPhase.working));
    _expectCleanDeliverable(first.turns.last.deliverable!.displaySummary);
    expect(
        first.turns.last.deliverable!.displaySummary, contains('status=PASS'));
    expect(first.turns.last.deliverable!.displaySummary,
        contains('files_changed=0'));
    expect(first.turns.last.deliverable!.loopState,
        LoopRuntimeOutcomeState.done.name);
    expect(first.turns.last.deliverable!.displaySummary,
        isNot(contains('ARMIN_LOOP_OUTCOME_BEGIN')));

    await tester.pump(const Duration(seconds: 8));
    final afterDone = state.tasks.firstWhere((task) => task.id == taskId);
    expect(afterDone.turns, hasLength(1));
    await _holdForExternalEvidence(tester);

    await _pumpDetailResult(tester, state, taskId);
    await _expandResultSummaries(tester);
    await _expectResultTextVisible(tester, firstMarker);
    expect(find.textContaining('最近进展'), findsNothing);
    expect(find.textContaining('Try /effort'), findsNothing);
    expect(find.textContaining('Type your message'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await _expectResultTextVisible(tester, firstMarker);
    expect(find.textContaining('最近进展'), findsNothing);

    await state.sendFollowUp(
      first,
      'Output only: $secondMarker status=PASS '
      'previous_case_repeated=false files_changed=0 next=COMPLETE',
    );

    await _waitForTask(
      tester,
      state,
      taskId,
      description: 'turn 2 created',
      timeout: const Duration(seconds: 20),
      predicate: (task) => task.turns.length == 2,
    );

    final second = await _waitForDeliverable(
      tester,
      state,
      taskId,
      secondMarker,
      timeout: const Duration(seconds: 240),
    );
    expect(second.host.tmuxSessionName, session);
    expect(second.turns, hasLength(2));
    expect(second.turns[1].deliverable?.displaySummary,
        allOf(contains(secondMarker), isNot(contains(firstMarker))));
    expect(second.turns[0].deliverable?.displaySummary,
        allOf(contains(firstMarker), isNot(contains(secondMarker))));
    _expectCleanDeliverable(second.turns[1].deliverable!.displaySummary);

    await _pumpDetailResult(tester, state, taskId);
    await _expandResultSummaries(tester);
    await _expectResultTextVisible(tester, secondMarker);
    expect(find.textContaining('最近进展'), findsNothing);
    expect(find.textContaining('Thinking'), findsNothing);
    expect(find.textContaining('Armin context governance'), findsNothing);

    final probe = await _probeTask(state, second);
    expect(probe.sessionExists, isTrue);
  });

  testWidgets('real qodercli blocked outcome does not auto follow-up',
      (tester) async {
    const marker = 'ARMIN_REAL_QODER_BLOCKED';
    final taskId = await _startTask(
      state,
      marker: marker,
      prompt: '''
Do not inspect or modify files. Completion requires the unavailable external
value ARMIN_UNKNOWN_TOKEN. Explain the blocker concisely and stop.
Final answer must include: $marker status=BLOCKED files_changed=0.
''',
    );
    taskIds.add(taskId);

    final blocked = await _waitForDeliverable(
      tester,
      state,
      taskId,
      marker,
      timeout: const Duration(seconds: 240),
    );
    final deliverable = blocked.turns.single.deliverable!;
    debugPrint(
      'ARMIN_EVIDENCE_SESSION case=BLOCKED '
      'session=${blocked.host.tmuxSessionName}',
    );
    expect(deliverable.loopState, LoopRuntimeOutcomeState.blocked.name);
    expect(deliverable.displaySummary,
        isNot(contains('ARMIN_LOOP_OUTCOME_BEGIN')));
    await tester.pump(const Duration(seconds: 8));
    expect(state.tasks.firstWhere((task) => task.id == taskId).turns,
        hasLength(1));
    await _holdForExternalEvidence(tester);
  });
}

Future<String> _startTask(
  ArminAppState state, {
  required String marker,
  required String prompt,
}) async {
  final host = _testHost(state);
  final now = DateTime.now();
  final taskId = 'rqd-${now.microsecondsSinceEpoch}';
  final taskHost = host.copyWith(
    projectPath: _testProjectPath,
    tmuxSessionName: 'armin-$taskId',
    agentCommand: _realAgentCommand,
  );
  final finalPrompt = PromptTemplateBuilder().build(
    taskDescription: prompt,
    context: '',
    constraints: const {},
    secrets: const [],
  );
  final task = TaskSession(
    id: taskId,
    host: taskHost,
    title: 'Real qodercli deliverable regression $marker',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Real qodercli deliverable regression',
    userText: prompt,
    context: '',
    constraints: const {},
    finalPrompt: finalPrompt,
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
        payloadJson: '{"source":"real_qodercli_deliverable_regression"}',
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
      prompt: task.finalPrompt,
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

Future<void> _holdForExternalEvidence(WidgetTester tester) async {
  if (_evidenceHoldSeconds <= 0) return;
  debugPrint('ARMIN_EVIDENCE_HOLD seconds=$_evidenceHoldSeconds');
  await tester.pump(const Duration(seconds: _evidenceHoldSeconds));
}

Future<void> _pumpDetailResult(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
) async {
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: MaterialApp(home: TaskDetailScreen(taskId: taskId)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('产出'));
  await tester.pumpAndSettle();
}

Future<void> _expandResultSummaries(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    final button = find.text('展开完整摘要');
    if (button.evaluate().isNotEmpty) {
      await tester.ensureVisible(button.first);
      await tester.pumpAndSettle();
      await tester.tap(button.first);
      await tester.pumpAndSettle();
      continue;
    }
    await _scrollResultPanel(tester);
  }
}

Future<void> _expectResultTextVisible(
  WidgetTester tester,
  String text,
) async {
  final finder = find.textContaining(text);
  for (var index = 0; index < 10; index++) {
    await _expandResultSummaries(tester);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await _scrollResultPanel(tester);
  }
  expect(finder, findsWidgets);
}

Future<void> _scrollResultPanel(WidgetTester tester) async {
  final scrollables = find.byType(Scrollable);
  if (scrollables.evaluate().isEmpty) {
    await tester.pump();
    return;
  }
  await tester.drag(scrollables.last, const Offset(0, -280));
  await tester.pumpAndSettle();
}

void _expectCleanDeliverable(String text) {
  expect(text, isNot(contains('最近进展')));
  expect(text, isNot(contains('Thinking')));
  expect(text, isNot(contains('Armin context governance')));
  expect(text, isNot(contains('Final answer must include')));
  expect(text, isNot(contains('Type your message')));
  expect(text, isNot(contains('Try /effort')));
  expect(text, isNot(contains('/context-window')));
  expect(text, isNot(contains('Model · ctx')));
  expect(text, isNot(contains('? for shortcuts')));
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
  _configuredRealHost = (seeded ?? _testSeedHost()).copyWith(
    agentCommand: _realAgentCommand,
    password: password,
    projectPath: _testProjectPath,
  );
}

HostConfig _testHost(ArminAppState state) {
  return _configuredRealHost ??
      state.hosts.firstWhere((host) => host.id == _seedHostId);
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

Future<TaskSession> _waitForDeliverable(
  WidgetTester tester,
  ArminAppState state,
  String taskId,
  String marker, {
  required Duration timeout,
}) async {
  TaskSession? latest;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    latest = state.tasks.where((task) => task.id == taskId).firstOrNull;
    final deliverable = latest?.turns.lastOrNull?.deliverable;
    if (deliverable != null && deliverable.displaySummary.contains(marker)) {
      return latest!;
    }
    await tester.pump(_pollInterval);
  }
  final task =
      latest ?? state.tasks.where((task) => task.id == taskId).firstOrNull;
  var remote = '';
  if (task != null) {
    try {
      remote = await state.agentSessionService.captureLog(
        _controlRequest(state, task),
      );
    } catch (error) {
      remote = 'capture failed: $error';
    }
  }
  final localStatus = task == null ? 'missing' : state.taskStatus(task).name;
  final turnStatus = task?.turns.lastOrNull?.status.name ?? 'missing';
  final rawLength = task?.turns.lastOrNull?.rawOutput.length ?? 0;
  final cleanLength = task?.turns.lastOrNull?.cleanedOutput.length ?? 0;
  final deliverable = task?.turns.lastOrNull?.deliverable?.displaySummary ?? '';
  throw TestFailure(
    'Timed out waiting for deliverable $marker.\n'
    'localStatus=$localStatus turnStatus=$turnStatus '
    'rawLength=$rawLength cleanLength=$cleanLength\n'
    'localDeliverable=${_tail(deliverable)}\n'
    'remoteTail=${_tail(remote)}',
  );
}

String _tail(String value, {int limit = 1800}) {
  final trimmed = value.trim();
  if (trimmed.length <= limit) {
    return trimmed;
  }
  return trimmed.substring(trimmed.length - limit);
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
  throw TestFailure('Timed out waiting for $description.');
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
