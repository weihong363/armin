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
    final segments = buildSpeechSegmentsForTest(summary);
    if (segments.isEmpty) {
      return;
    }
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setVolume(1.0);
    for (final segment in segments) {
      final profile = speechProfileForTest(segment.languageCode);
      try {
        await _flutterTts.setLanguage(segment.languageCode);
      } catch (_) {
        await _flutterTts.setLanguage('zh-CN');
      }
      await _flutterTts.setSpeechRate(profile.speechRate);
      await _flutterTts.setPitch(profile.pitch);
      await _flutterTts.speak(segment.text);
    }
  }

  @visibleForTesting
  static List<SpeechSummarySegment> buildSpeechSegmentsForTest(
    String summary,
  ) {
    final text = cleanSpeechSummaryForTest(summary);
    if (text.isEmpty) {
      return const [];
    }
    return text
        .split(RegExp(r'(?<=[。！？.!?])\s+|\n+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map(
          (part) => SpeechSummarySegment(
            text: part,
            languageCode: _isEnglishDominant(part) ? 'en-US' : 'zh-CN',
          ),
        )
        .toList(growable: false);
  }

  @visibleForTesting
  static String cleanSpeechSummaryForTest(String summary) {
    final withoutBlocks = summary
        .replaceAll(RegExp(r'```[\s\S]*?```'), '\n')
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (match) => match.group(1)!);
    final lines = withoutBlocks
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !_isSpeechNoiseLine(line))
        .map(_cleanSpeechLine)
        .where((line) => line.isNotEmpty)
        .toList();
    return _joinSpeechLines(lines);
  }

  @visibleForTesting
  static SpeechVoiceProfile speechProfileForTest(String languageCode) {
    return languageCode == 'en-US'
        ? const SpeechVoiceProfile(speechRate: 0.54, pitch: 1.0)
        : const SpeechVoiceProfile(speechRate: 0.58, pitch: 0.98);
  }

  static String _cleanSpeechLine(String line) {
    return line
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .replaceAll(RegExp(r'https?://\S+'), '')
        .trim();
  }

  static bool _isSpeechNoiseLine(String line) {
    final lower = line.toLowerCase();
    return lower.startsWith('```') ||
        lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('final ') ||
        lower.startsWith('const ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        lower.startsWith('npm ') ||
        lower.startsWith('flutter ') ||
        lower.startsWith('dart ') ||
        lower.startsWith('git ') ||
        lower.startsWith('ssh ') ||
        lower.startsWith('tmux ') ||
        lower == 'explored' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.contains(' to view transcript') ||
        lower.startsWith('path:') ||
        lower.startsWith('file:') ||
        lower.contains('://') ||
        lower.contains('/users/') ||
        lower.contains('/workspace/') ||
        lower.contains('package:') ||
        lower.contains('stack trace') ||
        lower.contains('exception') ||
        _looksLikeCode(line);
  }

  static bool _looksLikeCode(String line) {
    final symbols = RegExp(r'[{};=<>]').allMatches(line).length;
    if (symbols >= 2) {
      return true;
    }
    return RegExp(r'\w+\([^)]*\)').hasMatch(line) &&
        !RegExp(r'[\u4e00-\u9fff]').hasMatch(line);
  }

  static bool _isEnglishDominant(String text) {
    final letters = RegExp(r'[A-Za-z]').allMatches(text).length;
    final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    return letters > 0 && letters >= chinese * 2;
  }

  static String _joinSpeechLines(List<String> lines) {
    final buffer = StringBuffer();
    for (final line in lines) {
      if (buffer.isEmpty) {
        buffer.write(line);
        continue;
      }
      final previous = buffer.toString().trimRight();
      final separator = RegExp(r'[。！？.!?]$').hasMatch(previous) ? ' ' : '。';
      buffer
        ..clear()
        ..write(previous)
        ..write(separator)
        ..write(line);
    }
    return buffer.toString().trim();
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

@visibleForTesting
class SpeechSummarySegment {
  const SpeechSummarySegment({
    required this.text,
    required this.languageCode,
  });

  final String text;
  final String languageCode;
}

@visibleForTesting
class SpeechVoiceProfile {
  const SpeechVoiceProfile({
    required this.speechRate,
    required this.pitch,
  });

  final double speechRate;
  final double pitch;
}
