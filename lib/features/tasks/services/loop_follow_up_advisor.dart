import '../models/task_constraint.dart';
import '../models/task_session.dart';

class LoopFollowUpSuggestion {
  const LoopFollowUpSuggestion({
    required this.id,
    required this.title,
    required this.reason,
    required this.draft,
    required this.priority,
  });

  final String id;
  final String title;
  final String reason;
  final String draft;
  final int priority;
}

class LoopFollowUpAdvisor {
  const LoopFollowUpAdvisor();

  List<LoopFollowUpSuggestion> suggest(TaskSession task) {
    final deliverable = task.turns.lastOrNull?.deliverable;
    if (deliverable == null) {
      return const [];
    }
    final summary = deliverable.displaySummary.trim();
    if (summary.isEmpty) {
      return const [];
    }
    final lower = summary.toLowerCase();
    final suggestions = <LoopFollowUpSuggestion>[];

    if (_hasBlocker(lower)) {
      suggestions.add(_blockerSuggestion());
    }
    if (_needsTestEvidence(task, lower)) {
      suggestions.add(_testEvidenceSuggestion());
    }
    if (_hasImplementationSignal(summary) && !_hasFileEvidence(summary)) {
      suggestions.add(_fileEvidenceSuggestion());
    }
    if (_looksTooThin(summary) && !_hasCompletionEvidence(lower)) {
      suggestions.add(_clarifyCompletionSuggestion());
    }
    if (_mayViolateConstraints(task, lower)) {
      suggestions.add(_constraintCheckSuggestion());
    }

    suggestions.sort((a, b) => a.priority.compareTo(b.priority));
    return suggestions.take(3).toList(growable: false);
  }

  bool _hasBlocker(String lower) {
    const markers = [
      'blocked',
      'auth',
      'permission',
      'cannot',
      'failed',
      'error',
      '无法',
      '失败',
      '权限',
      '认证',
      '阻塞',
    ];
    return markers.any(lower.contains);
  }

  bool _needsTestEvidence(TaskSession task, String lower) {
    if (_hasTestEvidence(lower)) {
      return false;
    }
    return task.constraints.contains(TaskConstraint.runTestsAfterChanges) ||
        _hasImplementationSignal(lower);
  }

  bool _hasTestEvidence(String lower) {
    const markers = [
      'test',
      'passed',
      'all tests passed',
      'flutter test',
      'npm test',
      'pytest',
      'go test',
      '测试',
      '通过',
    ];
    return markers.any(lower.contains);
  }

  bool _hasImplementationSignal(String text) {
    final lower = text.toLowerCase();
    const markers = [
      'implemented',
      'modified',
      'updated',
      'created',
      'fixed',
      'added',
      '实现',
      '修改',
      '更新',
      '修复',
      '新增',
    ];
    return markers.any(lower.contains);
  }

  bool _hasFileEvidence(String text) {
    final filePattern = RegExp(
      r'([\w.-]+/)+[\w.-]+\.\w+|[\w.-]+\.(dart|ts|tsx|js|jsx|json|yaml|yml|md|go|rs|py|kt|swift)',
      caseSensitive: false,
    );
    return filePattern.hasMatch(text);
  }

  bool _looksTooThin(String text) {
    final usefulChars = text.replaceAll(RegExp(r'\s+'), '');
    return usefulChars.length < 40;
  }

  bool _hasCompletionEvidence(String lower) {
    const markers = [
      'completed',
      'done',
      'passed',
      '已完成',
      '完成',
      '通过',
      '可验收',
    ];
    return markers.any(lower.contains);
  }

  bool _mayViolateConstraints(TaskSession task, String lower) {
    final analyzeOnly = task.constraints.contains(TaskConstraint.analyzeOnly);
    final noGitCommit = task.constraints.contains(TaskConstraint.noGitCommit);
    final mentionsChange = _hasImplementationSignal(lower);
    final mentionsCommit = lower.contains('commit') ||
        lower.contains('git commit') ||
        lower.contains('提交');
    return (analyzeOnly && mentionsChange) || (noGitCommit && mentionsCommit);
  }

  LoopFollowUpSuggestion _blockerSuggestion() {
    return const LoopFollowUpSuggestion(
      id: 'resolve_blocker',
      title: '先收敛阻塞',
      reason: '结果里出现阻塞、认证、权限或失败信号，继续扩展任务前应先确认原因。',
      draft: '请先说明当前阻塞原因、最小解除步骤，以及是否需要我确认或提供信息。不要扩大任务范围。',
      priority: 10,
    );
  }

  LoopFollowUpSuggestion _testEvidenceSuggestion() {
    return const LoopFollowUpSuggestion(
      id: 'request_test_evidence',
      title: '补充测试证据',
      reason: '本轮结果没有明确测试命令或测试结果，暂时缺少可验收证据。',
      draft: '请运行与本次修改相关的最小测试；如果没有可运行测试或本轮没有代码修改，请停止继续搜索，'
          '直接输出测试命令、结果或未运行原因，以及仍未覆盖的风险。',
      priority: 20,
    );
  }

  LoopFollowUpSuggestion _fileEvidenceSuggestion() {
    return const LoopFollowUpSuggestion(
      id: 'request_file_evidence',
      title: '补充修改清单',
      reason: '结果提到实现或修改，但没有清晰的文件清单和验证方式。',
      draft: '请输出本轮修改的文件列表、每个文件的作用，以及如何验证这些修改。',
      priority: 30,
    );
  }

  LoopFollowUpSuggestion _clarifyCompletionSuggestion() {
    return const LoopFollowUpSuggestion(
      id: 'clarify_completion',
      title: '确认完成度',
      reason: '本轮结果过短或缺少交付细节，无法判断是否可验收。',
      draft: '请明确列出已完成内容、未完成内容、下一步最小动作，以及当前是否可验收。',
      priority: 40,
    );
  }

  LoopFollowUpSuggestion _constraintCheckSuggestion() {
    return const LoopFollowUpSuggestion(
      id: 'check_constraints',
      title: '确认约束是否被遵守',
      reason: '本轮结果可能与只读、不要提交或类似约束存在冲突。',
      draft: '请确认本轮是否修改了文件、是否提交了 Git，以及是否违反我给出的约束。',
      priority: 50,
    );
  }
}
