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

class AgentInstructionDiscoveryKey {
  const AgentInstructionDiscoveryKey({
    required this.hostId,
    required this.projectPathId,
    required this.normalizedProjectPath,
  });

  final String hostId;
  final String projectPathId;
  final String normalizedProjectPath;

  String get value => '$hostId::$projectPathId::$normalizedProjectPath';
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
      return '未检测到 AGENTS.md。Armin 将使用内置轻量上下文治理规则。';
    }
    return '检测到 AGENTS.md。Agent 可能会读取仓库内的专用规则。';
  }
}
