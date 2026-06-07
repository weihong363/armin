import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/agent_instruction_discovery.dart';
import 'package:armin/features/tasks/services/prompt_governor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PromptGovernor injects short context governance rules', () {
    final prompt = const PromptGovernor().apply('输出 hello');
    final lines = prompt.split('\n');

    expect(prompt, contains('Only inspect files directly related'));
    expect(prompt, contains('Never scan the entire repository'));
    expect(prompt, isNot(contains('TASK_RESULT_START')));
    expect(prompt, isNot(contains('NEED_APPROVAL_START')));
    expect(prompt, endsWith('输出 hello'));
    expect(lines.length, lessThanOrEqualTo(20));
  });

  test('aggressive mode removes restrictive governance rules', () {
    final prompt = const PromptGovernor().apply(
      '重构登录模块',
      constraints: {TaskConstraint.allowChanges},
    );

    expect(prompt, contains('aggressive'));
    expect(prompt, isNot(contains('Keep edits minimal')));
    expect(prompt, isNot(contains('Run only targeted tests')));
    expect(prompt, isNot(contains('Keep command output short')));
    expect(prompt, contains('You have full authority'));
    expect(prompt, contains('Run any commands'));
    expect(prompt, endsWith('重构登录模块'));
  });

  test('safe mode adds no-write governance rules', () {
    final prompt = const PromptGovernor().apply(
      '分析项目结构',
      constraints: {TaskConstraint.analyzeOnly},
    );

    expect(prompt, contains('safe'));
    expect(prompt, contains('Never modify any file'));
    expect(prompt, contains('Do not run commands that alter state'));
    expect(prompt, endsWith('分析项目结构'));
  });

  test('balanced mode keeps original governance rules', () {
    final prompt = const PromptGovernor().apply(
      '修一下bug',
      constraints: {TaskConstraint.minimalChange, TaskConstraint.noGitCommit},
    );

    expect(prompt, contains('Keep edits minimal'));
    expect(prompt, contains('Run only targeted tests'));
    expect(prompt, isNot(contains('aggressive')));
    expect(prompt, isNot(contains('safe')));
  });

  test('empty constraints fall back to balanced rules', () {
    final prompt = const PromptGovernor().apply('hello', constraints: {});

    expect(prompt, contains('Keep edits minimal'));
    expect(prompt, isNot(contains('aggressive')));
    expect(prompt, isNot(contains('safe')));
  });

  test('AgentInstructionDiscovery uses bounded find command', () {
    const discovery = AgentInstructionDiscovery(maxDepth: 3);
    final command = discovery.buildFindCommand();

    expect(command, contains('find . -maxdepth 3'));
    expect(command, contains('AGENTS.md'));
    expect(command, contains('AGENTS.override.md'));
  });

  test('AgentInstructionDiscovery parses UI message', () {
    final result = const AgentInstructionDiscovery().parse(
      './AGENTS.md\n./app/AGENTS.override.md\n',
    );

    expect(result.detected, isTrue);
    expect(
      result.uiMessage,
      '检测到 AGENTS.md。Agent 可能会读取仓库内的专用规则。',
    );
  });

  test('AgentInstructionDiscovery key includes host project and path', () {
    const key = AgentInstructionDiscoveryKey(
      hostId: 'host-1',
      projectPathId: 'project-2',
      normalizedProjectPath: '~/workspace/armin',
    );

    expect(key.value, 'host-1::project-2::~/workspace/armin');
  });
}
