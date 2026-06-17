import 'package:armin/features/agent/parsers/terminal_prompt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects Permission Required write prompt via question keyword', () {
    const output = 'Permission Required\n'
        '\n'
        'Tool: Write\n'
        'File: rename_tool/setup.py\n'
        '\n'
        '    1 #!/usr/bin/env python3\n'
        '    2 from setuptools import setup\n'
        '\n'
        '    4 setup(\n'
        '    5     name=\'rename-tool\',\n'
        '    6     version=\'1.0.0\',\n'
        '    7     py_modules=[\'rename\'],\n'
        '    8     entry_points={\n'
        '    9         \'console_scripts\': [\n'
        '   10             \'rename-tool=rename:main\',\n'
        '   11         ],\n'
        '   12     },\n'
        '   13     python_requires=\'>=3.6\',\n'
        '   14 )\n'
        '\n'
        'Apply this change?\n'
        '\n'
        '  \u276f 1. Allow once\n'
        '    2. Allow for this session\n'
        '    3. Modify with external editor\n'
        '    4. Reject and type something\n'
        '    5. No\n';

    final prompt = const TerminalPromptParser().parse(output);
    expect(prompt, isNotNull);
    expect(prompt!.question, 'Apply this change?');
    expect(prompt.options, hasLength(5));
    expect(prompt.options.first.key, '1');
    expect(prompt.options.first.label, 'Allow once');
  });

  test('detects apply-change prompt without Permission Required title', () {
    const output = 'Some generated code preview\n'
        'Tool: Write\n'
        'File: README.md\n'
        '\n'
        '    1 # 文件批量重命名工具\n'
        '    2 支持正则匹配、递归处理、预览模式。\n'
        '\n'
        'Apply this change?\n'
        '\n'
        '  \u276f 1. Allow once\n'
        '    2. Allow for this session\n'
        '    3. Modify with external editor\n'
        '    4. Reject and type something\n'
        '    5. No\n';

    final prompt = const TerminalPromptParser().parse(output);
    expect(prompt, isNotNull);
    expect(prompt!.question, 'Apply this change?');
    expect(prompt.options.map((option) => option.label), [
      'Allow once',
      'Allow for this session',
      'Modify with external editor',
      'Reject and type something',
      'No',
    ]);
  });

  test('detects Permission Required prompt with structural fallback', () {
    // Without the 'apply' keyword match, structural detection should still work.
    const output = 'Permission Required\n'
        '\n'
        'Do you want to save this file?\n'
        '\n'
        '  > 1. Yes\n'
        '    2. No\n'
        '    3. Cancel\n';

    final prompt = const TerminalPromptParser().parse(output);
    expect(prompt, isNotNull);
    expect(prompt!.question, 'Do you want to save this file?');
    expect(prompt.options, hasLength(3));
  });
}
