enum HostAuthType {
  password,
  privateKey,
}

class HostConfig {
  const HostConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.projectPath,
    required this.tmuxSessionName,
    required this.agentCommand,
    required this.createdAt,
    required this.updatedAt,
  });

  factory HostConfig.mock() {
    final now = DateTime.now();
    return HostConfig(
      id: 'host-local-mac',
      name: 'Local Mac',
      host: '192.168.1.10',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.privateKey,
      projectPath: '/Users/ironion/workspace/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final HostAuthType authType;
  final String projectPath;
  final String tmuxSessionName;
  final String agentCommand;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get address => host;

  HostConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    HostAuthType? authType,
    String? projectPath,
    String? tmuxSessionName,
    String? agentCommand,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return HostConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      projectPath: projectPath ?? this.projectPath,
      tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
      agentCommand: agentCommand ?? this.agentCommand,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
