enum TaskConstraint {
  analyzeOnly,
  minimalChange,
  allowChanges,
  runTestsAfterChanges,
  noGitCommit,
  confirmHighRisk,
}

extension TaskConstraintLabel on TaskConstraint {
  String get label {
    switch (this) {
      case TaskConstraint.analyzeOnly:
        return '只分析不修改';
      case TaskConstraint.minimalChange:
        return '最小改动';
      case TaskConstraint.allowChanges:
        return '允许修改';
      case TaskConstraint.runTestsAfterChanges:
        return '修改后运行测试';
      case TaskConstraint.noGitCommit:
        return '不要提交 Git';
      case TaskConstraint.confirmHighRisk:
        return '高风险操作先确认';
    }
  }
}
