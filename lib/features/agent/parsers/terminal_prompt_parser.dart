import 'terminal_prompt.dart';

class TerminalPromptParser {
  const TerminalPromptParser();

  TerminalPrompt? parse(String output) {
    final lines = _plainLines(output);
    final questionIndex = lines.lastIndexWhere(_isQuestion);
    if (questionIndex < 0) {
      return null;
    }
    final options = _readOptions(lines.skip(questionIndex + 1));
    if (options.length < 2) {
      return null;
    }
    return TerminalPrompt(
      question: lines[questionIndex].trim(),
      command: _readCommand(lines, questionIndex),
      options: options,
    );
  }

  List<String> _plainLines(String output) {
    return output
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '\n')
        .split('\n');
  }

  bool _isQuestion(String line) {
    final lower = line.toLowerCase();
    return lower.contains('allow execution of') ||
        lower.contains('allow this command to run') ||
        lower.contains('allow command execution') ||
        lower.contains('approve this command') ||
        lower.contains('would you like to run');
  }

  List<TerminalPromptOption> _readOptions(Iterable<String> lines) {
    final options = <TerminalPromptOption>[];
    final pattern = RegExp(r'^\s*[>›❯]?\s*(\d+)\.\s+(.+?)\s*$');
    for (final line in lines) {
      final match = pattern.firstMatch(line);
      if (match == null) {
        if (options.isNotEmpty && line.trim().isNotEmpty) {
          break;
        }
        continue;
      }
      options.add(
        TerminalPromptOption(
          key: match.group(1)!,
          label: match.group(2)!.trim(),
        ),
      );
    }
    return options;
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
