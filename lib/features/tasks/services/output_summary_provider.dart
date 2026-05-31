import '../../../core/models/task_status.dart';
import '../../agent/services/codex_output_cleaner.dart';
import '../../voice/services/device_voice_service.dart';
import 'secret_redactor.dart';

class OutputSummaryRequest {
  const OutputSummaryRequest({
    required this.cleanedOutput,
    required this.status,
    this.taskTitle = '',
    this.promptInputs = const [],
    this.agentCommand = '',
  });

  final String cleanedOutput;
  final TaskStatus status;
  final String taskTitle;
  final List<String> promptInputs;
  final String agentCommand;
}

class OutputSummary {
  const OutputSummary({
    required this.displaySummary,
    required this.speechSummary,
    this.importantLines = const [],
    this.fallbackReason,
  });

  final String displaySummary;
  final String speechSummary;
  final List<String> importantLines;
  final String? fallbackReason;

  OutputSummary copyWith({
    String? displaySummary,
    String? speechSummary,
    List<String>? importantLines,
    String? fallbackReason,
  }) {
    return OutputSummary(
      displaySummary: displaySummary ?? this.displaySummary,
      speechSummary: speechSummary ?? this.speechSummary,
      importantLines: importantLines ?? this.importantLines,
      fallbackReason: fallbackReason ?? this.fallbackReason,
    );
  }
}

abstract class OutputSummaryProvider {
  Future<OutputSummary> summarize(OutputSummaryRequest request);
}

class RuleBasedOutputSummaryProvider implements OutputSummaryProvider {
  const RuleBasedOutputSummaryProvider({
    CodexOutputCleaner cleaner = const CodexOutputCleaner(),
    SecretRedactor redactor = const SecretRedactor(),
    this.maxDisplayLines = 4,
    this.maxDisplayChars = 420,
  })  : _cleaner = cleaner,
        _redactor = redactor;

  final CodexOutputCleaner _cleaner;
  final SecretRedactor _redactor;
  final int maxDisplayLines;
  final int maxDisplayChars;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final cleaned =
        _redactor.redactInlineSecrets(_cleaner.clean(request.cleanedOutput));
    final importantLines = _importantLines(cleaned, request);
    final display = _compactDisplay(importantLines.take(maxDisplayLines));
    final speech = DeviceVoiceService.cleanSpeechSummary(display);
    return OutputSummary(
      displaySummary: display,
      speechSummary: speech,
      importantLines: importantLines,
    );
  }

  List<String> _importantLines(String cleaned, OutputSummaryRequest request) {
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final lines = _semanticLines(cleaned)
        .where((line) => line.isNotEmpty)
        .where((line) => !_looksLikePromptEcho(line, promptInputs))
        .where((line) => !_looksLikeLowValueLine(line))
        .toList(growable: false);
    final semanticLines = _joinContinuationLines(lines);

    final scored = [
      for (var index = 0; index < semanticLines.length; index++)
        _ScoredLine(
          line: semanticLines[index],
          index: index,
          score: _scoreLine(semanticLines[index]),
        ),
    ];
    final useful = scored.where((item) => item.score >= 20).toList()
      ..sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        return scoreCompare == 0 ? a.index.compareTo(b.index) : scoreCompare;
      });
    final selected = useful.isEmpty
        ? scored.take(maxDisplayLines).toList()
        : useful.take(maxDisplayLines).toList();
    selected.sort((a, b) => a.index.compareTo(b.index));
    return selected.map((item) => item.line).toList(growable: false);
  }

  List<String> _semanticLines(String cleaned) {
    return cleaned
        .replaceAll('\r', '\n')
        .split('\n')
        .map(_semanticLine)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _semanticLine(String line) {
    var value = line.trim();
    if (value.isEmpty) {
      return '';
    }
    value = value
        .replaceFirst(RegExp(r'^[>›]\s*'), '')
        .replaceAll(RegExp(r"Glob\('[^']*'\)"), ' ')
        .replaceAll(RegExp(r"Grep\('[^']*'[^)]*\)", caseSensitive: false), ' ')
        .replaceAll(RegExp(r'Read\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\bThinking\b[.…]*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[▪■●•]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    value = _dropToolTracePrefix(value);
    return _normalizePetDescription(value);
  }

  String _dropToolTracePrefix(String line) {
    final natural = RegExp(
      r'([A-Za-z][A-Za-z0-9_-]*\s*[是:：].*)',
      caseSensitive: false,
    ).firstMatch(line);
    if (natural != null) {
      return natural.group(1)!.trim();
    }
    return line;
  }

  String _normalizePetDescription(String line) {
    final petMatch =
        RegExp(r'^([A-Za-z][A-Za-z0-9_-]*)\s+是\s+一\s+只\s+').firstMatch(line);
    if (petMatch == null) {
      return line;
    }
    final name = _titleCaseAsciiName(petMatch.group(1)!);
    return line.replaceFirst(petMatch.group(0)!, '$name是一只');
  }

  String _titleCaseAsciiName(String name) {
    if (name.isEmpty || name != name.toUpperCase()) {
      return name;
    }
    return name[0] + name.substring(1).toLowerCase();
  }

  List<String> _joinContinuationLines(List<String> lines) {
    final result = <String>[];
    for (final line in lines) {
      if (result.isNotEmpty && _looksLikeContinuation(line)) {
        result[result.length - 1] = '${result.last} $line';
      } else {
        result.add(line);
      }
    }
    return result;
  }

  bool _looksLikeContinuation(String line) {
    final lower = line.toLowerCase();
    if (RegExp(r'^\d+[.)]\s+').hasMatch(line) ||
        RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]{1,16}[:：]').hasMatch(line)) {
      return false;
    }
    if (lower == 'explored' ||
        lower == 'thinking' ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.startsWith('glob(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('read ') ||
        lower.startsWith('read(') ||
        lower.startsWith('edited ') ||
        lower.startsWith('opened ') ||
        lower.startsWith('checked ') ||
        lower.startsWith('shift+tab ')) {
      return false;
    }
    return true;
  }

  String _compactDisplay(Iterable<String> lines) {
    final values = lines.map(_compactLine).where((line) => line.isNotEmpty);
    final display = values.join('\n').trim();
    if (display.length <= maxDisplayChars) {
      return display;
    }
    return '${display.substring(0, maxDisplayChars).trimRight()}...';
  }

  String _compactLine(String line) {
    if (line.length <= maxDisplayChars) {
      return line;
    }
    final clauses = line
        .split(RegExp(r'[，,；;。]\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (clauses.length <= 1) {
      return '${line.substring(0, maxDisplayChars).trimRight()}...';
    }

    final selected = <String>[clauses.first];
    for (final clause in clauses.skip(1)) {
      if (_isKeyClause(clause)) {
        selected.add(clause);
      }
      final joined = selected.join('，');
      if (joined.length >= maxDisplayChars) {
        break;
      }
    }
    final compacted = selected.join('，');
    if (compacted.length <= maxDisplayChars) {
      return compacted;
    }
    return '${compacted.substring(0, maxDisplayChars).trimRight()}...';
  }

  bool _isKeyClause(String clause) {
    final lower = clause.toLowerCase();
    return RegExp(r'\d').hasMatch(clause) ||
        clause.contains('结果') ||
        clause.contains('实际') ||
        clause.contains('找到') ||
        clause.contains('包括') ||
        clause.contains('分别是') ||
        clause.contains('状态') ||
        clause.contains('像素') ||
        clause.contains('精灵图') ||
        clause.contains('成功') ||
        clause.contains('失败') ||
        lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('success');
  }

  int _scoreLine(String line) {
    final lower = line.toLowerCase();
    var score = 0;
    if (_looksLikeResultLine(line)) {
      score += 40;
    }
    if (line.contains('结论') ||
        line.contains('总结') ||
        line.contains('最终') ||
        line.contains('输出') ||
        line.contains('摘要')) {
      score += 25;
    }
    if (RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]+[:：]').hasMatch(line)) {
      score += 25;
    }
    if (RegExp(r'\d').hasMatch(line)) {
      score += 8;
    }
    if (lower.contains('pixel') ||
        line.contains('像素') ||
        line.contains('状态') ||
        line.contains('精灵图')) {
      score += 12;
    }
    return score;
  }

  Set<String> _taskWords(String taskTitle) {
    return taskTitle
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.length >= 3)
        .toSet();
  }

  bool _looksLikePromptEcho(
    String line,
    List<String> promptInputs,
  ) {
    final compactLine = line.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    for (final input in promptInputs) {
      final compactInput = input.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (compactInput.length >= 4 &&
          (compactLine == compactInput || compactLine.contains(compactInput))) {
        return true;
      }
      final taskWords = _taskWords(input);
      if (taskWords.isNotEmpty) {
        final lower = line.toLowerCase();
        final hits = taskWords.where(lower.contains).length;
        if (hits >= 3 && line.length <= 120) {
          return true;
        }
      }
    }
    return false;
  }

  bool _looksLikeLowValueLine(String line) {
    final lower = line.toLowerCase();
    return lower == '无' ||
        lower == 'none' ||
        lower == 'not_run' ||
        lower.startsWith('任务：') ||
        lower.startsWith('任务:') ||
        lower.startsWith('补充上下文') ||
        lower.startsWith('执行约束') ||
        lower.startsWith('风险信息') ||
        lower.startsWith('user constraints') ||
        lower.startsWith('## user constraints') ||
        lower == 'explored' ||
        lower == 'thinking' ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.startsWith('glob(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('read ') ||
        lower.startsWith('read(') ||
        lower.startsWith('edited ') ||
        lower.startsWith('opened ') ||
        lower.startsWith('checked ') ||
        lower.startsWith('shift+tab ') ||
        line.startsWith('过程记录') ||
        line.startsWith('继续从') ||
        line.startsWith('我先看一下');
  }

  bool _looksLikeResultLine(String line) {
    final lower = line.toLowerCase();
    return line.contains('已') ||
        line.contains('实际') ||
        line.contains('找到') ||
        line.contains('结果') ||
        line.contains('包括') ||
        line.contains('分别是') ||
        line.contains('成功') ||
        line.contains('失败') ||
        line.contains('额度已用完') ||
        _looksLikeEnglishStatusLine(lower);
  }

  bool _looksLikeEnglishStatusLine(String lower) {
    return RegExp(r'^(?:error|failed|success)(?:\s*[:：-]|\s|$)')
            .hasMatch(lower) ||
        RegExp(r'\b(?:error|failed|success)\s*[:：-]').hasMatch(lower);
  }
}

typedef LocalSmallModelSummaryRunner = Future<OutputSummary> Function(
  OutputSummaryRequest request,
);

class _ScoredLine {
  const _ScoredLine({
    required this.line,
    required this.index,
    required this.score,
  });

  final String line;
  final int index;
  final int score;
}

typedef LocalSmallModelAvailabilityCheck = Future<bool> Function();

class LocalSummaryCapability {
  const LocalSummaryCapability({
    required this.available,
    required this.message,
  });

  final bool available;
  final String message;
}

class LocalSmallModelSummaryProvider implements OutputSummaryProvider {
  const LocalSmallModelSummaryProvider({
    LocalSmallModelSummaryRunner? runner,
    LocalSmallModelAvailabilityCheck? availabilityCheck,
    OutputSummaryProvider fallback = const RuleBasedOutputSummaryProvider(),
    SecretRedactor redactor = const SecretRedactor(),
    this.timeout = const Duration(seconds: 3),
  })  : _runner = runner,
        _availabilityCheck = availabilityCheck,
        _fallback = fallback,
        _redactor = redactor;

  final LocalSmallModelSummaryRunner? _runner;
  final LocalSmallModelAvailabilityCheck? _availabilityCheck;
  final OutputSummaryProvider _fallback;
  final SecretRedactor _redactor;
  final Duration timeout;

  Future<LocalSummaryCapability> capability() async {
    if (_runner == null) {
      return const LocalSummaryCapability(
        available: false,
        message: '当前未安装端侧摘要模型，将使用规则摘要。',
      );
    }
    final check = _availabilityCheck;
    if (check == null) {
      return const LocalSummaryCapability(
        available: true,
        message: '端侧摘要模型已就绪。',
      );
    }
    try {
      final available = await check().timeout(timeout);
      return LocalSummaryCapability(
        available: available,
        message: available ? '端侧摘要模型已就绪。' : '当前设备不支持端侧摘要模型，将使用规则摘要。',
      );
    } catch (_) {
      return const LocalSummaryCapability(
        available: false,
        message: '无法确认端侧摘要能力，将使用规则摘要。',
      );
    }
  }

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final safeRequest = _redactedRequest(request);
    final runner = _runner;
    final capability = await this.capability();
    if (runner == null) {
      return _fallbackSummary(safeRequest, 'local small model unavailable');
    }
    if (!capability.available) {
      return _fallbackSummary(safeRequest, 'local small model not supported');
    }

    try {
      final summary = await runner(safeRequest).timeout(timeout);
      if (summary.displaySummary.trim().isEmpty ||
          summary.speechSummary.trim().isEmpty) {
        return _fallbackSummary(
          safeRequest,
          'local small model returned empty',
        );
      }
      return _redactedSummary(summary);
    } catch (error) {
      return _fallbackSummary(safeRequest, 'local small model failed: $error');
    }
  }

  OutputSummaryRequest _redactedRequest(OutputSummaryRequest request) {
    return OutputSummaryRequest(
      cleanedOutput: _redactor.redactInlineSecrets(request.cleanedOutput),
      status: request.status,
      taskTitle: _redactor.redactInlineSecrets(request.taskTitle),
      promptInputs: request.promptInputs
          .map(_redactor.redactInlineSecrets)
          .toList(growable: false),
      agentCommand: _redactor.redactInlineSecrets(request.agentCommand),
    );
  }

  Future<OutputSummary> _fallbackSummary(
    OutputSummaryRequest request,
    String reason,
  ) async {
    final summary = await _fallback.summarize(request);
    return summary.copyWith(fallbackReason: reason);
  }

  OutputSummary _redactedSummary(OutputSummary summary) {
    final display = _redactor.redactInlineSecrets(summary.displaySummary);
    final speech = DeviceVoiceService.cleanSpeechSummary(
      _redactor.redactInlineSecrets(summary.speechSummary),
    );
    return summary.copyWith(
      displaySummary: display,
      speechSummary: speech,
      importantLines: summary.importantLines
          .map(_redactor.redactInlineSecrets)
          .toList(growable: false),
    );
  }
}

class SelectableOutputSummaryProvider implements OutputSummaryProvider {
  SelectableOutputSummaryProvider({
    OutputSummaryProvider fallback = const RuleBasedOutputSummaryProvider(),
    LocalSmallModelSummaryProvider localModel =
        const LocalSmallModelSummaryProvider(),
  })  : _fallback = fallback,
        _localModel = localModel;

  final OutputSummaryProvider _fallback;
  final LocalSmallModelSummaryProvider _localModel;
  bool _preferLocalModel = false;

  bool get preferLocalModel => _preferLocalModel;

  void setPreferLocalModel(bool value) {
    _preferLocalModel = value;
  }

  Future<LocalSummaryCapability> localModelCapability() {
    return _localModel.capability();
  }

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) {
    if (_preferLocalModel) {
      return _localModel.summarize(request);
    }
    return _fallback.summarize(request);
  }
}

// TODO: Supply a LocalSmallModelSummaryRunner backed by an Android runtime
// such as MediaPipe LLM Inference or llama.cpp after model packaging and
// user-controlled model download/storage are designed.
