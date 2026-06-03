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

  test('parses dynamic asking-user option prompts with descriptions', () {
    const output = '''
▪ 项目中目前没有专门的中断测试用例。你是指以下哪种场景？
   1. Ralph Loop 运行中被中断（Ctrl+C / SIGINT）— 测试循环能否优雅退出、保留已完成的迭代
   2. API 请求超时中断 — 测试 Grafana/Prometheus 等外部调用超时时系统的降级行为
   3. 其他场景 — 请具体说明
 Asking User
──────────────────────────────────────────────────────────────────────────────────────────
 你想测试哪种中断场景？
  ❯ 1. Ralph Loop 中断
       测试 Ctrl+C / SIGINT 时循环能否优雅退出并保留已完成的迭代
    2. API 请求超时中断
       测试 Grafana/Prometheus 等外部调用超时时的降级行为
    3. 两者都要
       同时测试循环中断和超时降级
    4. Type Something
 ↑↓ navigate · Enter select · Esc back
''';

    final prompt = const TerminalPromptParser().parse(output);

    expect(prompt?.question, '你想测试哪种中断场景？');
    expect(prompt?.command, isEmpty);
    expect(prompt?.options, hasLength(4));
    expect(prompt?.options.map((option) => option.label), [
      'Ralph Loop 中断',
      'API 请求超时中断',
      '两者都要',
      'Type Something',
    ]);
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
