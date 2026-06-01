import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/voice/screens/voice_settings_screen.dart';
import 'package:armin/features/voice/services/device_voice_service.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
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

  testWidgets('voice preview failure is handled without crashing',
      (tester) async {
    final voice = _FailingPreviewVoiceService();
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
    expect(find.textContaining('语音预览失败'), findsOneWidget);
    expect(voice.spokenSummaries, hasLength(0));
    expect(voice.stopSpeakingCount, 1);
  });

  testWidgets('local summary toggle enables optional provider with fallback',
      (tester) async {
    final state = ArminAppState(
      store: InMemoryTaskHistoryStore(),
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
    );
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: VoiceSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('当前未安装端侧摘要模型'), findsOneWidget);
    await tester.tap(find.text('端侧摘要增强（实验）'));
    await tester.pumpAndSettle();

    expect(state.speechSettings.preferLocalSummaryModel, isTrue);
    final summary = await state.outputSummaryProvider.summarize(
      const OutputSummaryRequest(
        cleanedOutput: '已找到结果。',
        status: TaskStatus.turnIdle,
      ),
    );
    expect(summary.displaySummary, '已找到结果。');
    expect(summary.fallbackReason, 'local small model unavailable');
  });
}

class _FailingPreviewVoiceService extends MockVoiceService {
  @override
  Future<void> speakSummary(String summary) async {
    throw const VoiceUnavailableException('系统语音引擎未开始朗读');
  }
}
