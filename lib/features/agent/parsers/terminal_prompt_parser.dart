import 'terminal_prompt.dart';

class TerminalPromptParser {
  const TerminalPromptParser();

  TerminalPrompt? parse(String output) {
    final lines = _plainLines(output);
    final promptBlock = _findPromptBlock(lines);
    if (promptBlock == null) {
      return null;
    }
    final options = _readOptions(lines.skip(promptBlock.optionIndex));
    if (options.length < 2) {
      return null;
    }
    return TerminalPrompt(
      question: lines[promptBlock.questionIndex].trim(),
      command: _readCommand(lines, promptBlock.questionIndex),
      options: options,
    );
  }

  List<String> _plainLines(String output) {
    return output
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '\n')
        .split('\n');
  }

  _PromptBlock? _findPromptBlock(List<String> lines) {
    final askingIndex = lines.lastIndexWhere(_isAskingUserMarker);
    if (askingIndex >= 0) {
      final optionIndex = _firstOptionIndex(lines, askingIndex + 1);
      if (optionIndex != null) {
        final questionIndex = _questionBeforeOptions(
          lines,
          start: askingIndex + 1,
          optionIndex: optionIndex,
        );
        if (questionIndex != null) {
          return _PromptBlock(
            questionIndex: questionIndex,
            optionIndex: optionIndex,
          );
        }
      }
    }

    final questionIndex = lines.lastIndexWhere(_isKnownCommandQuestion);
    if (questionIndex >= 0) {
      final optionIndex = _firstOptionIndex(lines, questionIndex + 1);
      if (optionIndex != null) {
        return _PromptBlock(
          questionIndex: questionIndex,
          optionIndex: optionIndex,
        );
      }
    }

    return _findStructuralPromptBlock(lines);
  }

  int? _firstOptionIndex(List<String> lines, int start) {
    for (var index = start; index < lines.length; index++) {
      if (_optionMatch(lines[index]) != null) {
        return index;
      }
    }
    return null;
  }

  int? _questionBeforeOptions(
    List<String> lines, {
    required int start,
    required int optionIndex,
  }) {
    for (var index = optionIndex - 1; index >= start; index--) {
      final line = lines[index].trim();
      if (line.isEmpty || _isSeparator(line)) {
        continue;
      }
      if (_looksLikeQuestion(line)) {
        return index;
      }
    }
    for (var index = optionIndex - 1; index >= start; index--) {
      final line = lines[index].trim();
      if (line.isNotEmpty && !_isSeparator(line)) {
        return index;
      }
    }
    return null;
  }

  bool _isAskingUserMarker(String line) {
    return line.trim().toLowerCase() == 'asking user';
  }

  bool _isKnownCommandQuestion(String line) {
    final lower = line.trim().toLowerCase();
    // Structural: a line ending with ? that references actions the agent
    // wants to perform — intentionally NOT matching CLI-specific keywords.
    if (!lower.endsWith('?') && !lower.endsWith('？')) {
      return false;
    }
    return lower.contains('execut') ||
        lower.contains('allow') ||
        lower.contains('apply') ||
        lower.contains('approv') ||
        lower.contains('proceed') ||
        lower.contains('运行') ||
        lower.contains('允许') ||
        lower.contains('继续');
  }

  bool _looksLikeQuestion(String line) {
    return _isKnownCommandQuestion(line) ||
        line.trim().endsWith('?') ||
        line.trim().endsWith('？');
  }

  List<TerminalPromptOption> _readOptions(Iterable<String> lines) {
    final options = <TerminalPromptOption>[];
    for (final line in lines) {
      final match = _optionMatch(line);
      if (match == null) {
        final trimmed = line.trim();
        if (options.isEmpty || trimmed.isEmpty || _isSeparator(trimmed)) {
          continue;
        }
        if (_isPromptFooter(trimmed)) {
          break;
        }
        if (line.startsWith(RegExp(r'\s')) && !_looksLikeQuestion(trimmed)) {
          continue;
        }
        break;
      }
      final label = match.group(2)!.trim();
      if (_isPromptFooter(label)) {
        break;
      }
      options.add(
        TerminalPromptOption(
          key: match.group(1)!,
          label: label,
        ),
      );
    }
    return options;
  }

  RegExpMatch? _optionMatch(String line) {
    return RegExp(r'^\s*[>›❯]?\s*(\d{1,2})[.)]\s+(.+?)\s*$').firstMatch(line);
  }

  bool _isPromptFooter(String line) {
    final lower = line.toLowerCase();
    return lower.contains('navigate') ||
        lower.contains('enter select') ||
        lower.contains('esc back') ||
        lower.contains('ctrl+o');
  }

  bool _isSeparator(String line) {
    return RegExp(r'^[─━_\-=]{3,}$').hasMatch(line.trim());
  }

  String _readCommand(List<String> lines, int questionIndex) {
    for (var index = questionIndex - 1; index >= 0; index--) {
      final match = RegExp(r'^\s*Command:\s*(.*)$', caseSensitive: false)
          .firstMatch(lines[index]);
      if (match == null) {
        continue;
      }
      final parts = <String>[
        match.group(1)!.trim(),
        for (final line
            in lines.skip(index + 1).take(questionIndex - index - 1))
          line.trim(),
      ].where((line) => line.isNotEmpty).toList(growable: false);
      return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final bracketed =
        RegExp(r'allow execution of \[(.+?)\]', caseSensitive: false)
            .firstMatch(lines[questionIndex]);
    return bracketed?.group(1)?.trim() ?? '';
  }

  /// Detects interactive CLI prompt blocks by structural features alone:
  /// a cluster of numbered option lines where at least one carries a
  /// cursor prefix (>, ❯, ►, ▸).  No CLI-specific keywords are required.
  _PromptBlock? _findStructuralPromptBlock(List<String> lines) {
    if (lines.length < 4) return null;

    // Scan from bottom up collecting numbered option lines.
    final optionIndices = <int>[];
    for (var i = lines.length - 1; i >= 0; i--) {
      if (_optionMatch(lines[i]) != null) {
        optionIndices.add(i);
      } else if (optionIndices.isNotEmpty) {
        final trimmed = lines[i].trim();
        if (trimmed.isEmpty || _isSeparator(trimmed)) {
          continue;
        }
        break;
      }
    }
    if (optionIndices.length < 2) return null;

    // Reverse to ascending line order.
    final sorted = optionIndices.reversed.toList(growable: false);

    // Options must start from 1.
    final firstMatch = _optionMatch(lines[sorted.first]);
    if (firstMatch == null || firstMatch.group(1) != '1') return null;

    // At least one option must carry a cursor prefix.
    final hasCursor = sorted.any((idx) {
      final line = lines[idx];
      return line.trimLeft().startsWith('>') ||
          line.trimLeft().startsWith('❯') ||
          line.trimLeft().startsWith('►') ||
          line.trimLeft().startsWith('▸');
    });
    if (!hasCursor) return null;

    // Maximum 20 options (interactive menus are short).
    if (sorted.length > 20) return null;

    // Find the question line: first non-blank, non-separator line above
    // the first option.
    final optionIndex = sorted.first;
    int? questionIndex;
    for (var i = optionIndex - 1; i >= 0; i--) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty || _isSeparator(trimmed)) continue;
      questionIndex = i;
      break;
    }
    if (questionIndex == null) return null;

    return _PromptBlock(
      questionIndex: questionIndex,
      optionIndex: optionIndex,
    );
  }
}

class _PromptBlock {
  const _PromptBlock({
    required this.questionIndex,
    required this.optionIndex,
  });

  final int questionIndex;
  final int optionIndex;
}
