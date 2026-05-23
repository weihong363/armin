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
}
