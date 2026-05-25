import '../../../core/models/task_status.dart';
import '../../agent/services/codex_output_cleaner.dart';
import '../../voice/services/device_voice_service.dart';

class OutputSummaryRequest {
  const OutputSummaryRequest({
    required this.cleanedOutput,
    required this.status,
    this.taskTitle = '',
    this.agentCommand = '',
  });

  final String cleanedOutput;
  final TaskStatus status;
  final String taskTitle;
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
    this.maxDisplayLines = 4,
  }) : _cleaner = cleaner;

  final CodexOutputCleaner _cleaner;
  final int maxDisplayLines;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final cleaned = _cleaner.clean(request.cleanedOutput);
    final importantLines = _importantLines(cleaned, request);
    final display = importantLines.isEmpty
        ? _fallbackDisplay(cleaned)
        : importantLines.take(maxDisplayLines).join('\n');
    final speech = DeviceVoiceService.cleanSpeechSummary(display);
    return OutputSummary(
      displaySummary: display,
      speechSummary: speech,
      importantLines: importantLines,
    );
  }

  List<String> _importantLines(String cleaned, OutputSummaryRequest request) {
    final taskWords = _taskWords(request.taskTitle);
    final lines = cleaned
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where(
            (line) => !_looksLikePromptEcho(line, request.taskTitle, taskWords))
        .where((line) => !_looksLikeLowValueLine(line))
        .toList(growable: false);

    final directResults = lines.where(_looksLikeResultLine).toList();
    return directResults.isEmpty
        ? lines.take(maxDisplayLines).toList()
        : directResults;
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
    String taskTitle,
    Set<String> taskWords,
  ) {
    final compactLine = line.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final compactTitle = taskTitle.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (compactTitle.length >= 4 &&
        (compactLine == compactTitle || compactTitle.contains(compactLine))) {
      return true;
    }
    if (taskWords.isEmpty) {
      return false;
    }
    final lower = line.toLowerCase();
    final hits = taskWords.where(lower.contains).length;
    return hits >= 3 && line.length <= 120;
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
        lower.startsWith('风险信息');
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
        lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('success');
  }

  String _fallbackDisplay(String cleaned) {
    final trimmed = cleaned.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed
        .split(RegExp(r'\n{2,}|\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(maxDisplayLines)
        .join('\n');
  }
}

typedef LocalSmallModelSummaryRunner = Future<OutputSummary> Function(
  OutputSummaryRequest request,
);

class LocalSmallModelSummaryProvider implements OutputSummaryProvider {
  const LocalSmallModelSummaryProvider({
    LocalSmallModelSummaryRunner? runner,
    OutputSummaryProvider fallback = const RuleBasedOutputSummaryProvider(),
    this.timeout = const Duration(seconds: 3),
  })  : _runner = runner,
        _fallback = fallback;

  final LocalSmallModelSummaryRunner? _runner;
  final OutputSummaryProvider _fallback;
  final Duration timeout;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final runner = _runner;
    if (runner == null) {
      return _fallbackSummary(request, 'local small model unavailable');
    }

    try {
      final summary = await runner(request).timeout(timeout);
      if (summary.displaySummary.trim().isEmpty ||
          summary.speechSummary.trim().isEmpty) {
        return _fallbackSummary(request, 'local small model returned empty');
      }
      return summary;
    } catch (error) {
      return _fallbackSummary(request, 'local small model failed: $error');
    }
  }

  Future<OutputSummary> _fallbackSummary(
    OutputSummaryRequest request,
    String reason,
  ) async {
    final summary = await _fallback.summarize(request);
    return summary.copyWith(fallbackReason: reason);
  }
}

// TODO: Wire LocalSmallModelSummaryProvider to an Android runtime such as
// MediaPipe LLM Inference or llama.cpp after model packaging, device capability
// checks, and user-controlled download/storage are designed.
