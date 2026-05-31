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

    expect(prompt, startsWith('Armin context governance:'));
    expect(prompt, contains('Only inspect files directly related'));
    expect(prompt, contains('Never scan the entire repository'));
    expect(prompt, contains('## User task'));
    expect(prompt, contains('## User constraints'));
    expect(prompt, contains('最小改动'));
    expect(prompt, contains('不要提交 Git'));
    expect(prompt, contains('## Context chunk'));
    expect(prompt, contains('## Secret placeholders'));
    expect(prompt, contains('错误日志'));
    expect(prompt, contains('修复登录失败'));
    expect(prompt, contains('GITHUB_TOKEN: [REDACTED]'));
    expect(prompt, isNot(contains('abc123')));
    expect(prompt, isNot(contains('hunter2')));
    expect(prompt, isNot(contains('secret-value')));
    expect(prompt, isNot(contains('TASK_RESULT_START')));
    expect(prompt, isNot(contains('NEED_APPROVAL_START')));
    expect(prompt, isNot(contains('完成后只输出')));
    expect(prompt, isNot(contains('普通开发操作默认允许')));
    expect(prompt, isNot(contains('不要自动 git commit')));
    expect(prompt, isNot(contains('安装/升级依赖')));
  });

  test('PromptTemplateBuilder does not let long context erase task semantics',
      () {
    final prompt = PromptTemplateBuilder().build(
      taskDescription: '输出所有 momo 的 PET，并检查是否有 SUMMER',
      context: List.generate(
        200,
        (index) => '背景噪音 $index：这是一段很长但优先级较低的上下文。',
      ).join('\n'),
      constraints: const {
        TaskConstraint.analyzeOnly,
        TaskConstraint.noGitCommit,
      },
      secrets: const [],
    );

    expect(prompt, contains('输出所有 momo 的 PET，并检查是否有 SUMMER'));
    expect(prompt, contains('只分析不修改'));
    expect(prompt, contains('不要提交 Git'));
  });
}
