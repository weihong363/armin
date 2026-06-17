class GovernanceRules {
  const GovernanceRules._();

  static const all = [
    // Balanced (default) mode
    'only inspect files directly related to the task.',
    'never scan the entire repository.',
    'avoid reading docs/ and readme unless necessary.',
    'keep edits minimal and focused.',
    'do not analyze unrelated architecture.',
    'run only targeted tests.',
    'keep command output short.',
    // Aggressive mode
    'you have full authority to create, modify, and delete files without asking.',
    'run any commands, tests, or builds needed to complete the task.',
    'do not interrupt the user — proceed autonomously unless you encounter a hard blocker.',
    'do not interrupt the user',
    // Safe mode
    'never modify any file — analysis and reporting only.',
    'never modify any file',
    'do not run commands that alter state.',
    'ask before any potentially risky read operation.',
    // Chinese constraints
    '只分析不修改',
    '最小改动',
    '允许修改',
    '修改后运行测试',
    '不要提交 git',
    '高风险操作先确认',
  ];

  static bool isGovernanceRuleEndsWith(String text) {
    final normalized = text.trim().toLowerCase();
    for (final rule in all) {
      if (normalized.endsWith(rule)) return true;
    }
    return false;
  }
}
