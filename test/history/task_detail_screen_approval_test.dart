import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/terminal_prompt.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/history/screens/task_detail_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resolved approval hides decision buttons', (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.running,
      approvalRequests: const [
        ApprovalRequest(
          reason: 'Need approval',
          command: 'touch ok.txt',
          risk: 'low',
          status: 'approved',
        ),
      ],
    );
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Approval Requests'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('已允许'), findsOneWidget);
    expect(find.text('允许'), findsNothing);
    expect(find.text('拒绝'), findsNothing);
  });

  testWidgets('detached task shows relisten controls', (tester) async {
    final task = _task().copyWith(status: TaskStatus.observerDetached);
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();

    expect(find.text('重新监听'), findsOneWidget);
    expect(find.text('断开监听'), findsOneWidget);
    expect(find.text('断开连接'), findsNothing);
  });

  testWidgets('terminal prompt options can be selected from runtime controls',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.needAttention,
      terminalPrompt: const TerminalPrompt(
        question: 'Allow execution of [ls]? Redirection detected.',
        options: [
          TerminalPromptOption(key: '1', label: 'Allow once'),
          TerminalPromptOption(key: '4', label: 'No'),
        ],
      ),
    );
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );

    expect(find.textContaining('Allow execution of [ls]?'), findsOneWidget);
    await tester.tap(find.text('1. Allow once'));
    await tester.pumpAndSettle();

    expect(agent.selectedTerminalOption, '1');
    expect(state.tasks.single.status, TaskStatus.running);
    expect(find.text('1. Allow once'), findsNothing);
  });

  testWidgets('voice follow-up sends recognized instruction', (tester) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final agent = _CapturingAgent();
    final voice = _RecognizingVoiceService('输出 hello world');
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: voice,
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );
    await tester.tap(find.text('追加指令'));
    await tester.pumpAndSettle();

    final button = find.text('语音追加');
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.lastFollowUp, '输出 hello world');
    expect(voice.stopSpeakingCount, 1);
    expect(state.tasks.single.voiceInputs.single.rawSttText, '输出 hello world');
    await tester.drag(
      find.byType(ListView).first,
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    expect(find.text('语音追加'), findsOneWidget);
    expect(find.text('输出 hello world'), findsWidgets);

    await tester.tap(find.text('指标'));
    await tester.pumpAndSettle();
    expect(find.text('语音追加'), findsOneWidget);
  });

  testWidgets('manual follow-up releases detail tree without inherited errors',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('追加指令'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续检查输出');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.lastFollowUp, '继续检查输出');
    expect(state.tasks.single.status, TaskStatus.running);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice stop command executes local stop instead of follow-up',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: _RecognizingVoiceService('停一下'),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('追加指令'));
    await tester.pumpAndSettle();

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('语音追加')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('已识别：停止当前任务'), findsOneWidget);
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.stopped, isTrue);
    expect(agent.lastFollowUp, isNull);
    expect(state.tasks.single.voiceInputs.single.rawSttText, '停一下');
  });

  testWidgets('voice constraint follow-up persists detected constraints',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: _RecognizingVoiceService('先别大改，不要提交 Git'),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('追加指令'));
    await tester.pumpAndSettle();

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('语音追加')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('追加约束'), findsOneWidget);

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.lastFollowUp, '先别大改，不要提交 Git');
    expect(store.task.constraints, contains(TaskConstraint.minimalChange));
    expect(store.task.constraints, contains(TaskConstraint.noGitCommit));
  });

  testWidgets('voice resume command resumes a paused task', (tester) async {
    final task = _task().copyWith(status: TaskStatus.paused);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: _RecognizingVoiceService('恢复任务'),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('追加指令'));
    await tester.pumpAndSettle();

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('语音追加')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('已识别：恢复当前任务'), findsOneWidget);
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.resumed, isTrue);
    expect(agent.lastFollowUp, isNull);
  });

  testWidgets('manual read result speaks cleaned task summary', (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      summary: 'hello world',
    );
    final voice = _RecognizingVoiceService('');
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: voice,
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    final speakButton = find.byIcon(Icons.volume_up_outlined).last;
    await tester.ensureVisible(speakButton);
    await tester.pumpAndSettle();
    await tester.tap(speakButton);
    await tester.pumpAndSettle();

    expect(voice.spokenSummaries.single, contains('hello world'));
  });

  testWidgets('failed task header does not label the finish time completed',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.failed,
      completedAt: DateTime(2026, 5, 18, 11, 42),
      shortSummary: 'SSH 执行失败',
    );
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );

    expect(find.text('11:42 失败'), findsOneWidget);
    expect(find.text('11:42 完成'), findsNothing);
  });

  testWidgets('rerun is disabled while task is still interactive',
      (tester) async {
    final state = ArminAppState(
      store: _TaskStore(_task().copyWith(status: TaskStatus.turnIdle)),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新执行'));
    await tester.pumpAndSettle();

    expect(find.text('任务详情'), findsOneWidget);
    expect(find.text('新建任务'), findsNothing);
  });

  testWidgets('rerun is available after task is failed', (tester) async {
    final state = ArminAppState(
      store: _TaskStore(_task().copyWith(status: TaskStatus.failed)),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新执行'));
    await tester.pumpAndSettle();

    expect(find.text('新建任务'), findsOneWidget);
  });

  testWidgets('terminal task exposes remote session cleanup action',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.runtimeLost);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理远端会话'));
    await tester.pumpAndSettle();

    expect(agent.cleanedUp, isTrue);
    expect(find.text('已请求清理远端 tmux 会话。'), findsOneWidget);
  });
}

TaskSession _task() {
  final now = DateTime(2026, 5, 18);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret',
    ),
    title: 'Task',
    status: TaskStatus.running,
    createdAt: now,
    updatedAt: now,
    rawSttText: '',
    cleanedDraft: 'Task',
    userText: 'Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Task',
    secretRecords: const [],
    rawLog: '',
  );
}

class _TaskStore implements TaskHistoryStore {
  _TaskStore(this.task);

  TaskSession task;

  @override
  Future<List<HostConfig>> loadHosts() async => [task.host];

  @override
  Future<List<TaskSession>> loadTasks() async => [task];

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {
    this.task = task;
  }

  @override
  Future<void> deleteTask(String taskId) async {}

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {}

  @override
  Future<void> deleteProjectPath(String projectPathId) async {}
}

class _NoopAgent implements AgentSessionService {
  const _NoopAgent();

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
    return const AgentInstructionDiscoveryResult(paths: []);
  }
}

class _CapturingAgent extends _NoopAgent {
  String? lastFollowUp;
  String? selectedTerminalOption;
  bool stopped = false;
  bool resumed = false;
  bool cleanedUp = false;

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    lastFollowUp = request.instruction;
  }

  @override
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {
    selectedTerminalOption = optionKey;
  }

  @override
  Future<void> stop(AgentControlRequest request) async {
    stopped = true;
  }

  @override
  Future<void> resume(AgentControlRequest request) async {
    resumed = true;
  }

  @override
  Future<void> cleanup(AgentControlRequest request) async {
    cleanedUp = true;
  }
}

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => '';

  @override
  Future<void> speakSummary(String summary) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> startListening({
    void Function(String partial)? onPartial,
  }) async {}

  @override
  Future<String> stopListening() async => '';
}

class _RecognizingVoiceService implements VoiceService {
  _RecognizingVoiceService(this.text);

  final String text;
  final List<String> spokenSummaries = [];
  int stopSpeakingCount = 0;
  String _latest = '';

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => text;

  @override
  Future<void> speakSummary(String summary) async {
    spokenSummaries.add(summary);
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakingCount++;
  }

  @override
  Future<void> startListening({
    void Function(String partial)? onPartial,
  }) async {
    _latest = text;
    onPartial?.call(text);
  }

  @override
  Future<String> stopListening() async => _latest;
}
