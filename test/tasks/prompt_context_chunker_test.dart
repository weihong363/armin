import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/prompt_context_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps task and constraints even when context exceeds budget', () {
    final prompt = const PromptContextChunker(maxPromptChars: 240).build(
      taskDescription: '帮我修复登录失败，并保留用户原始错误语义',
      context: List.generate(
        80,
        (index) => 'low value context line $index',
      ).join('\n'),
      constraints: const {
        TaskConstraint.minimalChange,
        TaskConstraint.noGitCommit,
      },
      secretsText: '',
    );

    expect(prompt, contains('## User task'));
    expect(prompt, contains('帮我修复登录失败，并保留用户原始错误语义'));
    expect(prompt, contains('## User constraints'));
    expect(prompt, contains('最小改动'));
    expect(prompt, contains('不要提交 Git'));
  });

  test('prioritizes error and file context over low value notes', () {
    final prompt = const PromptContextChunker(maxPromptChars: 360).build(
      taskDescription: '修复 pets 列表为空',
      context: '''
普通背景说明，没有直接价值。

lib/features/pets/pet_list.dart
Error: expected 3 pets but actual 0 pets.

更多普通背景说明 ${'x' * 500}
''',
      constraints: const {},
      secretsText: '',
    );

    expect(prompt, contains('lib/features/pets/pet_list.dart'));
    expect(prompt, contains('expected 3 pets'));
    expect(prompt, isNot(contains('更多普通背景说明 xxxxxxxxxxxxxxxxxxxxxxxxx')));
  });

  test('truncated descriptive context keeps the leading subject and meaning',
      () {
    const summer = 'Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色、'
        '海军蓝比基尼、自信活力的 pin-up 风格，含 9 个动画状态'
        '（idle/running/waving/jumping/failed/waiting/review 等），'
        '1536×1872 精灵图集，192×208 像素格。';

    final prompt = const PromptContextChunker(maxPromptChars: 210).build(
      taskDescription: '帮我输出所有 momo 的 PET',
      context: '结果：$summer\n补充说明：${'extra ' * 80}',
      constraints: const {},
      secretsText: '',
    );

    expect(prompt, contains('Summer：一位迷人的美国沙滩女孩 Codex 宠物'));
    expect(prompt, contains('[Context truncated]'));
    expect(prompt, isNot(contains('## Context chunk 1\n个动画状态')));
  });
}
