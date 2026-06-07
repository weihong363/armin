/// 术语词典条目
///
/// 用于纠正 ASR 将专业术语误识别为音近词的问题。
class TermEntry {
  const TermEntry({
    required this.correctTerm,
    required this.asrMisspellings,
    this.category = '',
    this.description = '',
  });

  /// 正确的术语
  final String correctTerm;

  /// ASR 常见误识别结果列表（音近词）
  final List<String> asrMisspellings;

  /// 术语分类（如 AI、Tool、Framework、Language）
  final String category;

  /// 描述说明
  final String description;
}

/// 可扩展的术语词典
///
/// 维护技术术语与其 ASR 常见误识别的映射。
/// 可通过 [addEntry] 及 [addEntries] 在运行时扩展。
class TerminologyDictionary {
  TerminologyDictionary({List<TermEntry>? entries}) : _entries = entries ?? [];

  final List<TermEntry> _entries;

  /// 所有条目（只读）
  List<TermEntry> get entries => List.unmodifiable(_entries);

  /// 添加单条术语
  void addEntry(TermEntry entry) {
    _entries.add(entry);
  }

  /// 批量添加术语
  void addEntries(Iterable<TermEntry> entries) {
    _entries.addAll(entries);
  }

  /// 查找匹配给定文本的术语条目
  ///
  /// 返回一个列表，按 [correctTerm] 长度降序排列（优先长匹配）。
  List<TermEntry> findMatches(String text) {
    final lowerText = text.toLowerCase();
    final matches = <TermEntry>[];

    for (final entry in _entries) {
      for (final misspelling in entry.asrMisspellings) {
        if (lowerText.contains(misspelling.toLowerCase())) {
          matches.add(entry);
          break; // 一个条目最多匹配一次
        }
      }
    }

    // 按正确术语长度降序排列，优先替换长术语
    matches.sort(
      (a, b) => b.correctTerm.length.compareTo(a.correctTerm.length),
    );
    return matches;
  }

  /// 中文开发者常用术语默认词典
  static TerminologyDictionary defaultDictionary() {
    return TerminologyDictionary(entries: [
      // ---- AI / LLM 领域 ----
      const TermEntry(
        correctTerm: 'Codex',
        asrMisspellings: ['科迪克斯', '扣迪克斯', '扣的死', 'codex', '扣的'],
        category: 'AI',
        description: 'OpenAI Codex CLI 工具',
      ),
      const TermEntry(
        correctTerm: 'Claude Code',
        asrMisspellings: ['克劳德扣的', '克劳德code', 'claude扣的', 'cloud code'],
        category: 'AI',
        description: 'Anthropic Claude Code 工具',
      ),
      const TermEntry(
        correctTerm: 'Cursor',
        asrMisspellings: ['科瑟', '扣瑟', 'kosa'],
        category: 'AI',
        description: 'AI 编程编辑器 Cursor',
      ),
      const TermEntry(
        correctTerm: 'Qwen',
        asrMisspellings: ['Q文', 'q文', 'kwen', 'quentin', '困'],
        category: 'AI',
        description: '阿里通义千问模型',
      ),
      const TermEntry(
        correctTerm: 'MCP',
        asrMisspellings: [
          'MCB',
          'mcp server',
          'map si pi',
          'em si pi',
          'emcp',
        ],
        category: 'AI',
        description: 'Model Context Protocol',
      ),
      const TermEntry(
        correctTerm: 'LangChain',
        asrMisspellings: ['狼链', '兰链', 'lang chain', '狼che', '廊chain'],
        category: 'AI',
        description: 'LangChain 框架',
      ),
      const TermEntry(
        correctTerm: 'LangGraph',
        asrMisspellings: ['郎图', '兰图', 'lang graph', '廊graph'],
        category: 'AI',
        description: 'LangGraph 框架',
      ),
      const TermEntry(
        correctTerm: 'Oazen',
        asrMisspellings: ['欧神', '欧增', 'ozen'],
        category: 'AI',
        description: 'Oazen',
      ),
      const TermEntry(
        correctTerm: 'Armin',
        asrMisspellings: ['阿明', '阿敏', '二明', '啊民'],
        category: 'Product',
        description: 'Armin 项目本身',
      ),

      // ---- 开发工具 ----
      const TermEntry(
        correctTerm: 'tmux',
        asrMisspellings: ['t marks', '替mux', '铁max', 't max'],
        category: 'Tool',
        description: '终端复用器 tmux',
      ),
      const TermEntry(
        correctTerm: 'SSH',
        asrMisspellings: ['ss h', 'ss each', 'esh'],
        category: 'Tool',
        description: 'SSH 远程连接',
      ),
      const TermEntry(
        correctTerm: 'Docker',
        asrMisspellings: ['刀客', 'docka', '道客'],
        category: 'Tool',
        description: 'Docker 容器',
      ),
      const TermEntry(
        correctTerm: 'Kubernetes',
        asrMisspellings: ['库bernet', 'k8', 'k8s', 'k8ss', 'k ate'],
        category: 'Tool',
        description: 'Kubernetes (K8s)',
      ),

      // ---- 编程语言 / 框架 ----
      const TermEntry(
        correctTerm: 'Flutter',
        asrMisspellings: ['flatter', 'flater', '浮拉特', 'flat'],
        category: 'Framework',
        description: 'Flutter 框架',
      ),
      const TermEntry(
        correctTerm: 'Dart',
        asrMisspellings: ['达特', '大特', 'dot', 'dark'],
        category: 'Language',
        description: 'Dart 编程语言',
      ),
      const TermEntry(
        correctTerm: 'Python',
        asrMisspellings: ['拍森', '派森', 'pison', 'pyson'],
        category: 'Language',
        description: 'Python 编程语言',
      ),
      const TermEntry(
        correctTerm: 'Rust',
        asrMisspellings: ['ras', 'rast', '拉斯特', 'rasp'],
        category: 'Language',
        description: 'Rust 编程语言',
      ),

      // ---- 通用技术词汇 ----
      const TermEntry(
        correctTerm: '架构',
        asrMisspellings: ['架狗', '架够', '价格'],
        category: 'General',
        description: '软件架构',
      ),
      const TermEntry(
        correctTerm: 'project',
        asrMisspellings: ['普肉接特', '普肉杰克', 'projack', 'projekt'],
        category: 'General',
        description: '项目',
      ),
      const TermEntry(
        correctTerm: 'code',
        asrMisspellings: ['扣的', '口的', '扣德', '扣得'],
        category: 'General',
        description: '代码',
      ),
      const TermEntry(
        correctTerm: 'API',
        asrMisspellings: ['a pi', 'a匹', 'api', 'ap i'],
        category: 'General',
        description: '应用程序接口',
      ),
      const TermEntry(
        correctTerm: 'CLI',
        asrMisspellings: ['c l i', 'see l i', 'sea lie'],
        category: 'General',
        description: '命令行接口',
      ),
      const TermEntry(
        correctTerm: 'config',
        asrMisspellings: ['康费格', 'confi', '康fig'],
        category: 'General',
        description: '配置文件',
      ),
      const TermEntry(
        correctTerm: 'GitHub',
        asrMisspellings: ['git up', '给塔', 'geethub'],
        category: 'General',
        description: 'GitHub 平台',
      ),
      const TermEntry(
        correctTerm: 'GitLab',
        asrMisspellings: ['git lab', '给特lab', 'geetlab'],
        category: 'General',
        description: 'GitLab 平台',
      ),
      const TermEntry(
        correctTerm: 'npm',
        asrMisspellings: ['n p m', 'en pm', 'enpiem'],
        category: 'Tool',
        description: 'Node.js 包管理器',
      ),

      // ---- 常见 ASR 误差 ----
      const TermEntry(
        correctTerm: '部署',
        asrMisspellings: ['布属', '不熟', '不鼠'],
        category: 'General',
        description: '部署',
      ),
      const TermEntry(
        correctTerm: '重构',
        asrMisspellings: ['重购', '从勾', '从构'],
        category: 'General',
        description: '代码重构',
      ),
      const TermEntry(
        correctTerm: '日志',
        asrMisspellings: ['日字', '日之', '自制'],
        category: 'General',
        description: '日志文件',
      ),
      const TermEntry(
        correctTerm: '数据库',
        asrMisspellings: ['数聚库', '数据酷', '数据苦'],
        category: 'General',
        description: '数据库',
      ),
    ]);
  }
}
