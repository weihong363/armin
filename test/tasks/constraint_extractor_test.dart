import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/constraint_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts common spoken constraints', () {
    final constraints = const ConstraintExtractor().extract(
      '先看看登录问题，先别大改，跑一下测试，别提交',
    );

    expect(constraints, contains(TaskConstraint.analyzeOnly));
    expect(constraints, contains(TaskConstraint.minimalChange));
    expect(constraints, contains(TaskConstraint.runTestsAfterChanges));
    expect(constraints, contains(TaskConstraint.noGitCommit));
  });

  test('English no-modify instruction overrides allow-change wording', () {
    final constraints = const ConstraintExtractor().extract(
      'Read pubspec.yaml. Do not modify files. 允许修改',
    );

    expect(constraints, contains(TaskConstraint.analyzeOnly));
    expect(constraints, isNot(contains(TaskConstraint.allowChanges)));
  });
}
