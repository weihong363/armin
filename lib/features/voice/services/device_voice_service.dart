import 'dart:async';

import 'package:flutter/foundation.dart';
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
  bool? _available;
  bool _isListening = false;
  String _latestWords = '';

  @override
  bool get isAvailable => _available != false;

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {
    await _ensureAvailable();
    if (_isListening) {
      await _speechToText.stop();
    }

    _latestWords = '';
    _isListening = true;
    await _speechToText.listen(
      localeId: _localeId,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
      ),
      onResult: (SpeechRecognitionResult result) {
        _latestWords = result.recognizedWords;
        onPartial?.call(_latestWords);
      },
    );
  }

  @override
  Future<String> stopListening() async {
    if (!_isListening) {
      return _latestWords.trim();
    }

    await _speechToText.stop();
    _isListening = false;
    return _latestWords.trim();
  }

  @override
  Future<String> listenOnce() async {
    try {
      final completed = Completer<void>();
      await startListening(
        onPartial: (_) {
          if (!completed.isCompleted && _latestWords.isNotEmpty) {
            completed.complete();
          }
        },
      );

      await Future.any([
        completed.future,
        Future<void>.delayed(_listenTimeout),
      ]);

      return stopListening();
    } catch (e) {
      await stopListening();
      rethrow;
    }
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

  Future<void> _ensureAvailable() async {
    if (_available == true) {
      return;
    }

    final available = await _speechToText.initialize();
    _available = available;
    if (available) {
      return;
    }

    try {
      final locales = await _speechToText.locales();
      debugPrint('Available locales: $locales');
    } catch (_) {
      // Locale diagnostics must not crash the UI.
    }

    throw const VoiceUnavailableException('当前设备不支持语音，请手动输入');
  }
}
