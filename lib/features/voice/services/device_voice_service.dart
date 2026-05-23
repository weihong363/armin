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
    SpeechVoiceStyle voiceStyle = SpeechVoiceStyle.clearFemale,
  })  : _speechToText = speechToText ?? SpeechToText(),
        _flutterTts = flutterTts ?? FlutterTts(),
        _listenTimeout = listenTimeout,
        _localeId = localeId,
        _voiceStyle = voiceStyle;

  final SpeechToText _speechToText;
  final FlutterTts _flutterTts;
  final Duration _listenTimeout;
  final String _localeId;
  SpeechVoiceStyle _voiceStyle;
  bool? _available;
  bool _isListening = false;
  String _latestWords = '';
  final Set<String> _selectedVoiceLanguages = {};

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
      await _selectPreferredVoice(segment.languageCode);
      final styledProfile = profile.forStyle(_voiceStyle);
      await _flutterTts.setSpeechRate(styledProfile.speechRate);
      await _flutterTts.setPitch(styledProfile.pitch);
      await _flutterTts.speak(segment.text);
    }
  }

  void updateVoiceStyle(SpeechVoiceStyle style) {
    if (_voiceStyle == style) {
      return;
    }
    _voiceStyle = style;
    _selectedVoiceLanguages.clear();
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
    return cleanSpeechSummary(summary);
  }

  static String cleanSpeechSummary(String summary) {
    final withoutBlocks = _removeFencedCode(summary)
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
        ? const SpeechVoiceProfile(speechRate: 0.58, pitch: 1.04)
        : const SpeechVoiceProfile(speechRate: 0.65, pitch: 1.06);
  }

  @visibleForTesting
  static Map<String, String>? preferredVoiceForTest(
    List<Map<String, String>> voices,
    String languageCode,
  ) {
    return _preferredVoice(voices, languageCode);
  }

  static String _cleanSpeechLine(String line) {
    return line
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .replaceAll(RegExp(r'https?://\S+'), '')
        .trim();
  }

  static String _removeFencedCode(String text) {
    final lines = text.replaceAll('\r', '\n').split('\n');
    final kept = <String>[];
    var inBlock = false;
    for (final line in lines) {
      final fenceCount = RegExp('```').allMatches(line).length;
      if (fenceCount > 0) {
        if (fenceCount.isOdd) {
          inBlock = !inBlock;
        }
        continue;
      }
      if (!inBlock) {
        kept.add(line);
      }
    }
    return kept.join('\n');
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

  Future<void> _selectPreferredVoice(String languageCode) async {
    if (_selectedVoiceLanguages.contains(languageCode)) {
      return;
    }
    _selectedVoiceLanguages.add(languageCode);
    try {
      final voices = await _flutterTts.getVoices;
      if (voices is! List) {
        return;
      }
      final normalized = voices
          .whereType<Map>()
          .map((voice) => voice.map(
                (key, value) => MapEntry('$key', '$value'),
              ))
          .toList(growable: false);
      final preferred = _preferredVoice(normalized, languageCode);
      if (preferred != null) {
        await _flutterTts.setVoice(preferred);
      }
    } catch (_) {
      // Voice catalog support varies by platform; language fallback is enough.
    }
  }

  static Map<String, String>? _preferredVoice(
    List<Map<String, String>> voices,
    String languageCode,
  ) {
    final requested = languageCode.toLowerCase().replaceAll('_', '-');
    final candidates = voices.where((voice) {
      final locale = (voice['locale'] ?? voice['language'] ?? '')
          .toLowerCase()
          .replaceAll('_', '-');
      return locale == requested ||
          locale.startsWith(requested.split('-').first);
    }).toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => _voiceScore(b).compareTo(_voiceScore(a)));
    return candidates.first;
  }

  static int _voiceScore(Map<String, String> voice) {
    final text =
        '${voice['name'] ?? ''} ${voice['gender'] ?? ''}'.toLowerCase();
    var score = 0;
    for (final marker in _femaleVoiceMarkers) {
      if (text.contains(marker)) {
        score += 3;
      }
    }
    for (final marker in _clearVoiceMarkers) {
      if (text.contains(marker)) {
        score += 2;
      }
    }
    return score;
  }

  static const _femaleVoiceMarkers = [
    'female',
    'woman',
    'xiaoxiao',
    'tingting',
    'mei',
    'siri female',
  ];

  static const _clearVoiceMarkers = [
    'premium',
    'enhanced',
    'neural',
    'clear',
  ];
}

enum SpeechVoiceStyle {
  systemDefault,
  clearFemale,
  fastFemale,
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

  SpeechVoiceProfile forStyle(SpeechVoiceStyle style) {
    return switch (style) {
      SpeechVoiceStyle.systemDefault => SpeechVoiceProfile(
          speechRate: speechRate - 0.05,
          pitch: pitch - 0.04,
        ),
      SpeechVoiceStyle.clearFemale => this,
      SpeechVoiceStyle.fastFemale => SpeechVoiceProfile(
          speechRate: speechRate + 0.06,
          pitch: pitch + 0.01,
        ),
    };
  }
}
