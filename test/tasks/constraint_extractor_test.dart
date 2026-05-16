import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/constraint_extractor.dart';

void main() {
  test('extracts common spoken constraints', () {
    final constraints = ConstraintExtractor().extract(
      '先看看登录问题，先别大改，跑一下测试，别提交',
    );

    expect(constraints, contains(TaskConstraint.analyzeOnly));
    expect(constraints, contains(TaskConstraint.minimalChange));
    expect(constraints, contains(TaskConstraint.runTestsAfterChanges));
    expect(constraints, contains(TaskConstraint.noGitCommit));
  });
}
