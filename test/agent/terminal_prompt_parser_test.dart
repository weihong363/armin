import 'package:armin/features/agent/parsers/terminal_prompt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses Codex execution prompt options from terminal output', () {
    const output = '''
\x1B[33mAllow execution of [ls]? Redirection detected.\x1B[0m

\x1B[32m> 1. Allow once\x1B[0m
  2. Always allow this exact command for future sessions
  3. Reject and type something
  4. No
''';

    final prompt = const TerminalPromptParser().parse(output);

    expect(prompt?.question, 'Allow execution of [ls]? Redirection detected.');
    expect(prompt?.options, hasLength(4));
    expect(prompt?.options.first.key, '1');
    expect(prompt?.options.first.label, 'Allow once');
    expect(prompt?.options.last.label, 'No');
  });

  test('parses allow-this-command prompts from terminal output', () {
    const output = '''
Tool: Bash
Run test_hello_world.py with verbose output
Command: cd /Users/ironion/workspace/runbook-copilot &&
python -m pytest tests/test_hello_world.py -v 2>&1 | head -30
Allow this command to run? Redirection detected.
> 1. Allow once
  2. Always allow this exact command for future sessions
  3. Reject and type something
  4. No
''';

    final prompt = const TerminalPromptParser().parse(output);

    expect(
        prompt?.question, 'Allow this command to run? Redirection detected.');
    expect(
      prompt?.command,
      'cd /Users/ironion/workspace/runbook-copilot && python -m pytest tests/test_hello_world.py -v 2>&1 | head -30',
    );
    expect(prompt?.options, hasLength(4));
    expect(prompt?.options.first.key, '1');
    expect(prompt?.options.first.label, 'Allow once');
  });

  test('ignores ordinary numbered terminal output', () {
    final prompt = const TerminalPromptParser().parse('''
Validation complete:
1. flutter test passed
2. flutter analyze passed
''');

    expect(prompt, isNull);
  });
}
