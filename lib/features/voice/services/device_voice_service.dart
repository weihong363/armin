import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_service.dart';

class DeviceVoiceService implements VoiceService {
  DeviceVoiceService({
    SpeechToText? speechToText,
    FlutterTts? flutterTts,
    Duration listenTimeout = const Duration(seconds: 8),
    String localeId = 'zh_CN',
  })  : _speechToText = speechToText ?? SpeechToText(),
        _flutterTts = flutterTts ?? FlutterTts(),
        _listenTimeout = listenTimeout,
        _localeId = localeId;

  final SpeechToText _speechToText;
  final FlutterTts _flutterTts;
  final Duration _listenTimeout;
  final String _localeId;

  @override
  Future<String> listenOnce() async {
    final available = await _speechToText.initialize();
    if (!available) {
      throw StateError('Speech recognition is not available on this device.');
    }

    var latestWords = '';
    final completed = Completer<void>();

    await _speechToText.listen(
      localeId: _localeId,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
      ),
      onResult: (SpeechRecognitionResult result) {
        latestWords = result.recognizedWords;
        if (result.finalResult && !completed.isCompleted) {
          completed.complete();
        }
      },
    );

    await Future.any([
      completed.future,
      Future<void>.delayed(_listenTimeout),
    ]);
    await _speechToText.stop();
    return latestWords.trim();
  }

  @override
  Future<void> speakSummary(String summary) async {
    final text = summary.trim();
    if (text.isEmpty) {
      return;
    }
    await _flutterTts.setLanguage('zh-CN');
    await _flutterTts.setSpeechRate(0.48);
    await _flutterTts.speak(text);
  }
}
