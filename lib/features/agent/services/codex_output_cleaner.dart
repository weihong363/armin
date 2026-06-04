class CodexOutputCleaner {
  const CodexOutputCleaner();

  String clean(String output) {
    final withoutAnsi = output
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '\n');
    final lines = withoutAnsi
        .split('\n')
        .map(_cleanLine)
        .where((line) => line.isNotEmpty && !_isNoiseLine(line))
        .toList();
    return _squashEmptyLines(lines).join('\n').trim();
  }

  String semanticHashInput(String output) {
    return clean(output)
        .replaceAll(RegExp(r'\b\d+(?:\.\d+)?s\b'), '')
        .replaceAll(RegExp(r'\b\d+% context left\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanLine(String line) {
    if (RegExp(r"you['’]ve hit your usage limit", caseSensitive: false)
        .hasMatch(line)) {
      return '额度已用完，请稍后重试。';
    }
    final preserveTableLine = _looksLikeDelimitedTableLine(line);
    return line
        .replaceFirst(
            preserveTableLine ? RegExp(r'(?!)') : RegExp(r'^[│|]\s*'), '')
        .replaceFirst(RegExp(r'^[›]\s*'), '')
        .replaceFirst(RegExp(r'^[✨⚠]\s*'), '')
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
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
        .trim();
  }

  bool _looksLikeDelimitedTableLine(String line) {
    final trimmed = line.trimLeft();
    if (!(trimmed.startsWith('│') || trimmed.startsWith('|'))) {
      return false;
    }
    final delimiter = trimmed.startsWith('│') ? '│' : '|';
    return delimiter.allMatches(trimmed).length >= 2;
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    return line == '|' ||
        _isTerminalGraphicLine(line) ||
        line.startsWith('┌') ||
        line.startsWith('└') ||
        line.startsWith('┐') ||
        line.startsWith('┘') ||
        line.startsWith('─') ||
        line.startsWith('_') ||
        line.startsWith('━') ||
        lower.contains('openai codex') ||
        lower.contains('qoder cli') ||
        lower.startsWith('model:') ||
        lower.startsWith('directory:') ||
        lower.startsWith('gpt-') ||
        lower.startsWith('tip:') ||
        lower.startsWith('use /skills ') ||
        lower.startsWith('armin context governance:') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('turn ') ||
        lower.startsWith('结果为：turn ') ||
        lower.startsWith('result: turn ') ||
        _isGovernanceRule(lower) ||
        lower.startsWith('update available!') ||
        lower.startsWith('release notes:') ||
        lower.startsWith('press enter to continue') ||
        lower.startsWith('run npm install') ||
        lower.startsWith('see full release notes') ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.contains('signed in browser login') ||
        lower.contains('type your message or @path/to/file') ||
        lower.contains('auto model') ||
        lower.contains('shift+tab to auto-accept edits') ||
        lower.contains('agents.md file') ||
        lower.contains(' to view transcript') ||
        lower.contains('npm install -g @openai/codex') ||
        lower.contains('github.com/openai/codex/releases') ||
        lower.contains('chatgpt.com/codex?app-landing-page=true') ||
        lower.startsWith('skipped loading') ||
        lower.startsWith('/users/') ||
        lower.contains('invalid skill.md') ||
        lower.contains('invalid yaml') ||
        lower.contains('mapping values are not allowed in this context') ||
        lower.startsWith('are not allowed in this context') ||
        lower == 'find and fix a bug in @filename' ||
        lower == 'implement {feature}' ||
        lower == 'explain this codebase';
  }

  bool _isTerminalGraphicLine(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    return compact.length >= 2 &&
        RegExp(
          r'^[█▓▒░▀▄▌▐▖▗▘▝▚▞▟▙▛▜▔▁▂▃▄▅▆▇╭╮╰╯─│┌┐└┘┬┴├┤┼━┃╋]+$',
        ).hasMatch(compact);
  }

  bool _isGovernanceRule(String lower) {
    return lower == 'only inspect files directly related to the task.' ||
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
        lower == '- keep command output short.';
  }

  List<String> _squashEmptyLines(List<String> lines) {
    final result = <String>[];
    var lastWasEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && lastWasEmpty) {
        continue;
      }
      result.add(line);
      lastWasEmpty = isEmpty;
    }
    return result;
  }
}
