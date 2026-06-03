import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/agent/parsers/task_result_parser.dart';

void main() {
  test('parses TASK_RESULT block', () {
    final result = TaskResultParser().parse('''
noise
TASK_RESULT_START
status: success
summary: done
changed_files:
- lib/main.dart
validation:
- flutter test
risks:
- none
next_actions:
- ship
TASK_RESULT_END
''');

    expect(result, isNotNull);
    expect(result!.status, 'success');
    expect(result.summary, 'done');
    expect(result.changedFiles, ['lib/main.dart']);
    expect(result.validation, ['flutter test']);
    expect(result.risks, ['none']);
    expect(result.nextActions, ['ship']);
  });

  test('ignores template placeholder result block', () {
    final result = TaskResultParser().parse('''
TASK_RESULT_START
status: success | failed | need_user_input
summary: ...
changed_files:
- ...
validation:
- ...
risks:
- ...
next_actions:
- ...
TASK_RESULT_END
''');

    expect(result, isNull);
  });

  test('uses latest real result block', () {
    final result = TaskResultParser().parse('''
TASK_RESULT_START
status: success | failed | need_user_input
summary: ...
TASK_RESULT_END
noise
TASK_RESULT_START
status: success
summary: pets are A, B
changed_files:
validation:
risks:
- none
next_actions:
- A
- B
TASK_RESULT_END
''');

    expect(result, isNotNull);
    expect(result!.summary, 'pets are A, B');
    expect(result.nextActions, ['A', 'B']);
  });

  test('parses Codex TUI result block with spaced underscores', () {
    final result = TaskResultParser().parse('''
> 任务：输出hello。完成后只输出 TASK _ RESULT _ START 块，字段为 status,
summary, changed _ files, validation, risks, next _ actions，并以
TASK _ RESULT _ END 结束。

• TASK _ RESULT _ START
status: success
summary: hello
changed _ files: [ ]
validation: not_run
risks: none
next _ actions: [ ]
TASK _ RESULT _ END
''');

    expect(result, isNotNull);
    expect(result!.status, 'success');
    expect(result.summary, 'hello');
    expect(result.validation, ['not_run']);
    expect(result.risks, ['none']);
    expect(result.nextActions, isEmpty);
  });

  test('parses natural Codex TUI output without structure', () {
    final result = TaskResultParser().parseNatural('''
┌──────────────────────────────┐
│ > 输出hello                   │
└──────────────────────────────┘

⚠ Skipped loading 1 skill(s) due to invalid SKILL.md files.

hello

gpt-5.5 medium fast · ~/workspace/momo
''', prompt: '输出hello');

    expect(result, isNotNull);
    expect(result!.status, 'success');
    expect(result.summary, 'hello');
  });

  test('does not parse Codex update prompt as natural output', () {
    final result = TaskResultParser().parseNatural('''
✨ Update available! 0.130.0 -> 0.132.0
Release notes: https://github.com/openai/codex/releases/latest
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version
Press enter to continue
Armin timed out waiting for Codex TUI to become ready.
''');

    expect(result, isNull);
  });

  test('parses natural output after Codex update prompt noise', () {
    final result = TaskResultParser().parseNatural('''
✨ Update available! 0.130.0 -> 0.132.0
Release notes: https://github.com/openai/codex/releases/latest
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version
Press enter to continue

┌──────────────────────────────┐
│ > 输出hello                   │
└──────────────────────────────┘

hello

> Explain this codebase
gpt-5.5 medium fast · ~/workspace/momo
''', prompt: '输出hello');

    expect(result, isNotNull);
    expect(result!.summary, 'hello');
  });

  test('drops turn headers and prompt governance echo from natural output', () {
    final result = TaskResultParser().parseNatural('''
Do not analyze unrelated architecture.
- Run only targeted tests.
- Keep command output short.

Turn 1
最小改动不要提交Git高风险操作先确认
hello world
''', prompt: '输出hello world在一行里面输出');

    expect(result, isNotNull);
    expect(result!.summary, 'hello world');
  });

  test('parses only output from noisy Codex pane', () {
    final result = TaskResultParser().parseNatural('''
╭────────────────────────────────────────────╮
│                                            │
╰────────────────────────────────────────────╯
https://chatgpt.com/codex?app-landing-page=true
mapping values are not allowed in this context at
line 2 column 152
mapping values are not allowed in this context at
line 2 column 152
输出hello
hello
Use /skills to list available skills
Implement {feature}
''', prompt: '输出hello');

    expect(result, isNotNull);
    expect(result!.summary, 'hello');
  });

  test('filters Codex tool trace lines from natural output', () {
    final result = TaskResultParser().parseNatural('''
帮我输出所有的pets名
我先看一下仓库里宠物资源的目录和命名方式，然后直接把现有 pet 名称列出来。
Explored
Search (^|/)Pets/|pets|Pet
Search Pets in .
Explored
Search pet|Pet|Pets|assets|Assets in .
List hatch-pet
List hatch-runs
Search pet.json in .
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
实际的 pets 有 momo、luna、nori。
''', prompt: '帮我输出所有的pets名');

    expect(result, isNotNull);
    expect(result!.summary, isNot(contains('Explored')));
    expect(result.summary, isNot(contains('Search')));
    expect(result.summary, isNot(contains('Ran jq')));
    expect(result.summary, contains('实际的 pets 有 momo、luna、nori。'));
  });
}
