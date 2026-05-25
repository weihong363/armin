import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/voice/screens/voice_settings_screen.dart';
import 'package:armin/features/voice/services/device_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../agent/services/mock_agent_session_service.dart';
import '../services/mock_voice_service.dart';

void main() {
  testWidgets('selecting voice style applies setting and plays preview',
      (tester) async {
    final voice = MockVoiceService();
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: MockAgentSessionService(),
      voiceService: voice,
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: VoiceSettingsScreen()),
      ),
    );

    await tester.tap(find.text('快速女性'));
    await tester.pumpAndSettle();

    expect(state.speechSettings.voiceStyle, SpeechVoiceStyle.fastFemale);
    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('任务结果已完成'));
  });
}
