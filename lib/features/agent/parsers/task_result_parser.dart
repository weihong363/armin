import 'task_result.dart';

class TaskResultParser {
  TaskResult? parse(String output) {
    final blocks = RegExp(
      r'TASK\s*_\s*RESULT\s*_\s*START([\s\S]*?)TASK\s*_\s*RESULT\s*_\s*END',
      caseSensitive: false,
    ).allMatches(output).toList().reversed;

    for (final match in blocks) {
      final block = match.group(1)?.trim() ?? '';
      final status = _singleLine(block, 'status') ?? 'failed';
      final summary = _singleLine(block, 'summary') ?? '';
      if (!_isRealResult(status: status, summary: summary)) {
        continue;
      }

      return TaskResult(
        status: status,
        summary: summary,
        changedFiles: _list(block, 'changed_files'),
        validation: _list(block, 'validation'),
        risks: _list(block, 'risks'),
        nextActions: _list(block, 'next_actions'),
      );
    }

    return null;
  }

  TaskResult? parseNatural(String output, {String prompt = ''}) {
    final summary = _naturalSummary(output, prompt: prompt);
    if (summary == null) {
      return null;
    }
    return TaskResult(
      status: 'success',
      summary: summary,
      changedFiles: const [],
      validation: const [],
      risks: const [],
      nextActions: const [],
    );
  }

  String? _singleLine(String block, String key) {
    final match = RegExp(
      '^${_keyPattern(key)}:\\s*(.*)\$',
      multiLine: true,
    ).firstMatch(block);
    return match?.group(1)?.trim();
  }

  List<String> _list(String block, String key) {
    final lines = block.split('\n');
    final values = <String>[];
    var inSection = false;
    final keyPattern = RegExp('^${_keyPattern(key)}:\\s*(.*)\$');

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final keyMatch = keyPattern.firstMatch(line);
      if (keyMatch != null) {
        final inlineValue = keyMatch.group(1)?.trim() ?? '';
        if (_isInlineListValue(inlineValue)) {
          values.add(inlineValue);
          return values;
        }
        inSection = true;
        continue;
      }
      if (inSection && RegExp(r'^[a-z]+(?:\s*_\s*[a-z]+)*:').hasMatch(line)) {
        break;
      }
      if (inSection && line.trimLeft().startsWith('-')) {
        values.add(line.trimLeft().substring(1).trim());
      }
    }

    return values;
  }

  String _keyPattern(String key) {
    return key.split('_').map(RegExp.escape).join(r'\s*_\s*');
  }

  bool _isInlineListValue(String value) {
    if (value.isEmpty || value == '[]' || value == '[ ]') {
      return false;
    }
    return !value.startsWith('[');
  }

  bool _isRealResult({
    required String status,
    required String summary,
  }) {
    return const {'success', 'failed', 'need_user_input'}
            .contains(status.trim()) &&
        !_isPlaceholder(summary);
  }

  bool _isPlaceholder(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ||
        trimmed == '...' ||
        trimmed == '<...>' ||
        trimmed.contains('|');
  }

  String? _naturalSummary(String output, {required String prompt}) {
    final promptLines = _plainLines(prompt)
        .map(_cleanNaturalLine)
        .where((line) => line.isNotEmpty)
        .toSet();
    final cleanedLines = _plainLines(output).map(_cleanNaturalLine).toList();
    final startIndex = _lastPromptIndex(cleanedLines, promptLines);
    final candidateLines =
        startIndex == null ? cleanedLines : cleanedLines.skip(startIndex);
    final useful = candidateLines
        .where((line) =>
            line.isNotEmpty &&
            !_isNoiseLine(line) &&
            !promptLines.contains(line))
        .toList();
    if (useful.isEmpty) {
      return null;
    }
    return useful.join('\n').trim();
  }

  int? _lastPromptIndex(List<String> cleanedLines, Set<String> promptLines) {
    if (promptLines.isEmpty) {
      return null;
    }
    for (var index = cleanedLines.length - 1; index >= 0; index -= 1) {
      if (promptLines.contains(cleanedLines[index])) {
        return index + 1;
      }
    }
    return null;
  }

  List<String> _plainLines(String output) {
    final withoutAnsi =
        output.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    return withoutAnsi
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _cleanNaturalLine(String line) {
    return line
        .replaceFirst(RegExp(r'^[│|]\s*'), '')
        .replaceFirst(RegExp(r'^[›]\s*'), '')
        .replaceFirst(RegExp(r'^[✨⚠]\s*'), '')
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .trim();
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    return line.startsWith('>') ||
        lower.startsWith('turn ') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        _isGovernanceEcho(lower) ||
        line.startsWith('┌') ||
        line.startsWith('└') ||
        line.startsWith('┐') ||
        line.startsWith('┘') ||
        line.startsWith('│') ||
        line.startsWith('─') ||
        line.startsWith('_') ||
        line.startsWith('━') ||
        line == '|' ||
        line == '╭' ||
        line == '╰' ||
        lower.contains('openai codex') ||
        lower.startsWith('model:') ||
        lower.startsWith('directory:') ||
        lower.startsWith('gpt-') ||
        lower.startsWith('tip:') ||
        lower.startsWith('use /skills ') ||
        lower == 'explored' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.contains(' to view transcript') ||
        lower.contains('update available!') ||
        lower.startsWith('release notes:') ||
        lower.startsWith('press enter to continue') ||
        lower.startsWith('run npm install') ||
        lower.startsWith('see full release notes') ||
        lower.startsWith('armin timed out waiting for codex tui') ||
        lower.contains('npm install -g @openai/codex') ||
        lower.contains('github.com/openai/codex/releases') ||
        RegExp(r'^\d+\.\s').hasMatch(lower) ||
        lower.startsWith('skipped loading') ||
        lower.startsWith('warning') ||
        lower.contains('invalid skill.md') ||
        lower.contains('invalid yaml') ||
        lower.contains('context left') ||
        lower.contains('working') ||
        lower == 'implement {feature}';
  }

  bool _isGovernanceEcho(String lower) {
    return lower == 'armin context governance:' ||
        lower == 'only inspect files directly related to the task.' ||
        lower == 'never scan the entire repository.' ||
        lower == 'avoid reading docs/ and readme unless necessary.' ||
        lower == 'keep edits minimal and focused.' ||
        lower == 'do not analyze unrelated architecture.' ||
        lower == 'run only targeted tests.' ||
        lower == 'keep command output short.' ||
        lower == '- only inspect files directly related to the task.' ||
        lower == '- never scan the entire repository.' ||
        lower == '- avoid reading docs/ and readme unless necessary.' ||
        lower == '- keep edits minimal and focused.' ||
        lower == '- do not analyze unrelated architecture.' ||
        lower == '- run only targeted tests.' ||
        lower == '- keep command output short.' ||
        (lower.contains('最小改动') &&
            lower.contains('不要提交') &&
            lower.contains('高风险操作先确认'));
  }
}
