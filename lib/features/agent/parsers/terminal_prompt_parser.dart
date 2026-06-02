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
    if (questionIndex < 0) {
      return null;
    }
    final optionIndex = _firstOptionIndex(lines, questionIndex + 1);
    if (optionIndex == null) {
      return null;
    }
    return _PromptBlock(
      questionIndex: questionIndex,
      optionIndex: optionIndex,
    );
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
    final lower = line.toLowerCase();
    return lower.contains('allow execution of') ||
        lower.contains('allow this command to run') ||
        lower.contains('allow command execution') ||
        lower.contains('approve this command') ||
        lower.contains('would you like to run');
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
}

class _PromptBlock {
  const _PromptBlock({
    required this.questionIndex,
    required this.optionIndex,
  });

  final int questionIndex;
  final int optionIndex;
}
