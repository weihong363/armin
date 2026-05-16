import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/tasks/models/secret_entry.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/prompt_template_builder.dart';

void main() {
  test('PromptTemplateBuilder builds final prompt with redacted secrets', () {
    final prompt = PromptTemplateBuilder().build(
      taskDescription: '修复登录失败 token=abc123',
      context: '错误日志 password=hunter2',
      constraints: const {
        TaskConstraint.minimalChange,
        TaskConstraint.noGitCommit,
      },
      secrets: const [
        SecretEntry(
          name: 'GITHUB_TOKEN',
          value: 'secret-value',
          usage: 'GitHub API',
        ),
      ],
    );

    expect(prompt, contains('请完成以下任务'));
    expect(prompt, contains('最小改动'));
    expect(prompt, contains('不要提交 Git'));
    expect(prompt, contains('GITHUB_TOKEN: [REDACTED]'));
    expect(prompt, isNot(contains('abc123')));
    expect(prompt, isNot(contains('hunter2')));
    expect(prompt, isNot(contains('secret-value')));
    expect(prompt, contains('TASK_RESULT_START'));
    expect(prompt, contains('NEED_APPROVAL_START'));
  });
}
