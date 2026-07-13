import 'dart:async';

import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/ai/services/slm_client.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_recurrence.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/screens/task_draft_screen.dart';
import 'package:armin/features/tasks/services/loop_evaluation_assistant.dart';
import 'package:armin/features/tasks/services/system_calendar_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('real agent draft screen hides mock scenario selector',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    expect(find.text('Mock 执行结果'), findsNothing);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('execution mode offers balanced and aggressive scenarios only',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    final state = await _pumpScreen(tester, store: store, agent: agent);

    await tester.scrollUntilVisible(
      find.text('平衡'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('安全'), findsNothing);
    expect(find.text('平衡'), findsOneWidget);
    expect(find.text('激进'), findsOneWidget);
    expect(
      find.text('适合短期任务或需要人工把关的工作；允许修改，但关键操作会暂停并请求确认。'),
      findsOneWidget,
    );

    await tester.tap(find.text('激进'));
    await tester.pumpAndSettle();
    expect(
      find.text('适合目标明确的长期任务；允许自主修改、处理审批并连续推进，通常无需人工守候。'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('send requires SSH password before creating task',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: '')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('请先在主机连接中填写 SSH 密码。'), findsOneWidget);
  });

  testWidgets('send requires project path before creating task',
      (tester) async {
    final store = _TaskStore(
      hosts: [_host(password: 'secret-password')],
      projectPaths: const [],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest, isNull);
    expect(store.savedTasks, isEmpty);
    expect(find.text('请先配置并选择项目目录。'), findsOneWidget);
  });

  testWidgets('send passes SSH password to agent request', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.password, 'secret-password');
    expect(agent.lastRequest?.projectPath, '/tmp/armin-task');
    expect(agent.lastRequest?.privateKeyPem, isNull);
    expect(store.savedTasks.last.host.projectPath, '/tmp/armin-task');
  });

  testWidgets('send uses selected host on first task execution',
      (tester) async {
    final store = _TaskStore(
      hosts: [
        _host(password: 'first-password'),
        _host(
          id: 'host-2',
          name: 'Qoder',
          host: '127.0.0.2',
          password: 'second-password',
          agentCommand: 'qodercli',
        ),
      ],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.tap(find.byKey(const ValueKey('host-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行主机'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Qoder ·').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.hostId, 'host-2');
    expect(agent.lastRequest?.host, '127.0.0.2');
    expect(agent.lastRequest?.password, 'second-password');
    expect(agent.lastRequest?.agentCommand, 'qodercli');
    expect(store.savedTasks.last.host.id, 'host-2');
  });

  testWidgets('historical rerun restores prior host and project path',
      (tester) async {
    final store = _TaskStore(
      hosts: [
        _host(password: 'default-password'),
        _host(
          id: 'host-2',
          name: 'Qoder',
          host: '127.0.0.2',
          password: 'history-password',
          agentCommand: 'qodercli',
        ),
      ],
      projectPaths: [
        _projectPath(),
        _projectPath(id: 'project-2', name: 'Momo', path: '~workspace/momo'),
      ],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(
      tester,
      store: store,
      agent: agent,
      screen: const TaskDraftScreen(
        initialTaskText: '继续历史任务',
        initialTaskTitle: '历史任务标题',
        selectedHostId: 'host-2',
        initialProjectPath: '~workspace/momo',
      ),
    );

    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.hostId, 'host-2');
    expect(agent.lastRequest?.agentCommand, 'qodercli');
    expect(agent.lastRequest?.projectPath, '~/workspace/momo');
    expect(store.savedTasks.last.title, '历史任务标题');
  });

  testWidgets('send stores custom task title', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.enterText(
      find.byKey(const ValueKey('task-title-field')),
      '自定义任务名',
    );
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(store.savedTasks.last.title, '自定义任务名');
  });

  testWidgets('empty task title falls back to generated title', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.enterText(find.byKey(const ValueKey('task-title-field')), '');
    await tester.pump();
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(store.savedTasks.last.title, '执行真实任务');
  });

  testWidgets('task title follows description until manually edited',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);
    final titleField = find.byKey(const ValueKey('task-title-field'));

    await tester.enterText(find.byType(TextField).first, '第一版任务描述');
    await tester.pump();
    expect(_textFieldController(tester, titleField).text, '第一版任务描述');

    await tester.enterText(titleField, '手动任务名');
    await tester.enterText(find.byType(TextField).first, '第二版任务描述');
    await tester.pump();

    expect(_textFieldController(tester, titleField).text, '手动任务名');
  });

  testWidgets('send creates first native output turn', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '输出 hello');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(store.savedTasks.first.turns, hasLength(1));
    expect(store.savedTasks.first.turns.single.turnIndex, 1);
    expect(store.savedTasks.first.turns.single.userInput, '输出 hello');
  });

  testWidgets('scheduled recurring task is persisted without starting an agent',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService();
    final calendar = _CaptureCalendarService();
    final state = await _pumpScreen(
      tester,
      store: store,
      agent: agent,
      screen: TaskDraftScreen(calendarService: calendar),
    );

    await tester.enterText(find.byType(TextField).first, '每天检查项目状态');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('schedule-mode-selector')),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('计划执行'));
    await tester.pumpAndSettle();
    expect(find.text('开始时间'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-date-wheel')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-hour-wheel')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-minute-wheel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-picker-confirm')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('schedule-time-picker')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('schedule-time-picker')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('schedule-recurrence-selector')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('schedule-recurrence-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('schedule-add-to-calendar')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('schedule-add-to-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建计划'));
    await tester.pumpAndSettle();

    final task = store.savedTasks.single;
    expect(agent.lastRequest, isNull);
    expect(task.startedAt, isNull);
    expect(task.scheduledFor, isNotNull);
    expect(task.recurrence, TaskRecurrence.daily);
    expect(task.turns, isEmpty);
    expect(state.taskStatus(task), TaskStatus.pending);
    expect(calendar.permissionRequested, isTrue);
    expect(task.calendarSyncEnabled, isTrue);
    state.dispose();
  });

  testWidgets('AGENTS.md discovery failure does not block sending',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(
      discoveryError: StateError('discovery failed'),
    );
    await _pumpScreen(tester, store: store, agent: agent);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('AGENTS.md 检测失败'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastDiscoveryRequest?.projectPath, '/tmp/armin-task');
    expect(agent.lastRequest, isNotNull);
  });

  testWidgets('AGENTS.md discovery shows detected message', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(
      discoveryResult: const AgentInstructionDiscoveryResult(
        paths: ['./AGENTS.md'],
      ),
    );
    await _pumpScreen(tester, store: store, agent: agent);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('检测到 AGENTS.md'),
      findsOneWidget,
    );
  });

  testWidgets('send normalizes home based project path', (tester) async {
    final store = _TaskStore(
      hosts: [_host(password: 'secret-password')],
      projectPaths: [_projectPath(path: '~workspace/momo')],
    );
    final agent = _CaptureAgentSessionService();
    await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(agent.lastRequest?.projectPath, '~/workspace/momo');
    expect(store.savedTasks.last.host.projectPath, '~/workspace/momo');
  });

  testWidgets('project selector fits narrow screens without overflow',
      (tester) async {
    final store = _TaskStore(
      hosts: [_host(password: 'secret-password')],
      projectPaths: [
        _projectPath(
          name: 'momo',
          path: '~/workspace/momo-with-a-very-long-project-directory-name',
        ),
      ],
    );
    final agent = _CaptureAgentSessionService();

    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(360, 640));

    await _pumpScreen(tester, store: store, agent: agent);

    expect(tester.takeException(), isNull);
  });

  testWidgets('send opens task detail before agent finishes', (tester) async {
    final waitBeforeResult = Completer<void>();
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(
      waitBeforeResult: waitBeforeResult,
    );
    final state = await _pumpScreen(
      tester,
      store: store,
      agent: agent,
      screen: const TaskDraftScreen(
        loopEvaluationAssistant: LoopEvaluationAssistant(
          client: _UnavailableSlmClient(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(find.text('任务详情'), findsOneWidget);
    expect(agent.lastRequest, isNotNull);
    expect(state.taskStatus(store.savedTasks.last), TaskStatus.running);
    expect(agent.lastRequest!.tmuxSessionName, startsWith('armin-'));
    expect(agent.lastRequest!.tmuxSessionName.length, lessThanOrEqualTo(14));
    expect(store.savedTasks.last.host.tmuxSessionName,
        agent.lastRequest!.tmuxSessionName);

    waitBeforeResult.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('SSH failure marks task failed', (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(error: StateError('ssh failed'));
    final state = await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, isNotEmpty);
    expect(state.taskStatus(store.savedTasks.last), TaskStatus.failed);
    expect(
      store.savedTasks.last.turns.lastOrNull?.status,
      NativeOutputTurnStatus.failed,
    );
  });

  testWidgets('done update without result marks task turn idle',
      (tester) async {
    final store = _TaskStore(hosts: [_host(password: 'secret-password')]);
    final agent = _CaptureAgentSessionService(doneWithoutResult: true);
    final state = await _pumpScreen(tester, store: store, agent: agent);

    await tester.enterText(find.byType(TextField).first, '执行真实任务');
    await tester.tap(find.text('发送任务'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, isNotEmpty);
    expect(state.taskStatus(store.savedTasks.last), TaskStatus.turnIdle);
    expect(store.savedTasks.last.completedAt, isNull);
  });
}

class _CaptureCalendarService implements SystemCalendarService {
  bool permissionRequested = false;

  @override
  Future<SystemCalendarPermission> permissionStatus() async =>
      SystemCalendarPermission.granted;

  @override
  Future<SystemCalendarPermission> requestPermission() async {
    permissionRequested = true;
    return SystemCalendarPermission.granted;
  }

  @override
  Future<bool> upsertScheduledTask(TaskSession task) async => true;

  @override
  Future<void> removeScheduledTask(String taskId) async {}
}

Future<ArminAppState> _pumpScreen(
  WidgetTester tester, {
  required _TaskStore store,
  required _CaptureAgentSessionService agent,
  Widget screen = const TaskDraftScreen(),
}) async {
  final state = ArminAppState(
    store: store,
    agentSessionService: agent,
    voiceService: MockVoiceService(),
  );
  await state.load();
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pump();
  return state;
}

TextEditingController _textFieldController(WidgetTester tester, Finder finder) {
  final textField = tester.widget<TextField>(finder);
  final controller = textField.controller;
  if (controller == null) {
    throw StateError('Expected text field to have a controller.');
  }
  return controller;
}

HostConfig _host({
  String id = 'host-1',
  String name = 'Dev',
  String host = '127.0.0.1',
  required String password,
  String agentCommand = 'codex',
}) {
  final now = DateTime(2026, 5, 17);
  return HostConfig(
    id: id,
    name: name,
    host: host,
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: '',
    tmuxSessionName: 'armin-codex',
    agentCommand: agentCommand,
    createdAt: now,
    updatedAt: now,
    password: password,
  );
}

class _TaskStore extends TaskHistoryStore {
  _TaskStore({
    required List<HostConfig> hosts,
    List<ProjectPathConfig>? projectPaths,
  })  : _hosts = hosts,
        _projectPaths = projectPaths?.toList() ?? [_projectPath()];

  final List<HostConfig> _hosts;
  final List<ProjectPathConfig> _projectPaths;
  final List<TaskSession> savedTasks = [];

  @override
  Future<List<HostConfig>> loadHosts() async => List.unmodifiable(_hosts);

  @override
  Future<List<TaskSession>> loadTasks() async => List.unmodifiable(savedTasks);

  @override
  Future<void> saveHost(HostConfig host) async {
    final index = _hosts.indexWhere((item) => item.id == host.id);
    if (index >= 0) {
      _hosts[index] = host;
      return;
    }
    _hosts.add(host);
  }

  @override
  Future<void> deleteHost(String hostId) async {
    _hosts.removeWhere((item) => item.id == hostId);
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    final index = savedTasks.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      savedTasks[index] = task;
      return;
    }
    savedTasks.add(task);
  }

  @override
  Future<void> deleteTask(String taskId) async {
    savedTasks.removeWhere((task) => task.id == taskId);
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async {
    return List.unmodifiable(_projectPaths);
  }

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    final index = _projectPaths.indexWhere((item) => item.id == projectPath.id);
    if (index >= 0) {
      _projectPaths[index] = projectPath;
      return;
    }
    _projectPaths.add(projectPath);
  }

  @override
  Future<void> deleteProjectPath(String projectPathId) async {
    _projectPaths.removeWhere((item) => item.id == projectPathId);
  }
}

ProjectPathConfig _projectPath({
  String id = 'project-1',
  String name = 'Armin',
  String path = '/tmp/armin-task',
}) {
  final now = DateTime(2026, 5, 17);
  return ProjectPathConfig(
    id: id,
    name: name,
    path: path,
    createdAt: now,
    updatedAt: now,
    isDefault: true,
  );
}

class _CaptureAgentSessionService implements AgentSessionService {
  _CaptureAgentSessionService({
    this.error,
    this.doneWithoutResult = false,
    this.waitBeforeResult,
    this.discoveryResult = const AgentInstructionDiscoveryResult(paths: []),
    this.discoveryError,
  });

  final Object? error;
  final bool doneWithoutResult;
  final Completer<void>? waitBeforeResult;
  final AgentInstructionDiscoveryResult discoveryResult;
  final Object? discoveryError;
  AgentExecutionRequest? lastRequest;
  AgentInstructionDiscoveryRequest? lastDiscoveryRequest;

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'ok');
  }

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    lastDiscoveryRequest = request;
    if (discoveryError != null) {
      throw discoveryError!;
    }
    return discoveryResult;
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    lastRequest = request;
    if (error != null) {
      throw error!;
    }
    if (doneWithoutResult) {
      yield const AgentExecutionUpdate(
        rawOutput: 'SSH session ended without readable result.',
        done: true,
      );
      return;
    }
    if (waitBeforeResult != null) {
      await waitBeforeResult!.future;
    }
    yield const AgentExecutionUpdate(
      rawOutput: 'done',
      cleanedOutput: 'done',
      done: true,
    );
  }

  @override
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {}

  @override
  Future<void> pause(AgentControlRequest request) async {}

  @override
  Future<void> resume(AgentControlRequest request) async {}

  @override
  Future<void> interrupt(AgentControlRequest request) async {}

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}

  @override
  Future<void> cleanup(AgentControlRequest request) async {}

  @override
  Future<String> captureLog(AgentControlRequest request) async => '';
}

class _UnavailableSlmClient implements SlmClient {
  const _UnavailableSlmClient();

  @override
  Future<SlmCapability> capability({String? modelPath}) async {
    return const SlmCapability(
      available: false,
      message: 'Unavailable in this widget test.',
    );
  }

  @override
  Future<SlmGenerationResponse> generate(SlmGenerationRequest request) {
    throw UnsupportedError('Generation is not expected in this widget test.');
  }
}
