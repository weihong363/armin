import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/screens/task_home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('home add context asks for a task before chat or voice',
      (tester) async {
    await _pumpHome(tester, voiceService: MockVoiceService());

    await tester.tap(find.byKey(const ValueKey('home-add-context-button')));
    await tester.pumpAndSettle();

    expect(find.text('Create a task before adding context.'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-voice-panel')), findsNothing);
  });

  testWidgets('connection paused task is not stuck in needs attention',
      (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(),
      initialTasks: [
        _task(
          'task-1',
          'Lost remote session',
          status: TaskStatus.runtimeLost,
        ),
      ],
    );

    expect(find.text('No task needs you right now.'), findsOneWidget);
    expect(find.text('Connection paused'), findsOneWidget);
    expect(find.text('Recently Completed'), findsOneWidget);
  });

  testWidgets('home add context binds automatically when one task is active',
      (tester) async {
    final state = await _pumpHome(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复首页登录失败'),
      initialTasks: [_task('task-1', 'Payment refactor')],
    );

    await tester.tap(find.byKey(const ValueKey('home-add-context-button')));
    await tester.pumpAndSettle();

    expect(find.text('Add context to this task'), findsOneWidget);
    expect(
      find.text('This context will be added to: Payment refactor'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Keep changes minimal.');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    final updatedTask = state.tasks.firstWhere((task) => task.id == 'task-1');
    expect(updatedTask.turns.last.userInput, 'Keep changes minimal.');
  });

  testWidgets(
      'home add context selects a target when multiple tasks are active',
      (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(),
      initialTasks: [
        _task('task-1', 'Payment refactor'),
        _task('task-2', 'Log analysis'),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('home-add-context-button')));
    await tester.pumpAndSettle();

    expect(find.text('Select Task'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Log analysis'));
    await tester.pumpAndSettle();

    expect(
      find.text('This context will be added to: Log analysis'),
      findsOneWidget,
    );
  });

  testWidgets('home add context supports hold to talk inside task context',
      (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复首页登录失败'),
      initialTasks: [_task('task-1', 'Payment refactor')],
    );

    await tester.tap(find.byKey(const ValueKey('home-add-context-button')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hold to Talk')),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('修复首页登录失败'), findsWidgets);
  });

  testWidgets('header settings button opens unified settings screen',
      (tester) async {
    await _pumpHome(tester, voiceService: MockVoiceService());

    await tester.tap(find.byKey(const ValueKey('home-settings-button')));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsWidgets);
    expect(find.text('执行环境'), findsOneWidget);
    expect(find.text('主机连接'), findsOneWidget);
    expect(find.text('项目目录'), findsOneWidget);
    expect(find.text('语音与播报'), findsWidgets);
  });

  testWidgets('bottom navigation opens history instead of duplicating settings',
      (tester) async {
    await _pumpHome(tester, voiceService: MockVoiceService());

    expect(find.text('主机'), findsNothing);
    expect(find.text('我'), findsNothing);
    expect(find.text('History'), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.text('历史任务'), findsOneWidget);
    expect(find.text('暂无历史任务'), findsOneWidget);
  });
}

Future<ArminAppState> _pumpHome(
  WidgetTester tester, {
  required MockVoiceService voiceService,
  List<TaskSession> initialTasks = const [],
}) async {
  final store = InMemoryTaskHistoryStore();
  for (final task in initialTasks) {
    await store.saveTask(task);
  }
  final state = ArminAppState(
    store: store,
    agentSessionService: const _NoDelayAgent(),
    voiceService: voiceService,
  );
  await state.load();
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: TaskHomeScreen()),
    ),
  );
  await tester.pump();
  return state;
}

class _NoDelayAgent implements AgentSessionService {
  const _NoDelayAgent();

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'OK');
  }

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    return const AgentInstructionDiscoveryResult(paths: []);
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    return const Stream<AgentExecutionUpdate>.empty();
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

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
  Future<void> stop(AgentControlRequest request) async {}

  @override
  Future<void> cleanup(AgentControlRequest request) async {}

  @override
  Future<String> captureLog(AgentControlRequest request) async => '';
}

TaskSession _task(
  String id,
  String title, {
  TaskStatus status = TaskStatus.turnIdle,
}) {
  final now = DateTime(2026, 6, 5, 10);
  return TaskSession(
    id: id,
    host: HostConfig(
      id: 'host-$id',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '',
      tmuxSessionName: 'armin-$id',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret',
    ),
    title: title,
    status: status,
    createdAt: now,
    updatedAt: now,
    rawSttText: '',
    cleanedDraft: title,
    userText: title,
    context: '',
    constraints: const {},
    finalPrompt: title,
    secretRecords: const [],
    rawLog: '',
  );
}
