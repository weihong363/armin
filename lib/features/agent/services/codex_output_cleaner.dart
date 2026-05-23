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
    return line
        .replaceFirst(RegExp(r'^[│|]\s*'), '')
        .replaceFirst(RegExp(r'^[›]\s*'), '')
        .replaceFirst(RegExp(r'^[✨⚠]\s*'), '')
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .trim();
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    return line == '|' ||
        line.startsWith('┌') ||
        line.startsWith('└') ||
        line.startsWith('┐') ||
        line.startsWith('┘') ||
        line.startsWith('│') ||
        line.startsWith('─') ||
        line.startsWith('_') ||
        line.startsWith('━') ||
        lower.contains('openai codex') ||
        lower.startsWith('model:') ||
        lower.startsWith('directory:') ||
        lower.startsWith('gpt-') ||
        lower.startsWith('tip:') ||
        lower.startsWith('use /skills ') ||
        lower.startsWith('update available!') ||
        lower.startsWith('release notes:') ||
        lower.startsWith('press enter to continue') ||
        lower.startsWith('run npm install') ||
        lower.startsWith('see full release notes') ||
        lower == 'explored' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.contains(' to view transcript') ||
        lower.contains('npm install -g @openai/codex') ||
        lower.contains('github.com/openai/codex/releases') ||
        lower.startsWith('skipped loading') ||
        lower.startsWith('warning') ||
        lower.contains('invalid skill.md') ||
        lower.contains('invalid yaml') ||
        RegExp(r'^\d+\.\s').hasMatch(lower);
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
