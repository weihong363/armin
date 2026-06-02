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
    final cleaned = cleanSpeechTextForTest(summary);
    if (cleaned.isEmpty) {
      throw const VoiceUnavailableException('没有可朗读的结果内容');
    }
    await _flutterTts.stop();
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setVolume(1.0);
    try {
      await _flutterTts.setQueueMode(0);
    } catch (_) {
      // Queue control is Android-only; other platforms can ignore it.
    }
    await _speakConnectedSummary(cleaned);
  }

  @override
  Future<void> stopSpeaking() async {
    await _flutterTts.stop();
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
    final text = cleanSpeechTextForTest(summary);
    if (text.isEmpty) {
      return const [];
    }
    return text
        .split(RegExp(r'(?<=[。！？.!?])\s+|\n+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .expand(_splitMixedLanguageSegment)
        .expand(_splitLongSpeechSegment)
        .toList(growable: false);
  }

  @visibleForTesting
  static String cleanSpeechSummaryForTest(String summary) {
    return cleanSpeechSummary(summary);
  }

  static String cleanSpeechSummary(String summary) {
    return _compactForSpeech(_normalizeSpeechSpacing(cleanSpeechText(summary)));
  }

  @visibleForTesting
  static String cleanSpeechTextForTest(String summary) {
    return cleanSpeechText(summary);
  }

  static String cleanSpeechText(String summary) {
    final withoutBlocks = _removeFencedCode(summary)
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (match) => match.group(1)!);
    final lines = withoutBlocks
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .map(_extractReadableSpeechLine)
        .where((line) => line.isNotEmpty && !_isSpeechNoiseLine(line))
        .map(_cleanSpeechLine)
        .map(_applyPronunciationHints)
        .map(_normalizeSpeechSpacing)
        .where((line) => line.isNotEmpty)
        .toList();
    return _normalizeSpeechSpacing(_joinSpeechLines(lines));
  }

  @visibleForTesting
  static SpeechVoiceProfile speechProfileForTest(String languageCode) {
    return languageCode == 'en-US'
        ? const SpeechVoiceProfile(speechRate: 0.60, pitch: 1.00)
        : const SpeechVoiceProfile(speechRate: 0.72, pitch: 1.07);
  }

  @visibleForTesting
  static SpeechVoiceProfile speechProfileForLanguageForTest(
    String languageCode, [
    SpeechVoiceStyle style = SpeechVoiceStyle.clearFemale,
  ]) {
    return _speechProfileForLanguage(languageCode, style);
  }

  @visibleForTesting
  static Duration speakTimeoutForTest(String text) {
    return _speakTimeout(text);
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
        .replaceAll(
          RegExp(r".*you['’]ve hit your usage limit.*", caseSensitive: false),
          '额度已用完，请稍后重试。',
        )
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _applyPronunciationHints(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<![A-Za-z0-9])一行(?![A-Za-z0-9])'),
      (match) => '${match.group(0)}（háng）',
    );
  }

  static String _normalizeSpeechSpacing(String text) {
    var normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    normalized = normalized.replaceAllMapped(
      RegExp(r'\s+([，。！？；：、,.!?;:）】}])'),
      (match) => match.group(1)!,
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([，。！？；：、])\s+'),
      (match) => match.group(1)!,
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([（【{])\s+'),
      (match) => match.group(1)!,
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'),
      (match) => '${match.group(1)!}${match.group(2)!}',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([\u4e00-\u9fff])\s+([A-Za-z0-9#])'),
      (match) => '${match.group(1)!}${match.group(2)!}',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([A-Za-z0-9])\s+([\u4e00-\u9fff])'),
      (match) => '${match.group(1)!}${match.group(2)!}',
    );
    return normalized;
  }

  static String _extractReadableSpeechLine(String line) {
    var text = line
        .replaceFirst(RegExp(r'^[>▸▪■\s•*-]+'), '')
        .replaceAll(RegExp(r'[▸▪■]+'), ' ')
        .trim();
    text = text
        .replaceAll(
          RegExp(
            r'\b(?:Glob|Grep|Read)\([^)]*\)',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:Search|List|Ran|Opened|Edited|Checked)\b[^。！？\n]*',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'^completion:\s*tls handshake eof\b.*', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'\bType your message or @path/to/file\b.*',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\bAuto Model\b.*', caseSensitive: false), ' ')
        .replaceAll(
          RegExp(r'\bShift\+Tab to Auto-accept Edits\b.*',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\bAGENTS\.md file\b.*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bThinking\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'/Users/\S+'), ' ')
        .replaceAll(RegExp(r'/workspace/\S+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
      return text;
    }
    return text;
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
    final normalized = lower.replaceFirst(RegExp(r'^[•*-]\s+'), '').trim();
    if (normalized.contains('usage limit')) {
      return false;
    }
    return lower.startsWith('```') ||
        lower.startsWith('│') ||
        lower.contains('openai codex') ||
        lower.contains('qoder cli') ||
        lower.contains('completion: tls handshake eof') ||
        lower.contains('type your message or @path/to/file') ||
        lower.contains('auto model') ||
        lower.contains('shift+tab to auto-accept edits') ||
        lower.contains('agents.md file') ||
        lower.startsWith('turn ') ||
        lower.startsWith('tip:') ||
        lower.startsWith('model:') ||
        lower.startsWith('directory:') ||
        lower.startsWith('gpt-') ||
        normalized.startsWith('armin context governance:') ||
        _isSpeechGovernanceRule(normalized) ||
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
        lower.startsWith('use /') ||
        lower == 'explored' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.startsWith('read ') ||
        lower.startsWith('edited ') ||
        lower.startsWith('opened ') ||
        lower.startsWith('checked ') ||
        lower.startsWith('grep ') ||
        lower.startsWith('rg ') ||
        lower.startsWith('cat ') ||
        lower.startsWith('sed ') ||
        lower.startsWith('jq ') ||
        lower.startsWith('find ') ||
        lower.startsWith('apply_patch') ||
        lower.startsWith('changed files') ||
        lower.startsWith('validation') ||
        lower.startsWith('risks') ||
        lower.startsWith('next actions') ||
        lower.startsWith('summary:') ||
        lower.startsWith('status:') ||
        lower.startsWith('command:') ||
        lower.startsWith('reason:') ||
        lower.contains(' to view transcript') ||
        lower.contains('context left') ||
        lower.contains('mapping values are not allowed') ||
        lower.contains('invalid yaml') ||
        lower.contains('invalid skill.md') ||
        lower.contains('skipped loading') ||
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

  static bool _isSpeechGovernanceRule(String lower) {
    return lower == 'only inspect files directly related to the task.' ||
        lower == 'never scan the entire repository.' ||
        lower == 'avoid reading docs/ and readme unless necessary.' ||
        lower == 'keep edits minimal and focused.' ||
        lower == 'do not analyze unrelated architecture.' ||
        lower == 'run only targeted tests.' ||
        lower == 'keep command output short.';
  }

  static bool _looksLikeCode(String line) {
    final symbols = RegExp(r'[{};=<>]').allMatches(line).length;
    if (symbols >= 2) {
      return true;
    }
    return RegExp(r'\w+\([^)]*\)').hasMatch(line) &&
        !RegExp(r'[\u4e00-\u9fff]').hasMatch(line);
  }

  static List<SpeechSummarySegment> _splitMixedLanguageSegment(String text) {
    if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
      return [
        SpeechSummarySegment(
            text: _normalizeEnglishForSpeech(text), languageCode: 'en-US'),
      ];
    }

    final segments = <SpeechSummarySegment>[];
    final pattern = RegExp(r'[A-Za-z][A-Za-z0-9_+\-./]*'
        r'(?:\s+[A-Za-z][A-Za-z0-9_+\-./]*)*');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      final before = text.substring(index, match.start).trim();
      if (before.isNotEmpty) {
        segments.add(SpeechSummarySegment(text: before, languageCode: 'zh-CN'));
      }
      final english = _normalizeEnglishForSpeech(match.group(0)!);
      if (english.isNotEmpty && !_looksLikeCode(english)) {
        segments
            .add(SpeechSummarySegment(text: english, languageCode: 'en-US'));
      }
      index = match.end;
    }
    final tail = text.substring(index).trim();
    if (tail.isNotEmpty) {
      segments.add(SpeechSummarySegment(text: tail, languageCode: 'zh-CN'));
    }
    return _mergeAdjacentSpeechSegments(segments);
  }

  static List<SpeechSummarySegment> _mergeAdjacentSpeechSegments(
    List<SpeechSummarySegment> segments,
  ) {
    final merged = <SpeechSummarySegment>[];
    for (final segment in segments) {
      if (merged.isNotEmpty &&
          merged.last.languageCode == segment.languageCode) {
        final previous = merged.removeLast();
        merged.add(
          SpeechSummarySegment(
            text: '${previous.text} ${segment.text}'.trim(),
            languageCode: segment.languageCode,
          ),
        );
      } else {
        merged.add(segment);
      }
    }
    return merged;
  }

  static Iterable<SpeechSummarySegment> _splitLongSpeechSegment(
    SpeechSummarySegment segment,
  ) {
    final maxLength = segment.languageCode == 'en-US' ? 180 : 90;
    if (segment.text.length <= maxLength) {
      return [segment];
    }
    return _splitReadableChunks(segment.text, maxLength)
        .map(
          (text) => SpeechSummarySegment(
            text: text,
            languageCode: segment.languageCode,
          ),
        )
        .where((part) => part.text.isNotEmpty);
  }

  static List<String> _splitReadableChunks(String text, int maxLength) {
    final chunks = <String>[];
    final buffer = StringBuffer();
    final parts = RegExp(r'[^。！？.!?；;，,]+[。！？.!?；;，,]?')
        .allMatches(text)
        .map((match) => match.group(0)!.trim())
        .where((part) => part.isNotEmpty);
    for (final part in parts) {
      if (part.length > maxLength) {
        _flushSpeechChunk(buffer, chunks);
        chunks.addAll(_splitOversizedSpeechPart(part, maxLength));
        continue;
      }
      final candidate = buffer.isEmpty ? part : '${buffer.toString()} $part';
      if (candidate.length > maxLength) {
        _flushSpeechChunk(buffer, chunks);
        buffer.write(part);
      } else {
        buffer
          ..clear()
          ..write(candidate);
      }
    }
    _flushSpeechChunk(buffer, chunks);
    return chunks;
  }

  static List<String> _splitOversizedSpeechPart(String text, int maxLength) {
    final chunks = <String>[];
    var remaining = text.trim();
    while (remaining.length > maxLength) {
      var splitAt = remaining.lastIndexOf(' ', maxLength);
      if (splitAt < maxLength ~/ 2) {
        splitAt = maxLength;
      }
      chunks.add(remaining.substring(0, splitAt).trim());
      remaining = remaining.substring(splitAt).trim();
    }
    if (remaining.isNotEmpty) {
      chunks.add(remaining);
    }
    return chunks;
  }

  static void _flushSpeechChunk(StringBuffer buffer, List<String> chunks) {
    final text = buffer.toString().trim();
    if (text.isNotEmpty) {
      chunks.add(text);
    }
    buffer.clear();
  }

  static String _normalizeEnglishForSpeech(String text) {
    return text
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'[/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _compactForSpeech(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= 90) {
      return trimmed;
    }
    final sentences = trimmed
        .split(RegExp(r'(?<=[。！？.!?])\s*'))
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList();
    final buffer = StringBuffer();
    for (final sentence in sentences) {
      final candidate =
          buffer.isEmpty ? sentence : '${buffer.toString()} $sentence';
      if (candidate.length > 90) {
        break;
      }
      buffer
        ..clear()
        ..write(candidate);
      if (buffer.length >= 70) {
        break;
      }
    }
    final compacted =
        buffer.isEmpty ? trimmed.substring(0, 90) : buffer.toString();
    return compacted;
  }

  static Duration _speakTimeout(String text) {
    final cjkCount = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    final otherCount = text.length - cjkCount;
    final seconds = (cjkCount / 2.5 + otherCount / 8).ceil() + 3;
    return Duration(seconds: seconds.clamp(8, 90));
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

  Future<void> _speakConnectedSummary(String cleaned) async {
    await _flutterTts.stop();
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setVolume(1.0);
    final segments = buildSpeechSegmentsForTest(cleaned);
    if (segments.isEmpty) {
      throw const VoiceUnavailableException('没有可朗读的结果内容');
    }

    for (final segment in segments) {
      await _configureSpeechLanguage(segment.languageCode);
      final result = await _flutterTts
          .speak(segment.text, focus: true)
          .timeout(_speakTimeout(segment.text));
      if (result == 0 || result == false) {
        throw const VoiceUnavailableException('系统语音引擎未开始朗读');
      }
    }
  }

  Future<void> _configureSpeechLanguage(String languageCode) async {
    await _flutterTts.setLanguage(languageCode);
    await _selectPreferredVoice(languageCode);
    final profile = _speechProfileForLanguage(languageCode, _voiceStyle);
    await _flutterTts.setSpeechRate(profile.speechRate);
    await _flutterTts.setPitch(profile.pitch);
  }

  static SpeechVoiceProfile _speechProfileForLanguage(
    String languageCode,
    SpeechVoiceStyle style,
  ) {
    final profile = speechProfileForTest(languageCode);
    final styled = profile.forStyle(style);
    return switch (languageCode.toLowerCase().replaceAll('_', '-')) {
      'en-us' => SpeechVoiceProfile(
          speechRate: ((styled.speechRate - 0.02).clamp(0.42, 0.95)).toDouble(),
          pitch: ((styled.pitch - 0.01).clamp(0.8, 1.3)).toDouble(),
        ),
      _ => styled,
    };
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
    'english',
    'us english',
    'uk english',
    'samantha',
    'joanna',
    'victoria',
    'ava',
    'karen',
    'allison',
    'serena',
    'zira',
    'google',
    'microsoft',
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
