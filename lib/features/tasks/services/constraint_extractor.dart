import '../models/task_constraint.dart';

class ConstraintExtractor {
  const ConstraintExtractor();

  Set<TaskConstraint> extract(String text) {
    final input = text.trim().toLowerCase();
    if (input.isEmpty) {
      return const {};
    }

    final constraints = <TaskConstraint>{};

    if (_containsAny(input, ['先看看', '先看一下', '先分析', '只分析', '别改'])) {
      constraints.add(TaskConstraint.analyzeOnly);
    }
    if (_containsAny(input, ['先别大改', '最小改动', '小改', '不要大规模重构'])) {
      constraints.add(TaskConstraint.minimalChange);
    }
    if (_containsAny(input, ['可以改', '允许修改', '直接改'])) {
      constraints.add(TaskConstraint.allowChanges);
    }
    if (_containsAny(input, ['跑一下测试', '运行测试', '跑测试', '测一下'])) {
      constraints.add(TaskConstraint.runTestsAfterChanges);
    }
    if (_containsAny(
        input, ['别提交', '不要提交', '不要 commit', '不要 git commit', '不要git commit'])) {
      constraints.add(TaskConstraint.noGitCommit);
    }
    if (_containsAny(input, ['高风险先确认', '危险操作先问', '删东西先问'])) {
      constraints.add(TaskConstraint.confirmHighRisk);
    }

    return constraints;
  }

  bool _containsAny(String input, List<String> patterns) {
    return patterns.any(input.contains);
  }
}
