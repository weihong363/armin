import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../tasks/services/output_summary_provider.dart';
import '../services/device_voice_service.dart';
import '../services/task_speech_policy.dart';
import '../services/voice_service.dart';

class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  Future<LocalSummaryCapability>? _localSummaryCapability;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _localSummaryCapability ??=
        AppStateScope.of(context).localSummaryCapability();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final settings = state.speechSettings;
    return Scaffold(
      appBar: AppBar(title: const Text('语音与播报')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          SwitchListTile(
            title: const Text('自动播报任务输出'),
            subtitle: const Text('任务完成、失败或等待继续时自动读出摘要'),
            value: settings.enabled,
            onChanged: (value) => _update(
              context,
              settings.copyWith(enabled: value),
            ),
          ),
          SwitchListTile(
            title: const Text('播报任务结果'),
            subtitle: const Text('包含完成、失败和运行时断开'),
            value: settings.speakResults,
            onChanged: settings.enabled
                ? (value) => _update(
                      context,
                      settings.copyWith(speakResults: value),
                    )
                : null,
          ),
          SwitchListTile(
            title: const Text('播报需处理事项'),
            subtitle: const Text('包含等待继续、需要处理和确认请求'),
            value: settings.speakAttention,
            onChanged: settings.enabled
                ? (value) => _update(
                      context,
                      settings.copyWith(speakAttention: value),
                    )
                : null,
          ),
          SwitchListTile(
            title: const Text('端侧摘要增强（实验）'),
            subtitle: const Text('仅提炼结果重点，不参与 Agent 执行；不可用时自动回退'),
            value: settings.preferLocalSummaryModel,
            onChanged: (value) => _update(
              context,
              settings.copyWith(preferLocalSummaryModel: value),
            ),
          ),
          FutureBuilder<LocalSummaryCapability>(
            future: _localSummaryCapability,
            builder: (context, snapshot) {
              final message = snapshot.data?.message ?? '正在检测端侧摘要能力...';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('音色风格', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<SpeechVoiceStyle>(
            segments: const [
              ButtonSegment(
                value: SpeechVoiceStyle.systemDefault,
                label: Text('系统默认'),
              ),
              ButtonSegment(
                value: SpeechVoiceStyle.clearFemale,
                label: Text('清晰女性'),
              ),
              ButtonSegment(
                value: SpeechVoiceStyle.fastFemale,
                label: Text('快速女性'),
              ),
            ],
            selected: {settings.voiceStyle},
            onSelectionChanged: settings.enabled
                ? (selected) => _previewStyle(
                      context,
                      settings.copyWith(voiceStyle: selected.single),
                    )
                : null,
          ),
        ],
      ),
    );
  }

  void _update(BuildContext context, TaskSpeechSettings settings) {
    AppStateScope.of(context).updateSpeechSettings(settings);
  }

  Future<void> _previewStyle(
    BuildContext context,
    TaskSpeechSettings settings,
  ) async {
    final state = AppStateScope.of(context);
    state.updateSpeechSettings(settings);
    await state.voiceService.stopSpeaking();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    try {
      await state.voiceService.speakSummary(_previewText(settings.voiceStyle));
    } on VoiceUnavailableException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('语音预览失败：$error')),
      );
    }
  }

  String _previewText(SpeechVoiceStyle style) {
    return switch (style) {
      SpeechVoiceStyle.systemDefault => '你好，我是 Armin。这是系统默认语音。',
      SpeechVoiceStyle.clearFemale => '你好，我是 Armin。任务结果已整理完成。',
      SpeechVoiceStyle.fastFemale => '你好，我是 Armin。任务结果已完成，请查看重点。',
    };
  }
}
