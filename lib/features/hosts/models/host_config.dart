enum HostAuthType {
  password,
  privateKey,
}

enum ShellWrapper {
  none,
  shLogin,
  zshLogin,
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
    this.password = '',
    this.privateKeyPath = '',
    this.isDefault = false,
    this.tmuxCommand = 'tmux',
    this.pathPrepend = '',
    this.shellWrapper = ShellWrapper.none,
  });

  factory HostConfig.fromJson(Map<String, Object?> json) {
    return HostConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? json['address'] as String? ?? '',
      port: json['port'] as int? ?? 22,
      username: json['username'] as String? ?? '',
      authType: HostAuthType.values.firstWhere(
        (type) => type.name == json['authType'],
        orElse: () => HostAuthType.password,
      ),
      projectPath: json['projectPath'] as String? ?? '',
      tmuxSessionName: json['tmuxSessionName'] as String? ?? 'armin-codex',
      agentCommand: json['agentCommand'] as String? ?? 'codex',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      password: '', // Password is loaded from secure storage separately
      privateKeyPath: json['privateKeyPath'] as String? ?? '',
      isDefault: json['isDefault'] as bool? ?? false,
      tmuxCommand: json['tmuxCommand'] as String? ?? 'tmux',
      pathPrepend: json['pathPrepend'] as String? ?? '',
      shellWrapper: ShellWrapper.values.firstWhere(
        (wrapper) => wrapper.name == json['shellWrapper'],
        orElse: () => ShellWrapper.none,
      ),
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

  /// Password is stored securely in platform keystore via SecurePasswordStore.
  /// This field holds the decrypted password in memory after loading.
  final String password;
  final String privateKeyPath;
  final bool isDefault;
  final String tmuxCommand;
  final String pathPrepend;
  final ShellWrapper shellWrapper;

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
    String? password,
    String? privateKeyPath,
    bool? isDefault,
    String? tmuxCommand,
    String? pathPrepend,
    ShellWrapper? shellWrapper,
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
      password: password ?? this.password,
      privateKeyPath: privateKeyPath ?? this.privateKeyPath,
      isDefault: isDefault ?? this.isDefault,
      tmuxCommand: tmuxCommand ?? this.tmuxCommand,
      pathPrepend: pathPrepend ?? this.pathPrepend,
      shellWrapper: shellWrapper ?? this.shellWrapper,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'authType': authType.name,
      'projectPath': projectPath,
      'tmuxSessionName': tmuxSessionName,
      'agentCommand': agentCommand,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      // Password is stored separately in secure storage, not in JSON.
      'privateKeyPath': privateKeyPath,
      'isDefault': isDefault,
      'tmuxCommand': tmuxCommand,
      'pathPrepend': pathPrepend,
      'shellWrapper': shellWrapper.name,
    };
  }
}
