import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/history/screens/task_detail_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
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

  testWidgets('voice follow-up sends recognized instruction', (tester) async {
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final agent = _CapturingAgent();
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: agent,
      voiceService: _RecognizingVoiceService('输出 hello world'),
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
  const _TaskStore(this.task);

  final TaskSession task;

  @override
  Future<List<HostConfig>> loadHosts() async => [task.host];

  @override
  Future<List<TaskSession>> loadTasks() async => [task];

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {}

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

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    lastFollowUp = request.instruction;
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
  Future<void> startListening({
    void Function(String partial)? onPartial,
  }) async {
    _latest = text;
    onPartial?.call(text);
  }

  @override
  Future<String> stopListening() async => _latest;
}
