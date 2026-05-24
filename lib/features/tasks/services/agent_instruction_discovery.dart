class AgentInstructionDiscovery {
  const AgentInstructionDiscovery({this.maxDepth = 3});

  final int maxDepth;

  String buildFindCommand() {
    final depth = maxDepth < 1 ? 1 : maxDepth;
    return 'find . -maxdepth $depth '
        r'\( -name AGENTS.md -o -name AGENTS.override.md \) -print';
  }

  AgentInstructionDiscoveryResult parse(String output) {
    final paths = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return AgentInstructionDiscoveryResult(paths: paths);
  }
}

class AgentInstructionDiscoveryResult {
  const AgentInstructionDiscoveryResult({
    required this.paths,
    this.warning = '',
  });

  final List<String> paths;
  final String warning;

  bool get detected => paths.isNotEmpty;

  String get uiMessage {
    if (warning.trim().isNotEmpty) {
      return warning;
    }
    if (paths.isEmpty) {
      return 'No AGENTS.md detected. Armin will use lightweight built-in '
          'prompt governance.';
    }
    return 'AGENTS.md detected. Codex may follow repository-specific '
        'optimization rules.';
  }
}
