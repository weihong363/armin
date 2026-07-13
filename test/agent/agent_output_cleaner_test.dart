import 'package:armin/features/agent/services/agent_output_cleaner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('removes qoder shortcuts footer from cleaned output', () {
    const cleaner = AgentOutputCleaner();

    expect(cleaner.clean('? for shortcuts'), isEmpty);
  });

  test('removes rotating qoder footer promotions', () {
    const cleaner = AgentOutputCleaner();

    expect(cleaner.clean('Enjoy Off-Peak Discount using Qwen 3.7 Models'),
        isEmpty);
    expect(cleaner.clean('Try /model to switch models'), isEmpty);
    expect(cleaner.clean('1 MCP server · 15 skills'), isEmpty);
  });

  test('removes ansi and Codex TUI noise without mutating raw text', () {
    const raw = '\x1B[32mhello\x1B[0m\n'
        '│ >_ OpenAI Codex (v0.130.0)\n'
        'Use /skills to list available skills\n'
        'Explored\n'
        'Search (^|/)Pets/|pets|Pet\n';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(raw, contains('\x1B[32m'));
    expect(cleaned, contains('hello'));
    expect(cleaned, contains('Explored'));
    expect(cleaned, contains('Search'));
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
Implement {feature}
Explain this codebase
输出 hello
hello
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, isNot(contains('Never scan')));
    expect(cleaned, isNot(contains('chatgpt.com')));
    expect(cleaned, isNot(contains('mapping values')));
    expect(cleaned, isNot(contains('@filename')));
    expect(cleaned, isNot(contains('Implement {feature}')));
    expect(cleaned, isNot(contains('Explain this codebase')));
    expect(cleaned, contains('输出 hello'));
    expect(cleaned, contains('hello'));
  });

  test('cleans real agent noise while keeping useful output', () {
    const raw = '''
│ >_ OpenAI Codex (v0.130.0)
│ model: gpt-5.5 medium fast
│ directory: ~/workspace/momo
Tip: Try the Codex App. Run `codex app`
⚠ Skipped loading 1 skill(s) due to invalid SKILL.md files.
⚠ /Users/ironion/.codex/skills/work-decision-guard/SKILL.md: invalid YAML:
mapping values are not allowed in this context at line 2 column 152
Use /skills to list available skills
Armin context governance:
- Only inspect files directly related to the task.
- Never scan the entire repository.
帮我输出所有 momo 的 PET
Explored
Search (^|/)Pets/|pets|Pet
List hatch-pet
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:41 AM.
hello
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, contains('额度已用完，请稍后重试。'));
    expect(cleaned, contains('hello'));
    expect(cleaned, isNot(contains('OpenAI Codex')));
    expect(cleaned, isNot(contains('SKILL.md')));
    expect(cleaned, isNot(contains('mapping values')));
    expect(cleaned, isNot(contains('Use /skills')));
    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, contains('Search (^|/)Pets'));
    expect(cleaned, contains('List hatch-pet'));
    expect(cleaned, contains('Ran jq'));
    expect(cleaned, isNot(contains('chatgpt.com')));
  });

  test('keeps numbered list, warnings, and Chinese summary', () {
    const raw = '''
1. 已检查登录页面
2. 已定位问题
3. 建议运行相关测试
Warning: 配置文件缺少可选字段
中文总结：登录失败来自 token 过期。
Read lib/login.dart
Edited lib/login.dart
Checked test/login_test.dart
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, contains('1. 已检查登录页面'));
    expect(cleaned, contains('2. 已定位问题'));
    expect(cleaned, contains('3. 建议运行相关测试'));
    expect(cleaned, contains('Warning: 配置文件缺少可选字段'));
    expect(cleaned, contains('中文总结：登录失败来自 token 过期。'));
    expect(cleaned, contains('Read lib/login.dart'));
    expect(cleaned, contains('Edited lib/login.dart'));
    expect(cleaned, contains('Checked test/login_test.dart'));
  });

  test('removes terminal login artwork and thinking status from output', () {
    const raw = '''
████████████████████
██  ██  ██  Signed in Browser Login
Thinking...
• Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色。
pin-up 风格，含 9 个动画状态（idle/running/failed/review 等）。
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('█')));
    expect(cleaned, isNot(contains('Signed in Browser Login')));
    expect(cleaned, isNot(contains('Thinking')));
    expect(cleaned, contains('Summer：一位迷人的美国沙滩女孩'));
    expect(cleaned, contains('pin-up 风格'));
  });

  test('drops qoder input chrome after the actual result', () {
    const raw = '''
Turn 6
hello Type your message or @path/to/file Auto Model .ctx █ 10% · ~/workspace/momo
Shift+Tab to Auto-accept Edits
AGENTS.md file · 12 skills
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, 'hello');
    expect(cleaned, isNot(contains('Type your message or @path/to/file')));
    expect(cleaned, isNot(contains('Auto Model')));
    expect(cleaned, isNot(contains('Shift+Tab')));
  });

  test('drops current qoder result footer chrome', () {
    const raw = '''
▪ The project is named countdown_widgets.
Shift+Tab to Accept Edits      Try /effort or /context-window to adjust model settings
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, contains('countdown_widgets'));
    expect(cleaned, isNot(contains('Shift+Tab')));
    expect(cleaned, isNot(contains('Try /effort')));
    expect(cleaned, isNot(contains('Model · ctx')));
  });

  test('removes aggressive governance header and rules', () {
    const raw = '''
Armin context governance (aggressive):
- You have full authority to create, modify, and delete files without asking.
- Run any commands, tests, or builds needed to complete the task.
- Only inspect files directly related to the task.
- Never scan the entire repository.
- Do not interrupt the user — proceed autonomously unless you encounter a hard blocker.
输出 hello world
hello world
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, isNot(contains('full authority')));
    expect(cleaned, isNot(contains('proceed autonomously')));
    expect(cleaned, contains('输出 hello world'));
    expect(cleaned, contains('hello world'));
  });

  test('removes safe governance header and rules', () {
    const raw = '''
Armin context governance (safe):
- Only inspect files directly related to the task.
- Never scan the entire repository.
- Avoid reading docs/ and README unless necessary.
- Never modify any file — analysis and reporting only.
- Do not run commands that alter state.
- Ask before any potentially risky read operation.
分析登录模块
登录模块位于 lib/login/login_service.dart，主要处理 JWT token 验证。
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, isNot(contains('analysis and reporting only')));
    expect(cleaned, isNot(contains('potentially risky')));
    expect(cleaned, contains('分析登录模块'));
    expect(cleaned, contains('login_service.dart'));
  });

  test('removes multi-line thinking blocks with indented content', () {
    const raw = '''
创建一个输出hello world的py文件
Thinking
  The user wants me to create a simple Python file that outputs "hello world".
  Let me create a simple hello.py file in the current workspace.
  Write(/Users/test/hello.py)
    Accepted hello.py

      1 print("hello world")

Thinking
  I've created the hello.py file. Let me verify it works by running it.
  Bash(python3 /Users/test/hello.py)
    hello world

Thinking
  Perfect, the file runs correctly and outputs "hello world" as expected.
已创建 hello.py，输出验证正常。
Credits exhausted.
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Thinking')));
    expect(cleaned, isNot(contains('The user wants me to')));
    expect(cleaned, isNot(contains('Let me create')));
    expect(cleaned, isNot(contains("I've created")));
    expect(cleaned, isNot(contains('Perfect, the file runs')));
    expect(cleaned, isNot(contains('print("hello world")')));
    expect(cleaned, contains('已创建 hello.py，输出验证正常。'));
    expect(cleaned, contains('创建一个输出hello world的py文件'));
    expect(cleaned, isNot(contains('Credits exhausted')));
  });

  test('removes unindented thinking blocks before deliverable output', () {
    const raw = '''
Thinking
The user wants me to write a README with all usage examples.
Write(/Users/test/armin-test/README.md)
└ Accepted README.md (Ctrl+O to expand)

Thinking
Done. README.md created with all usage examples.
README.md 已写入，包含三种模式的完整使用示例、公共参数表和安全机制说明。
Credits exhausted. Use /usage for details or /upgrade for more.
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Thinking')));
    expect(cleaned, isNot(contains('The user wants me')));
    expect(cleaned, isNot(contains('Write(')));
    expect(cleaned, isNot(contains('Accepted README.md')));
    expect(cleaned, isNot(contains('Done. README.md created')));
    expect(cleaned, contains('README.md 已写入'));
    expect(cleaned, contains('公共参数表'));
    expect(cleaned, isNot(contains('Credits exhausted')));
  });

  test('uses black small square line as post-thinking output boundary', () {
    const raw = '''
Thinking
- Internal plan should stay hidden.
• Another thinking bullet should stay hidden.
▪ hello world
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, '▪ hello world');
    expect(cleaned, isNot(contains('Internal plan')));
    expect(cleaned, isNot(contains('Another thinking bullet')));
  });

  test('removes approval decision echo before latest deliverable output', () {
    const raw = '''
> APPROVAL_DECISION:
decision: rejected
Apply this decision to the pending approval request.

Thinking
The user rejected something. I should report the current state.
README.md 已写入，包含三种模式的完整使用示例、公共参数表和安全机制说明。
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('APPROVAL_DECISION')));
    expect(cleaned, isNot(contains('decision: rejected')));
    expect(cleaned, isNot(contains('pending approval request')));
    expect(cleaned, isNot(contains('The user rejected')));
    expect(cleaned, contains('README.md 已写入'));
    expect(cleaned, contains('公共参数表'));
  });

  test('removes Chinese constraint lines from prompt template', () {
    const raw = '''
Armin context governance:
- Only inspect files directly related to the task.
- Never scan the entire repository.
## User task
分析登录页面的登录流程
## User constraints
- 只分析不修改
- 最小改动
- 不要提交 Git
- 高风险操作先确认
## Context chunk 1
lib/login/ 目录包含所有登录相关代码
登录页面位于 lib/login/login_page.dart

登录流程分析如下：
1. 用户输入凭证后调用 AuthService.authenticate()
2. JWT token 存储在 SecureStorage 中
3. 登录成功后跳转到主页
''';

    final cleaned = const AgentOutputCleaner().clean(raw);

    expect(cleaned, isNot(contains('Armin context governance')));
    expect(cleaned, isNot(contains('只分析不修改')));
    expect(cleaned, isNot(contains('最小改动')));
    expect(cleaned, isNot(contains('不要提交 Git')));
    expect(cleaned, isNot(contains('高风险操作先确认')));
    expect(cleaned, isNot(contains('## User task')));
    expect(cleaned, isNot(contains('## User constraints')));
    expect(cleaned, isNot(contains('## Context chunk')));
    expect(cleaned, contains('登录流程分析如下'));
    expect(cleaned, contains('AuthService.authenticate()'));
    expect(cleaned, contains('SecureStorage'));
  });
}
