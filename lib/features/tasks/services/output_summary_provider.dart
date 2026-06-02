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
    final withoutPromptBlocks = _removeTerminalPromptBlocks(
      request.cleanedOutput,
    );
    final cleaned =
        _redactor.redactInlineSecrets(_cleaner.clean(withoutPromptBlocks));
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
    final withoutPromptBlocks = _removeTerminalPromptBlocks(cleaned);
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final lines = _semanticLines(withoutPromptBlocks)
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

  String _removeTerminalPromptBlocks(String cleaned) {
    final lines = cleaned
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '\n')
        .split('\n');
    final kept = <String>[];
    var skipping = false;
    var sawOption = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (!skipping && _isTerminalPromptStart(trimmed)) {
        _removeTerminalPromptPreface(kept);
        skipping = true;
        sawOption = false;
        continue;
      }
      if (!skipping) {
        kept.add(line);
        continue;
      }
      if (trimmed.isEmpty ||
          _isTerminalPromptStart(trimmed) ||
          _isTerminalPromptSeparator(trimmed)) {
        continue;
      }
      if (_isTerminalPromptFooter(trimmed)) {
        skipping = false;
        sawOption = false;
        continue;
      }
      if (_isTerminalPromptOption(trimmed)) {
        sawOption = true;
        continue;
      }
      if (!sawOption || line.startsWith(RegExp(r'\s'))) {
        continue;
      }
      skipping = false;
      kept.add(line);
    }
    return kept.join('\n');
  }

  void _removeTerminalPromptPreface(List<String> lines) {
    while (lines.isNotEmpty) {
      final trimmed = lines.last.trim();
      if (trimmed.isEmpty ||
          _isTerminalPromptOption(trimmed) ||
          _isTerminalPromptSeparator(trimmed) ||
          _looksLikeTerminalPromptPreface(trimmed)) {
        lines.removeLast();
        continue;
      }
      break;
    }
  }

  bool _looksLikeTerminalPromptPreface(String line) {
    return line.startsWith('▪') ||
        line.startsWith('•') ||
        line.endsWith('?') ||
        line.endsWith('？') ||
        line.contains('你是指以下哪种') ||
        line.contains('请选择') ||
        line.contains('请具体说明');
  }

  bool _isTerminalPromptStart(String line) {
    final lower = line.toLowerCase();
    return lower == 'asking user' ||
        lower.startsWith('allow this command to run') ||
        lower.startsWith('allow execution of') ||
        lower.startsWith('allow command execution') ||
        lower.startsWith('would you like to run') ||
        lower.startsWith('approve this command');
  }

  bool _isTerminalPromptOption(String line) {
    return RegExp(r'^[>›❯]?\s*\d{1,2}[.)]\s+.+').hasMatch(line);
  }

  bool _isTerminalPromptFooter(String line) {
    final lower = line.toLowerCase();
    return lower.contains('navigate') ||
        lower.contains('enter select') ||
        lower.contains('esc back') ||
        lower.contains('ctrl+o');
  }

  bool _isTerminalPromptSeparator(String line) {
    return RegExp(r'^[─━_\-=]{3,}$').hasMatch(line);
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
        .replaceAll(
          RegExp(r'^completion:\s*tls handshake eof\b.*', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'\bType your message or @path/to/file\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAuto Model\b.*', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\bShift\+Tab to Auto-accept Edits\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAGENTS\.md file\b.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bThinking\b[.…]*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[▪■●•]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    value = _dropToolTracePrefix(value);
    value = _stripPromptNoisePrefix(value);
    return _normalizePetDescription(value);
  }

  String _stripPromptNoisePrefix(String line) {
    var value = line.trimLeft();
    var previous = '';
    while (value.isNotEmpty && value != previous) {
      previous = value;
      for (final pattern in _promptNoisePrefixPatterns) {
        final match = pattern.firstMatch(value);
        if (match != null) {
          value = value.substring(match.end).trimLeft();
          break;
        }
      }
    }
    return value.trim();
  }

  static final List<RegExp> _promptNoisePrefixPatterns = [
    RegExp(
      r'^(?:最小改动|不要提交\s*git|不要提交git|不要提交\s+Git|高风险操作先确认)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:user constraints|## user constraints|## user task|## context chunk|## secret placeholders)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:do not analyze unrelated architecture\.?|run only targeted tests\.?|keep command output short\.?)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:turn \d+|result: turn \d+|结果为：turn \d+)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
  ];

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
        lower.startsWith('```') ||
        lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('final ') ||
        lower.startsWith('const ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        lower.startsWith('flutter ') ||
        lower.startsWith('dart ') ||
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
        lower.startsWith('```') ||
        lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('final ') ||
        lower.startsWith('const ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        lower.startsWith('flutter ') ||
        lower.startsWith('dart ') ||
        lower.startsWith('任务：') ||
        lower.startsWith('任务:') ||
        lower.startsWith('补充上下文') ||
        lower.startsWith('执行约束') ||
        lower.startsWith('风险信息') ||
        lower.startsWith('user constraints') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('completion: tls handshake eof') ||
        lower.startsWith('tool:') ||
        lower.startsWith('command:') ||
        lower.startsWith('run ') ||
        lower.startsWith('bash(') ||
        lower.startsWith('python -m ') ||
        lower.startsWith('cd ') ||
        lower.startsWith('allow this command to run') ||
        lower.startsWith('allow execution of') ||
        lower.startsWith('would you like to run') ||
        RegExp(r'^\d+[.)]\s+(?:allow once|always allow|reject and type something|no)\b')
            .hasMatch(lower) ||
        RegExp(r'^\d+[.)]\s+(?:允许|始终允许|拒绝|不允许|否)\b').hasMatch(lower) ||
        line.startsWith('测试目标') ||
        line.startsWith('执行 ') ||
        lower.startsWith('turn ') ||
        lower.startsWith('结果为：turn ') ||
        lower.startsWith('result: turn ') ||
        (lower.contains('最小改动') &&
            lower.contains('不要提交') &&
            lower.contains('高风险操作先确认')) ||
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
        lower.startsWith('let me ') ||
        lower.startsWith('i will ') ||
        lower.startsWith("i'll ") ||
        lower.startsWith('i am going to ') ||
        lower.startsWith('no direct ') ||
        lower.startsWith('q:') ||
        lower.startsWith('question:') ||
        line.startsWith('过程记录') ||
        line.startsWith('继续从') ||
        line.startsWith('我先看一下') ||
        line.startsWith('我先检查') ||
        line.startsWith('我会先') ||
        line.startsWith('我将先') ||
        line.startsWith('让我先') ||
        line.startsWith('让我检查') ||
        line.startsWith('项目中没有找到') ||
        line.startsWith('没有找到专门的') ||
        line.startsWith('接下来') ||
        line.startsWith('下面我') ||
        line.startsWith('先看看') ||
        line.startsWith('先检查');
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
