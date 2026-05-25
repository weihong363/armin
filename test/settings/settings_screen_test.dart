import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('settings routes execution and speech configuration separately',
      (tester) async {
    await _pumpSettings(tester);

    expect(find.text('执行环境'), findsOneWidget);
    expect(find.text('主机连接'), findsOneWidget);
    expect(find.text('项目目录'), findsOneWidget);
    expect(find.text('语音与播报'), findsWidgets);
  });

  testWidgets('settings opens host connection configuration', (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('settings-hosts')));
    await tester.pumpAndSettle();

    expect(find.text('主机连接'), findsOneWidget);
    expect(find.text('添加主机'), findsOneWidget);
  });

  testWidgets('settings opens project path configuration', (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('settings-project-paths')));
    await tester.pumpAndSettle();

    expect(find.text('项目目录'), findsOneWidget);
    expect(find.text('添加目录'), findsOneWidget);
  });

  testWidgets('settings opens voice configuration', (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('settings-voice')));
    await tester.pumpAndSettle();

    expect(find.text('语音与播报'), findsWidgets);
    expect(find.text('自动播报任务输出'), findsOneWidget);
  });
}

Future<void> _pumpSettings(WidgetTester tester) async {
  final state = ArminAppState(
    store: InMemoryTaskHistoryStore(),
    agentSessionService: MockAgentSessionService(),
    voiceService: MockVoiceService(),
  );
  await state.load();
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pump();
}
