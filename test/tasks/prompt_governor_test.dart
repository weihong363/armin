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
      'AGENTS.md detected. Agent may follow repository-specific '
      'optimization rules.',
    );
  });
}
