import 'voice_service.dart';

class MockVoiceService implements VoiceService {
  @override
  Future<String> listenOnce() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return '嗯 帮我先看看这个页面为什么登录失败，先别大改，然后跑一下测试，别提交';
  }

  @override
  Future<void> speakSummary(String summary) async {
    return;
  }
}
