import 'package:armin/features/voice/services/voice_service.dart';

class MockVoiceService implements VoiceService {
  MockVoiceService({
    this.recognizedText = '嗯 帮我先看看这个页面为什么登录失败，先别大改，然后跑一下测试，别提交',
    this.available = true,
  });

  final String recognizedText;
  final bool available;
  final List<String> spokenSummaries = [];
  int stopSpeakingCount = 0;
  String _latestWords = '';

  @override
  bool get isAvailable => available;

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {
    if (!available) {
      throw const VoiceUnavailableException('当前设备不支持语音，请手动输入');
    }
    _latestWords = recognizedText;
    onPartial?.call(_latestWords);
  }

  @override
  Future<String> stopListening() async {
    return _latestWords.trim();
  }

  @override
  Future<String> listenOnce() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await startListening();
    return stopListening();
  }

  @override
  Future<void> speakSummary(String summary) async {
    spokenSummaries.add(summary);
  }

  @override
  Future<void> pauseSpeaking() async {}

  @override
  Future<void> stopSpeaking() async {
    stopSpeakingCount++;
  }
}
