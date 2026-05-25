import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import '../features/agent/services/mock_agent_session_service.dart';
import 'package:armin/features/tasks/screens/task_home_screen.dart';
import '../features/voice/services/mock_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home microphone shows recognized voice output', (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复首页登录失败'),
    );

    await _pressAndReleaseHomeMic(tester);

    expect(find.byKey(const ValueKey('home-voice-panel')), findsOneWidget);
    expect(find.text('修复首页登录失败'), findsOneWidget);
    expect(find.text('写入草稿'), findsOneWidget);
  });

  testWidgets('home voice panel can return to home', (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复首页登录失败'),
    );

    await _pressAndReleaseHomeMic(tester);
    await tester.tap(find.byKey(const ValueKey('home-voice-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-voice-panel')), findsNothing);
  });

  testWidgets('home voice result opens draft with initial task text',
      (tester) async {
    await _pumpHome(
      tester,
      voiceService: MockVoiceService(recognizedText: '修复首页登录失败'),
    );

    await _pressAndReleaseHomeMic(tester);
    await tester.tap(find.byKey(const ValueKey('home-voice-use-result')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, '修复首页登录失败');
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
    expect(find.text('历史'), findsOneWidget);
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();

    expect(find.text('历史任务'), findsOneWidget);
    expect(find.text('暂无历史任务'), findsOneWidget);
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required MockVoiceService voiceService,
}) async {
  final state = ArminAppState(
    store: InMemoryTaskHistoryStore(),
    agentSessionService: MockAgentSessionService(),
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
}

Future<void> _pressAndReleaseHomeMic(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('home-voice-button'));
  final gesture = await tester.startGesture(tester.getCenter(button));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}
