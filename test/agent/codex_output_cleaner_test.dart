import 'package:armin/features/agent/services/codex_output_cleaner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('removes ansi and Codex TUI noise without mutating raw text', () {
    const raw = '\x1B[32mhello\x1B[0m\n'
        '│ >_ OpenAI Codex (v0.130.0)\n'
        'Use /skills to list available skills\n'
        'Explored\n'
        'Search (^|/)Pets/|pets|Pet\n';

    final cleaned = const CodexOutputCleaner().clean(raw);

    expect(raw, contains('\x1B[32m'));
    expect(cleaned, contains('hello'));
    expect(cleaned, isNot(contains('Explored')));
    expect(cleaned, isNot(contains('Search')));
    expect(cleaned, isNot(contains('OpenAI Codex')));
    expect(cleaned, isNot(contains('Use /skills')));
    expect(cleaned, isNot(contains('\x1B')));
  });

  test('removes Armin governance and invalid skill noise', () {
    const raw = '''
Armin context governance:
- Only inspect files directly related to the task.
- Never scan the entire repository.
https://chatgpt.com/codex?app-landing-page=true
mapping values are not allowed in this context at line 2 column 152
Find and fix a bug in @filename
输出 hello
hello
''';

    final cleaned = const CodexOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, isNot(contains('Never scan')));
    expect(cleaned, isNot(contains('chatgpt.com')));
    expect(cleaned, isNot(contains('mapping values')));
    expect(cleaned, isNot(contains('@filename')));
    expect(cleaned, contains('输出 hello'));
    expect(cleaned, contains('hello'));
  });
}
