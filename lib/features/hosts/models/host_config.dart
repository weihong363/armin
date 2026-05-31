enum HostAuthType {
  password,
  privateKey,
}

enum ShellWrapper {
  none,
  shLogin,
  zshLogin,
}

enum HostMachineType {
  generic,
  macAppleSilicon,
  macIntel,
  linux,
}

extension HostMachineTypeDefaults on HostMachineType {
  String get label {
    return switch (this) {
      HostMachineType.generic => '通用 / 自定义',
      HostMachineType.macAppleSilicon => 'macOS Apple Silicon',
      HostMachineType.macIntel => 'macOS Intel',
      HostMachineType.linux => 'Linux',
    };
  }

  String get defaultTmuxCommand {
    return switch (this) {
      HostMachineType.generic => 'tmux',
      HostMachineType.macAppleSilicon => '/opt/homebrew/bin/tmux',
      HostMachineType.macIntel => '/usr/local/bin/tmux',
      HostMachineType.linux => '/usr/bin/tmux',
    };
  }

  String get defaultPathPrepend {
    return switch (this) {
      HostMachineType.generic => '',
      HostMachineType.macAppleSilicon =>
        '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
      HostMachineType.macIntel =>
        '/usr/local/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
      HostMachineType.linux =>
        '/usr/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
    };
  }

  String get defaultAgentCommand {
    return switch (this) {
      HostMachineType.generic => 'codex',
      HostMachineType.macAppleSilicon => r'$HOME/.npm-global/bin/codex',
      HostMachineType.macIntel => r'$HOME/.npm-global/bin/codex',
      HostMachineType.linux => r'$HOME/.npm-global/bin/codex',
    };
  }

  String get description {
    return switch (this) {
      HostMachineType.generic => '使用远端 shell PATH 中的 tmux。',
      HostMachineType.macAppleSilicon => 'Homebrew 工具通常位于 /opt/homebrew/bin。',
      HostMachineType.macIntel => 'Homebrew 工具通常位于 /usr/local/bin。',
      HostMachineType.linux => '系统工具通常位于 /usr/bin。',
    };
  }
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
    this.machineType = HostMachineType.generic,
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
      machineType: HostMachineType.values.firstWhere(
        (type) => type.name == json['machineType'],
        orElse: () => HostMachineType.generic,
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
  final HostMachineType machineType;

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
    HostMachineType? machineType,
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
      machineType: machineType ?? this.machineType,
    );
  }

  HostConfig toSafePersistedCopy() {
    return copyWith(password: '');
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
      'machineType': machineType.name,
    };
  }
}
