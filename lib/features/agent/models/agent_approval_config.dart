/// 统一审批模式 —— UI 层使用的抽象概念，与具体 CLI 无关。
enum AgentApprovalMode {
  /// 安全：只读分析，所有写操作需确认
  safe,

  /// 平衡：自动放行低风险编辑，高风险仍需确认
  balanced,

  /// 激进：完全自主，跳过所有权限检查
  aggressive,
}

extension AgentApprovalModeLabel on AgentApprovalMode {
  String get label {
    return switch (this) {
      AgentApprovalMode.safe => '安全',
      AgentApprovalMode.balanced => '平衡',
      AgentApprovalMode.aggressive => '激进',
    };
  }

  String get description {
    return switch (this) {
      AgentApprovalMode.safe => '只读 · 不做修改',
      AgentApprovalMode.balanced => '可修改代码 · 先请示',
      AgentApprovalMode.aggressive => '完全授权 · 不中断',
    };
  }
}

/// CLI 代理类型，用于将统一审批模式翻译为各 CLI 的原生启动参数。
enum AgentType {
  codex,
  qoder,
  claude,

  /// 未识别的 CLI，不传审批参数，仅依赖 Prompt 内治理规则。
  custom,
}

extension AgentTypeDetection on AgentType {
  /// 从 agentCommand 字符串自动检测 AgentType。
  static AgentType detect(String agentCommand) {
    final basename = agentCommand.trim().toLowerCase().split('/').last;
    if (basename == 'codex') return AgentType.codex;
    if (basename == 'qodercli' || basename == 'qoder') return AgentType.qoder;
    if (basename == 'claude') return AgentType.claude;
    return AgentType.custom;
  }
}

/// 审批配置：将统一模式翻译为具体 CLI 的启动参数。
///
/// 所有 CLI 的默认行为即视为"平衡"模式，因此 balanced 模式不追加任何
/// 额外 flag——仅在偏离默认时才传入参数。
class AgentApprovalConfig {
  const AgentApprovalConfig({
    required this.agentType,
    required this.mode,
  });

  final AgentType agentType;
  final AgentApprovalMode mode;

  /// 需要注入到 CLI 启动命令后的额外参数。
  /// 返回空列表表示不传参数，使用该 CLI 的默认行为。
  List<String> get launchFlags {
    return switch (agentType) {
      AgentType.codex => _codexFlags,
      AgentType.qoder => _qoderFlags,
      AgentType.claude => _claudeFlags,
      AgentType.custom => const [],
    };
  }

  List<String> get _codexFlags {
    return switch (mode) {
      AgentApprovalMode.safe => [
          '--sandbox',
          'read-only',
          '--ask-for-approval',
          'untrusted',
        ],
      AgentApprovalMode.balanced => const [],
      AgentApprovalMode.aggressive => ['--full-auto'],
    };
  }

  List<String> get _qoderFlags {
    return switch (mode) {
      AgentApprovalMode.safe => ['--permission-mode', 'plan'],
      AgentApprovalMode.balanced => const [],
      // Armin's YOLO mode keeps the terminal approval channel observable and
      // auto-approves through Runtime. Do not bypass qodercli permissions here.
      AgentApprovalMode.aggressive => const [],
    };
  }

  List<String> get _claudeFlags {
    return switch (mode) {
      AgentApprovalMode.safe => ['--permission-mode', 'plan'],
      AgentApprovalMode.balanced => const [],
      AgentApprovalMode.aggressive => ['--dangerously-skip-permissions'],
    };
  }
}
