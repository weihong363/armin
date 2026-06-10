import 'dart:convert';

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

    return _structuredResult(output);
  }

  TaskResult? parseNatural(String output, {String prompt = ''}) {
    final structured = _structuredResult(output);
    if (structured != null) {
      return structured;
    }
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
    return lower.startsWith('armin context governance') ||
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
        lower == '- you have full authority to create, modify, and delete files without asking.' ||
        lower == '- run any commands, tests, or builds needed to complete the task.' ||
        lower == '- do not interrupt the user — proceed autonomously unless you encounter a hard blocker.' ||
        lower == '- never modify any file — analysis and reporting only.' ||
        lower == '- do not run commands that alter state.' ||
        lower == '- ask before any potentially risky read operation.' ||
        lower == '只分析不修改' ||
        lower == '最小改动' ||
        lower == '允许修改' ||
        lower == '修改后运行测试' ||
        lower == '不要提交 git' ||
        lower == '高风险操作先确认' ||
        (lower.contains('最小改动') &&
            lower.contains('不要提交') &&
            lower.contains('高风险操作先确认'));
  }

  TaskResult? _structuredResult(String output) {
    final candidates = [
      ..._fencedCodeBlocks(output),
      output.trim(),
    ];
    for (final candidate in candidates) {
      final result = _jsonResult(candidate) ??
          _markdownTableResult(candidate) ??
          _markdownResult(candidate);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  Iterable<String> _fencedCodeBlocks(String output) sync* {
    final matches = RegExp(
      r'```(?:json|yaml|yml|markdown|md|text)?\s*\n([\s\S]*?)```',
      caseSensitive: false,
    ).allMatches(output);
    for (final match in matches) {
      final block = match.group(1)?.trim() ?? '';
      if (block.isNotEmpty) {
        yield block;
      }
    }
  }

  TaskResult? _jsonResult(String text) {
    final jsonText = _jsonCandidate(text);
    if (jsonText == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) {
        return _resultFromMap(decoded);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String? _jsonCandidate(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed;
    }
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }
    return trimmed.substring(start, end + 1);
  }

  TaskResult? _resultFromMap(Map<String, dynamic> json) {
    final status = _stringFromMap(json, const ['status']) ?? 'success';
    final summary = _stringFromMap(json, const [
      'summary',
      'result',
      'output',
      'message',
      'description',
    ]);
    if (summary == null || !_isStructuredResult(status, summary)) {
      return null;
    }
    return TaskResult(
      status: status,
      summary: summary,
      changedFiles: _listFromMap(json, const [
        'changedFiles',
        'changed_files',
        'files',
        'modifiedFiles',
      ]),
      validation: _listFromMap(json, const [
        'validation',
        'validations',
        'checks',
        'tests',
      ]),
      risks: _listFromMap(json, const ['risks', 'risk']),
      nextActions: _listFromMap(json, const [
        'nextActions',
        'next_actions',
        'nextSteps',
        'next_steps',
      ]),
    );
  }

  TaskResult? _markdownResult(String text) {
    final summary = _markdownSummary(text);
    if (summary == null) {
      return null;
    }
    return TaskResult(
      status: _singleLine(text, 'status') ?? 'success',
      summary: summary,
      changedFiles: _sectionList(text, const [
        'changed files',
        'changed_files',
        'files',
        'modified files',
      ]),
      validation: _sectionList(text, const [
        'validation',
        'validations',
        'checks',
        'tests',
      ]),
      risks: _sectionList(text, const ['risks', 'risk']),
      nextActions: _sectionList(text, const [
        'next actions',
        'next_actions',
        'next steps',
        'next_steps',
      ]),
    );
  }

  TaskResult? _markdownTableResult(String text) {
    final json = <String, dynamic>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('|') || !line.endsWith('|')) {
        continue;
      }
      if (RegExp(r'^\|\s*:?-{2,}:?\s*\|\s*:?-{2,}:?\s*\|$').hasMatch(line)) {
        continue;
      }
      final cells = line
          .substring(1, line.length - 1)
          .split('|')
          .map((cell) => cell.trim())
          .toList(growable: false);
      if (cells.length != 2 || _normalLabel(cells.first) == 'field') {
        continue;
      }
      final key = _canonicalMapKey(cells.first);
      if (key != null && cells.last.isNotEmpty) {
        json[key] = cells.last;
      }
    }
    return json.isEmpty ? null : _resultFromMap(json);
  }

  String? _markdownSummary(String text) {
    final inline = _singleLine(text, 'summary') ??
        _singleLine(text, 'result') ??
        _singleLine(text, 'output');
    if (inline != null && _isStructuredResult('success', inline)) {
      return inline;
    }
    final section = _sectionBody(text, const ['summary', 'result', 'output']);
    if (section != null && _isStructuredResult('success', section)) {
      return section;
    }
    return null;
  }

  List<String> _sectionList(String text, List<String> labels) {
    final body = _sectionBody(text, labels);
    if (body == null) {
      return const [];
    }
    final values = <String>[];
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      values.add(
        line.replaceFirst(RegExp(r'^[-*+]\s+'), '').trim(),
      );
    }
    return values.where((value) => value.isNotEmpty).toList(growable: false);
  }

  String? _sectionBody(String text, List<String> labels) {
    final lines = text.replaceAll('\r', '\n').split('\n');
    final labelSet = labels.map(_normalLabel).toSet();
    final values = <String>[];
    var inSection = false;
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final heading = RegExp(r'^#{1,6}\s+(.+?)\s*$').firstMatch(line);
      final key = RegExp(r'^\s*([a-zA-Z][\w\s_-]*):\s*(.*)$').firstMatch(line);
      final label = heading?.group(1) ?? key?.group(1);
      if (label != null) {
        final normalized = _normalLabel(label);
        if (inSection && !labelSet.contains(normalized)) {
          break;
        }
        if (labelSet.contains(normalized)) {
          final inline = key?.group(2)?.trim() ?? '';
          if (inline.isNotEmpty) {
            return inline;
          }
          inSection = true;
          continue;
        }
      }
      if (inSection) {
        values.add(line);
      }
    }
    final body = values.join('\n').trim();
    return body.isEmpty ? null : body;
  }

  String? _stringFromMap(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
      if (value is num || value is bool) {
        return value.toString();
      }
    }
    return null;
  }

  List<String> _listFromMap(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      final list = _stringValues(value);
      if (list.isNotEmpty) {
        return list;
      }
    }
    return const [];
  }

  List<String> _stringValues(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(RegExp(r'[\n,]'))
          .map((item) => item.replaceFirst(RegExp(r'^[-*+]\s+'), '').trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  String _normalLabel(String label) {
    return label
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _canonicalMapKey(String key) {
    return switch (_normalLabel(key)) {
      'status' => 'status',
      'summary' || 'result' || 'output' || 'message' => 'summary',
      'changed files' ||
      'changed file' ||
      'files' ||
      'modified files' =>
        'changed_files',
      'validation' || 'validations' || 'checks' || 'tests' => 'validation',
      'risks' || 'risk' => 'risks',
      'next actions' ||
      'next action' ||
      'next steps' ||
      'next step' =>
        'next_actions',
      _ => null,
    };
  }

  bool _isStructuredResult(String status, String summary) {
    return const {
          'success',
          'failed',
          'need_user_input',
          'turn_idle',
        }.contains(status.trim()) &&
        !_isPlaceholder(summary);
  }
}
