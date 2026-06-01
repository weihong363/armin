import 'dart:async';

import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/parsers/terminal_prompt.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/history/screens/task_detail_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:armin/features/tasks/widgets/task_card.dart';

void main() {
  testWidgets('resolved approval hides decision buttons', (tester) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets('running task shows comet loading badge on runtime control',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.running);
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

    expect(find.text('远端正在执行，结果会持续同步到这里'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        find.byKey(const Key('runtime-control-state-badge')), findsOneWidget);
  });

  testWidgets('terminal prompt options can be selected from runtime controls',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.needAttention,
      terminalPrompt: const TerminalPrompt(
        question: 'Allow execution of [ls]? Redirection detected.',
        command: 'ls',
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
    expect(find.text('ls'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(agent.selectedTerminalOption, '1');
    expect(state.tasks.single.status, TaskStatus.running);
    expect(find.text('Allow once'), findsNothing);
  });

  testWidgets('terminal prompt supports manual response options',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.needAttention,
      terminalPrompt: const TerminalPrompt(
        question: 'Allow this command to run? Redirection detected.',
        command: 'python -m pytest tests/test_hello_world.py',
        options: [
          TerminalPromptOption(key: '1', label: 'Allow once'),
          TerminalPromptOption(key: '3', label: 'Reject and type something'),
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

    expect(find.textContaining('python -m pytest'), findsOneWidget);
    await tester.tap(find.text('Reject and type something'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      '不要执行，先说明风险',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.selectedTerminalOption, '3');
    expect(agent.lastFollowUp, '不要执行，先说明风险');
    expect(state.tasks.single.terminalPrompt, isNull);
  });

  testWidgets(
      'approval requests surface manual and voice actions in runtime controls',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.needApproval,
      approval: const ApprovalRequest(
        reason: 'Need approval',
        command: 'rm -rf build',
        risk: 'medium',
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

    expect(find.text('任务确认'), findsOneWidget);
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('语音处理'), findsOneWidget);

    await tester.tap(find.text('语音处理'));
    await tester.pumpAndSettle();

    expect(find.text('审批处理'), findsOneWidget);
    expect(find.text('说“批准”或“拒绝”'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('允许'));
    await tester.pumpAndSettle();

    expect(agent.lastFollowUp, contains('APPROVAL_DECISION:'));
    expect(state.tasks.single.status, TaskStatus.running);
    expect(state.tasks.single.approvalRequests.single.status, 'approved');
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

    await tester.enterText(find.byType(TextField).last, '继续检查输出');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(agent.lastFollowUp, '继续检查输出');
    expect(state.tasks.single.status, TaskStatus.running);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual follow-up shows progress while instruction is sending',
      (tester) async {
    final task = _task().copyWith(status: TaskStatus.turnIdle);
    final agent = _DelayedFollowUpAgent();
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
    await tester.enterText(find.byType(TextField).last, '继续检查输出');
    await tester.tap(find.text('发送'));
    await tester.pump();

    expect(agent.lastFollowUp, '继续检查输出');
    expect(find.text('发送中...'), findsOneWidget);

    agent.completeFollowUp();
    await tester.pumpAndSettle();

    expect(state.tasks.single.status, TaskStatus.running);
    expect(find.text('发送中...'), findsNothing);
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

  testWidgets('manual read result speaks current turn card output',
      (tester) async {
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 Taro',
          rawOutput: '',
          cleanedOutput: '输出 Taro\nTaro 是一只小型宠物。',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '输出 Summer',
          rawOutput: '',
          cleanedOutput: '''
输出 Taro
Taro 是一只小型宠物。
输出 Summer
Summer 是一个海滩风格宠物。
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
      ],
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

    final speakButton = find.byTooltip('朗读这段输出').first;
    await tester.scrollUntilVisible(
      speakButton,
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(speakButton);
    await tester.pumpAndSettle();

    expect(voice.spokenSummaries.single, contains('Summer'));
    expect(voice.spokenSummaries.single, isNot(contains('Taro')));
  });

  testWidgets('manual read result uses displayed text as speech source',
      (tester) async {
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 hello world',
          rawOutput: 'hello world',
          cleanedOutput: 'hello world',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
      ],
    );
    final voice = _RecognizingVoiceService('');
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: voice,
      outputSummaryProvider: _CustomDisplaySummaryProvider(),
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

    final speakButton = find.byTooltip('朗读这段输出').first;
    await tester.scrollUntilVisible(
      speakButton,
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(speakButton);
    await tester.pumpAndSettle();

    expect(voice.spokenSummaries.single, contains('页面展示文本'));
    expect(voice.spokenSummaries.single, isNot(contains('旧语音文本')));
  });

  testWidgets('timeline filters terminal chrome from stored summary',
      (tester) async {
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      shortSummary: '''
████████████████████
Signed in Browser Login
Thinking...
Summer：一位迷人的美国沙滩女孩 Codex 宠物。
''',
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
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );

    expect(find.textContaining('Signed in Browser Login'), findsNothing);
    expect(find.textContaining('Thinking'), findsNothing);
    expect(find.textContaining('█'), findsNothing);
  });

  testWidgets('result prefers latest semantic turn over stale terminal result',
      (tester) async {
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.running,
      result: const TaskResult(
        status: 'turn_idle',
        summary: 'Signed in Browser Login',
        changedFiles: [],
        validation: [],
        risks: [],
        nextActions: [],
      ),
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '输出 Summer',
          rawOutput: '',
          cleanedOutput: 'Summer：一位迷人的美国沙滩女孩 Codex 宠物。',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.running,
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
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Summer：一位迷人的美国沙滩女孩'), findsOneWidget);
    expect(find.textContaining('Signed in Browser Login'), findsNothing);
  });

  testWidgets(
      'result lists semantic output from every turn without prompt echoes',
      (tester) async {
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '列出所有宠物',
          rawOutput: '',
          cleanedOutput: '列出所有宠物\n实际宠物：momo、Summer。',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续输出 Summer',
          rawOutput: '',
          cleanedOutput: '''
列出所有宠物
实际宠物：momo、Summer。
继续输出 Summer
Summer：海滩风格 Codex 宠物。
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-3',
          taskId: 'task-1',
          turnIndex: 3,
          userInput: '补充尺寸',
          rawOutput: '',
          cleanedOutput: '''
列出所有宠物
实际宠物：momo、Summer。
继续输出 Summer
Summer：海滩风格 Codex 宠物。
补充尺寸
精灵图集尺寸为 1536 x 1872。
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
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
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    expect(find.text('Turn 1'), findsOneWidget);
    expect(find.text('Turn 2'), findsOneWidget);
    expect(find.text('Turn 3'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Turn 3')).dy,
      lessThan(tester.getTopLeft(find.text('Turn 2')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Turn 2')).dy,
      lessThan(tester.getTopLeft(find.text('Turn 1')).dy),
    );
    expect(find.textContaining('实际宠物：momo、Summer'), findsOneWidget);
    expect(find.textContaining('Summer：海滩风格 Codex 宠物'), findsOneWidget);
    expect(find.textContaining('精灵图集尺寸为 1536 x 1872'), findsOneWidget);
    expect(find.text('继续输出 Summer'), findsNothing);
    expect(find.text('补充尺寸'), findsNothing);
  });

  testWidgets('result omits turns waiting for terminal interaction',
      (tester) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.needAttention,
      terminalPrompt: const TerminalPrompt(
        question: 'Allow this command to run? Redirection detected.',
        command: 'python -m pytest tests/test_hello_world.py',
        options: [
          TerminalPromptOption(key: '1', label: 'Allow once'),
          TerminalPromptOption(key: '4', label: 'No'),
        ],
      ),
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '执行测试',
          rawOutput: '',
          cleanedOutput: '''
Tool: Bash
Command: python -m pytest tests/test_hello_world.py
Allow this command to run? Redirection detected.
1. Allow once
4. No
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.needAttention,
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
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    expect(find.text('Turn 1'), findsNothing);
    expect(find.text('暂无结果'), findsOneWidget);
  });

  testWidgets('result refreshes after reloading updated turns', (tester) async {
    final now = DateTime(2026, 5, 18);
    final initialTask = _task().copyWith(
      status: TaskStatus.turnIdle,
      updatedAt: now,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出hello',
          rawOutput: 'hello',
          cleanedOutput: 'hello',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
      ],
    );
    final store = _TaskStore(initialTask);
    final state = ArminAppState(
      store: store,
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
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    expect(find.textContaining('hello'), findsWidgets);
    expect(find.textContaining('world'), findsNothing);

    store.task = initialTask.copyWith(
      updatedAt: now.add(const Duration(minutes: 1)),
      turns: [
        ...initialTask.turns,
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '输出world',
          rawOutput: 'world',
          cleanedOutput: 'world',
          startedAt: now.add(const Duration(seconds: 10)),
          lastOutputAt: now.add(const Duration(seconds: 10)),
          status: NativeOutputTurnStatus.turnIdle,
        ),
      ],
    );
    await state.load();
    await tester.pumpAndSettle();

    expect(find.textContaining('world'), findsWidgets);
  });

  testWidgets(
      'resuming the app returns to latest result turn and scrolls to top',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 hello',
          rawOutput: 'hello',
          cleanedOutput: 'hello',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续输出 world',
          rawOutput: 'world',
          cleanedOutput: 'world',
          startedAt: now.add(const Duration(seconds: 1)),
          lastOutputAt: now.add(const Duration(seconds: 1)),
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-3',
          taskId: 'task-1',
          turnIndex: 3,
          userInput: '继续输出 armin',
          rawOutput: 'armin',
          cleanedOutput: 'armin',
          startedAt: now.add(const Duration(seconds: 2)),
          lastOutputAt: now.add(const Duration(seconds: 2)),
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-4',
          taskId: 'task-1',
          turnIndex: 4,
          userInput: '继续输出 latest',
          rawOutput: 'latest',
          cleanedOutput: 'latest',
          startedAt: now.add(const Duration(seconds: 3)),
          lastOutputAt: now.add(const Duration(seconds: 3)),
          status: NativeOutputTurnStatus.turnIdle,
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
    await tester.tap(find.text('结果'));
    await tester.pumpAndSettle();

    final resultList =
        find.byKey(const PageStorageKey<String>('task-detail-result-list'));
    await tester.drag(resultList, const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(find.text('Turn 4').hitTestable(), findsNothing);

    await tester.tap(find.text('指标'));
    await tester.pumpAndSettle();
    expect(find.text('Turn 4').hitTestable(), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();

    expect(find.text('结果'), findsOneWidget);
    expect(find.text('Turn 4').hitTestable(), findsOneWidget);
    expect(find.text('Turn 3').hitTestable(), findsOneWidget);
  });

  testWidgets('timeline lists latest turns first and expands scoped output',
      (tester) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 5, 18);
    final task = _task().copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 Taro',
          rawOutput: '''
输出 Taro
Thinking
Taro 是一只小型疲惫兔子开发者桌面宠物。
''',
          cleanedOutput: 'Taro 是一只小型疲惫兔子开发者桌面宠物。',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续输出 Summer',
          rawOutput: '''
输出 Taro
Thinking
Taro 是一只小型疲惫兔子开发者桌面宠物。
继续输出 Summer
Thinking
Summer 是一个桌面宠物。
''',
          cleanedOutput: '''
输出 Taro
Taro 是一只小型疲惫兔子开发者桌面宠物。
继续输出 Summer
Summer 是一个桌面宠物。
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
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
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'task-1')),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Turn 2：追加指令'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Turn 2：追加指令')).dy,
      lessThan(tester.getTopLeft(find.text('Turn 1：初始任务')).dy),
    );
    expect(find.text('展开完整输出'), findsNWidgets(2));
    expect(find.textContaining('Summer 是一个桌面宠物'), findsNothing);

    await tester.tap(find.text('展开完整输出').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Summer 是一个桌面宠物'), findsOneWidget);
    expect(find.textContaining('Taro 是一只小型疲惫兔子'), findsNothing);
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

  testWidgets('detail banner shows project cli and editable title',
      (tester) async {
    final task = _task().copyWith(
      title: '旧标题',
      userText: '初始提示词内容',
      host: _task().host.copyWith(
            projectPath: '~/workspace/armin',
            agentCommand: 'qoder',
          ),
    );
    final state = ArminAppState(
      store: _TaskStore(
        task,
        projectPaths: [
          ProjectPathConfig(
            id: 'project-1',
            name: 'Armin',
            path: '~/workspace/armin',
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
          ),
        ],
      ),
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

    expect(find.text('Prompt'), findsNothing);
    expect(find.text('项目名：'), findsOneWidget);
    expect(find.text('Armin'), findsOneWidget);
    expect(find.text('CLI：'), findsOneWidget);
    expect(find.text('qoder'), findsOneWidget);
    expect(find.textContaining('初始提示词内容'), findsNothing);
    expect(find.byKey(const Key('task-title-field')), findsNothing);

    await tester.tap(find.byTooltip('编辑标题'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-title-field')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('task-title-field')), '新标题');
    await tester.tap(find.byTooltip('保存标题'));
    await tester.pumpAndSettle();

    expect(state.tasks.single.title, '新标题');
    expect(find.text('新标题'), findsWidgets);
  });

  testWidgets('task title fallback is consistent across list and detail',
      (tester) async {
    final task = _task().copyWith(title: '');
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: const _NoopAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskCard(task: task, onTap: () {}),
        ),
      ),
    );
    expect(find.text('未命名任务'), findsOneWidget);

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDetailScreen(taskId: 'task-1'),
        ),
      ),
    );
    expect(find.text('未命名任务'), findsWidgets);
    expect(find.byTooltip('编辑标题'), findsOneWidget);
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
  _TaskStore(this.task, {this.projectPaths = const []});

  TaskSession task;
  final List<ProjectPathConfig> projectPaths;

  @override
  Future<List<HostConfig>> loadHosts() async => [task.host];

  @override
  Future<List<TaskSession>> loadTasks() async => [task];

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => projectPaths;

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

class _DelayedFollowUpAgent extends _CapturingAgent {
  final Completer<void> _followUpCompleter = Completer<void>();

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    lastFollowUp = request.instruction;
    await _followUpCompleter.future;
  }

  void completeFollowUp() => _followUpCompleter.complete();
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

class _CustomDisplaySummaryProvider implements OutputSummaryProvider {
  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    return const OutputSummary(
      displaySummary: '页面展示文本 hello world',
      speechSummary: '旧语音文本 should not win',
    );
  }
}
