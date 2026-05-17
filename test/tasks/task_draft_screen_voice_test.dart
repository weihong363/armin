import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import '../features/agent/services/mock_agent_session_service.dart';
import 'package:armin/features/tasks/screens/task_draft_screen.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  testWidgets('initial task text is shown in task description', (tester) async {
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: TaskDraftScreen(initialTaskText: '首页语音结果'),
        ),
      ),
    );
    await tester.pump();

    expect(_taskDescription(tester), '首页语音结果');
  });

  testWidgets('press and hold voice input fills empty task description',
      (tester) async {
    await _pumpDraftScreen(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复登录失败'),
    );

    await _pressAndReleaseVoiceButton(tester);

    expect(_taskDescription(tester), '修复登录失败');
  });

  testWidgets('empty voice result does not overwrite manual input',
      (tester) async {
    await _pumpDraftScreen(
      tester,
      voiceService: MockVoiceService(recognizedText: ''),
    );
    await tester.enterText(find.byType(TextField).first, '保留手动输入');

    await _pressAndReleaseVoiceButton(tester);

    expect(_taskDescription(tester), '保留手动输入');
    expect(find.text('未检测到语音，请重试或手动输入'), findsOneWidget);
  });

  testWidgets('voice result appends to existing task description',
      (tester) async {
    await _pumpDraftScreen(
      tester,
      voiceService: MockVoiceService(recognizedText: '继续跑测试'),
    );
    await tester.enterText(find.byType(TextField).first, '先保留当前草稿');

    await _pressAndReleaseVoiceButton(tester);

    expect(_taskDescription(tester), '先保留当前草稿\n继续跑测试');
  });

  testWidgets('unavailable voice shows SnackBar without changing manual input',
      (tester) async {
    await _pumpDraftScreen(
      tester,
      voiceService: MockVoiceService(available: false),
    );
    await tester.enterText(find.byType(TextField).first, '手动输入仍可用');

    await _pressAndReleaseVoiceButton(tester);

    expect(_taskDescription(tester), '手动输入仍可用');
    expect(find.text('当前设备不支持语音，请手动输入'), findsOneWidget);
  });
}

Future<void> _pumpDraftScreen(
  WidgetTester tester, {
  required MockVoiceService voiceService,
}) async {
  final state = ArminAppState(
    store: InMemoryTaskHistoryStore(),
    agentSessionService: MockAgentSessionService(),
    voiceService: voiceService,
  );
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: TaskDraftScreen()),
    ),
  );
  // Load after pumping widget
  await state.load();
  await tester.pump();
}

Future<void> _pressAndReleaseVoiceButton(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('voice-hold-button'));
  final gesture = await tester.startGesture(tester.getCenter(button));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

String _taskDescription(WidgetTester tester) {
  final field = tester.widget<TextField>(find.byType(TextField).first);
  return field.controller!.text;
}
