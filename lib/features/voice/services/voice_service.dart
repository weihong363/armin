abstract class VoiceService {
  Future<String> listenOnce();

  Future<void> speakSummary(String summary);
}
