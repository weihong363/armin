abstract class VoiceService {
  bool get isAvailable;

  Future<void> startListening({void Function(String partial)? onPartial});

  Future<String> stopListening();

  Future<String> listenOnce();

  Future<void> speakSummary(String summary);
}

class VoiceUnavailableException implements Exception {
  const VoiceUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
