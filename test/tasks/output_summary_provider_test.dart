import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const request = OutputSummaryRequest(
    cleanedOutput: '''
Armin context governance:
- Keep command output short.
Explored
Search pet.json in .
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
帮我输出所有 momo 的 PET
实际的 pets 有 momo、luna、nori。
''',
    status: TaskStatus.turnIdle,
    taskTitle: '帮我输出所有 momo 的 PET',
    agentCommand: 'qodercli',
  );

  test('rule provider extracts important result lines', () async {
    final summary = await const RuleBasedOutputSummaryProvider().summarize(
      request,
    );

    expect(summary.displaySummary, '实际的 pets 有 momo、luna、nori。');
    expect(summary.speechSummary, contains('实际的pets有momo、luna、nori'));
    expect(summary.importantLines, contains('实际的 pets 有 momo、luna、nori。'));
    expect(summary.displaySummary, isNot(contains('Search pet')));
    expect(summary.displaySummary, isNot(contains('Ran jq')));
  });

  test('rule provider removes follow-up prompt echoes from readable output',
      () async {
    const followUp = OutputSummaryRequest(
      cleanedOutput: '''
输出 hello world
hello
''',
      status: TaskStatus.turnIdle,
      taskTitle: '初始任务',
      promptInputs: ['输出 hello world'],
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(followUp);

    expect(summary.displaySummary, 'hello');
    expect(summary.speechSummary, 'hello');
    expect(summary.displaySummary, isNot(contains('输出 hello world')));
  });

  test('rule provider does not speak a prompt when no output exists', () async {
    const echoOnly = OutputSummaryRequest(
      cleanedOutput: '输出 hello world',
      status: TaskStatus.turnIdle,
      promptInputs: ['输出 hello world'],
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(echoOnly);

    expect(summary.displaySummary, isEmpty);
    expect(summary.speechSummary, isEmpty);
  });

  test('rule provider drops turn headers and prompt governance echoes',
      () async {
    const noisyTurn = OutputSummaryRequest(
      cleanedOutput: '''
Do not analyze unrelated architecture.
- Run only targeted tests.
- Keep command output short.

Turn 1
最小改动不要提交Git高风险操作先确认

hello world
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出hello world在一行里面输出',
      promptInputs: ['输出hello world在一行里面输出'],
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(noisyTurn);

    expect(summary.displaySummary, 'hello world');
    expect(summary.speechSummary, 'hello world');
    expect(summary.displaySummary, isNot(contains('Turn 1')));
    expect(summary.displaySummary, isNot(contains('最小改动')));
  });

  test('rule provider strips governance prefix but keeps the actual result',
      () async {
    const noisyPrefix = OutputSummaryRequest(
      cleanedOutput: '最小改动不要提交 Git 高风险操作先确认 HELLO WORLD',
      status: TaskStatus.turnIdle,
      taskTitle: '输出hello world在一行里面输出',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(noisyPrefix);

    expect(summary.displaySummary, 'HELLO WORLD');
    expect(summary.speechSummary, 'HELLO WORLD');
    expect(summary.displaySummary, isNot(contains('最小改动')));
    expect(summary.displaySummary, isNot(contains('不要提交')));
    expect(summary.displaySummary, isNot(contains('高风险操作先确认')));
  });

  test('rule provider removes qoder input chrome after the result', () async {
    const qoderChrome = OutputSummaryRequest(
      cleanedOutput: '''
Turn 6
hello Type your message or @path/to/file Auto Model .ctx █ 10% · ~/workspace/momo
Shift+Tab to Auto-accept Edits
AGENTS.md file · 12 skills
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出hello',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(qoderChrome);

    expect(summary.displaySummary, 'hello');
    expect(summary.speechSummary, 'hello');
    expect(summary.displaySummary,
        isNot(contains('Type your message or @path/to/file')));
    expect(summary.displaySummary, isNot(contains('Auto Model')));
  });

  test('rule provider strips completion handshake eof noise', () async {
    const handshakeNoise = OutputSummaryRequest(
      cleanedOutput: '''
completion: tls handshake eof
runbook-copilot 是面向工程团队的 RAG 事故排障助手，用于根据告警、服务名、日志和症状检索知识库并生成带引用的排障建议。
''',
      status: TaskStatus.turnIdle,
      taskTitle: '检查输出',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(handshakeNoise);

    expect(summary.displaySummary, isNot(contains('tls handshake eof')));
    expect(summary.displaySummary, contains('runbook-copilot'));
  });

  test(
      'rule provider preserves description when animation names contain failed',
      () async {
    const descriptiveResult = OutputSummaryRequest(
      cleanedOutput: '''
Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色、海军蓝比基尼、自信活力的
pin-up 风格，含 9 个动画状态（idle/running/waving/jumping/failed/waiting/review
等），15361872 精灵图集，192208 像素格。
''',
      status: TaskStatus.turnIdle,
    );

    final summary = await const RuleBasedOutputSummaryProvider()
        .summarize(descriptiveResult);

    expect(summary.displaySummary, startsWith('Summer：一位迷人的美国沙滩女孩'));
    expect(summary.displaySummary, contains('pin-up 风格，含 9 个动画状态'));
    expect(summary.displaySummary, contains('failed/waiting/review'));
    expect(summary.displaySummary, contains('15361872 精灵图集'));
  });

  test('rule provider summarizes long turn output by core result not prefix',
      () async {
    final longOutput = OutputSummaryRequest(
      cleanedOutput: '''
我先看一下仓库里宠物资源的目录和命名方式，然后直接把现有 pet 名称列出来。
Explored
Search (^|/)Pets|pets|Pet in .
继续从项目结构和资源引用里找实际资源目录。
${List.generate(20, (index) => '过程记录 $index：检查了一个低价值路径，没有形成最终结果。').join('\n')}
结论：实际存在的 PET 包括 momo、luna、nori、Summer。
Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色、海军蓝比基尼、自信活力的 pin-up 风格，含 9 个动画状态（idle/running/waving/jumping/failed/waiting/review 等），1536×1872 精灵图集，192×208 像素格。
''',
      status: TaskStatus.turnIdle,
      taskTitle: '帮我输出所有 momo 的 PET',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(longOutput);

    expect(summary.displaySummary, contains('实际存在的 PET 包括'));
    expect(summary.displaySummary, contains('Summer：一位迷人的美国沙滩女孩'));
    expect(summary.displaySummary, contains('9 个动画状态'));
    expect(summary.displaySummary, contains('192×208 像素格'));
    expect(summary.displaySummary, isNot(startsWith('我先看一下仓库')));
    expect(summary.displaySummary, isNot(contains('过程记录 0')));
  });

  test('rule provider joins wrapped natural-language result lines', () async {
    const wrapped = OutputSummaryRequest(
      cleanedOutput: '''
Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕
肤、海军蓝比基尼、像素风格、厚轮廓线、赛璐璐平涂，9 行精灵图
（idle/running/waving/jumping/failed/waiting/review 等），192×208 像素格。
''',
      status: TaskStatus.turnIdle,
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(wrapped);

    expect(summary.displaySummary, startsWith('Summer：一位迷人的美国沙滩女孩'));
    expect(summary.displaySummary, contains('192×208 像素格'));
    expect(summary.displaySummary, isNot(startsWith('肤、海军蓝')));
  });

  test('rule provider extracts pet description from raw tool context',
      () async {
    const toolTrace = OutputSummaryRequest(
      cleanedOutput: '''
> Glob('.hatch-pet-runs/taro/**/*.json') ■ Glob('.hatch-pet-runs/taro/**/*.md')
Glob('output/hatch-pet/taro/**/*.json') ■ Read(/Users/ironion/workspace/momo/output/hatch-pet/taro/pet_request.json) ■ TARO 是 一 只 小型疲惫兔子开发者桌面宠物，灰奶油色调像素风格（厚轮廓线、赛璐璐平涂），9 行精灵图（idle/running-right/running-left/waving/jumping/failed/waiting/running/review），192×208 帧尺寸。
Shift+Tab to Auto-accept Edits
''',
      status: TaskStatus.turnIdle,
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(toolTrace);

    expect(summary.displaySummary, startsWith('Taro是一只小型疲惫兔子'));
    expect(summary.displaySummary, contains('192×208 帧尺寸'));
    expect(summary.displaySummary, isNot(contains('Glob(')));
    expect(summary.displaySummary, isNot(contains('Read(')));
    expect(summary.displaySummary, isNot(contains('Shift+Tab')));
  });

  test('rule provider strips constraints and thinking traces dynamically',
      () async {
    const noisy = OutputSummaryRequest(
      cleanedOutput: '''
User constraints 最小改动 不要提交Git 高风险操作先确认
Thinking
Grep('SUMMER' within ./)
Thinking Grep('summer' within ./) Thinking
Summer 是一个 Codex桌面宠物（pixel-art风格），角色设定为一位活力四射的美国海滩女孩吉祥物，拥有9种动画状态（idle、running、waving、jumping等），采用192×208像素网格、#00FF00 chroma-key背景。
''',
      status: TaskStatus.turnIdle,
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(noisy);

    expect(summary.displaySummary, startsWith('Summer 是一个 Codex桌面宠物'));
    expect(summary.displaySummary, contains('192×208像素网格'));
    expect(summary.displaySummary, isNot(contains('User constraints')));
    expect(summary.displaySummary, isNot(contains('Thinking')));
    expect(summary.displaySummary, isNot(contains('Grep(')));
  });

  test('rule provider removes meta narration prefixes before results',
      () async {
    const metaNarration = OutputSummaryRequest(
      cleanedOutput: '''
Let me find relevant test files for interruption testing.
No direct interruption test files found.
Q: 你想执行哪个中断测试？
测试目标 -> 运行 test_hello_world
执行 test_hello_world.py
HELLO WORLD
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出hello world',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(metaNarration);

    expect(summary.displaySummary, contains('HELLO WORLD'));
    expect(summary.displaySummary, isNot(contains('Let me find relevant')));
    expect(summary.displaySummary, isNot(contains('Q:')));
    expect(summary.displaySummary, isNot(contains('No direct interruption')));
  });

  test('rule provider removes interactive approval transcript from results',
      () async {
    const interactive = OutputSummaryRequest(
      cleanedOutput: '''
Tool: Bash
Run test_hello_world.py with verbose output
Command: cd /Users/ironion/workspace/runbook-copilot &&
python -m pytest tests/test_hello_world.py -v 2>&1 | head -30
Allow this command to run? Redirection detected.
1. Allow once
2. Always allow this exact command for future sessions
3. Reject and type something
4. No
HELLO WORLD
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出 HELLO WORLD',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(interactive);

    expect(summary.displaySummary, 'HELLO WORLD');
    expect(summary.displaySummary, isNot(contains('Allow this command')));
    expect(summary.displaySummary, isNot(contains('Command:')));
    expect(summary.displaySummary, isNot(contains('Allow once')));
  });

  test('rule provider removes dynamic asking-user transcript from results',
      () async {
    const interactive = OutputSummaryRequest(
      cleanedOutput: '''
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
HELLO WORLD
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出 HELLO WORLD',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(interactive);

    expect(summary.displaySummary, 'HELLO WORLD');
    expect(summary.displaySummary, isNot(contains('Asking User')));
    expect(summary.displaySummary, isNot(contains('Ralph Loop')));
    expect(summary.displaySummary, isNot(contains('Type Something')));
  });

  test('rule provider excludes terminal chrome from visible result', () async {
    const terminalSnapshot = OutputSummaryRequest(
      cleanedOutput: '''
████████████████████
██  ██  ██  Signed in Browser Login
Thinking...
Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色、海军蓝比基尼、自信活力的
pin-up 风格，含 9 个动画状态（idle/running/waving/jumping/failed/waiting/review
等），1536 x 1872 精灵图集，192 x 208 像素格。
''',
      status: TaskStatus.turnIdle,
    );

    final summary = await const RuleBasedOutputSummaryProvider()
        .summarize(terminalSnapshot);

    expect(summary.displaySummary, startsWith('Summer：一位迷人的美国沙滩女孩'));
    expect(summary.displaySummary, contains('192 x 208 像素格'));
    expect(summary.displaySummary, isNot(contains('Signed in Browser Login')));
    expect(summary.displaySummary, isNot(contains('Thinking')));
    expect(summary.displaySummary, isNot(contains('█')));
  });

  test('rule provider summarizes structured table results', () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
当前测试模块：你想测试哪个模块？

| 模块 | 测试文件 |
| --- | --- |
| 答案生成 | test_answer_generator.py |
| API 调试 | test_api_debug.py |
| 文档分块 | test_chunking.py |
| 配置 | test_config.py |
| 嵌入向量 | test_embedding_provider.py |
| 评估 | test_evaluation.py |
| 工厂模式 | test_factory.py |
| Grafana 适配器 | test_grafana_adapter.py |
| 知识库 lint | test_knowledge_lint.py |
| 日志解析 | test_log_parser.py |
| Loop API | test_loop_api.py |
| Loop 存储 | test_loop_storage.py |
| 可观测性适配器 | test_observability_adapters.py |
| 值班循环运行时 | test_oncall_loop_runtime.py |
| 产品化 | test_productization.py |
| Ralph Loop 跟进 | test_ralph_loop_followup.py |
| 检索 | test_retrieval.py |
| Schema | test_schema.py |

你想测试哪个模块？
''',
      status: TaskStatus.turnIdle,
      taskTitle: '你想测试哪个模块？',
      promptInputs: ['你想测试哪个模块？'],
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(summary.displaySummary, startsWith('结构化结果如下：共 18 个测试文件'));
    expect(summary.displaySummary, contains('test_answer_generator.py'));
    expect(summary.displaySummary, contains('test_observability_adapters.py'));
    expect(summary.displaySummary, contains('test_schema.py'));
    expect(RegExp(r'test_[A-Za-z0-9_]+\.py').allMatches(summary.displaySummary),
        hasLength(18));
    expect(summary.displaySummary, isNot(contains('|')));
    expect(summary.displaySummary, isNot(contains('当前测试模块')));
    expect(summary.displaySummary, isNot(endsWith('你想测试哪个模块？')));
  });

  test('rule provider summarizes unicode box table results', () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
▪ 核心测试文件汇总如下：
   ┌───────────────────────────┬──────┬────────────────────────────┬─────────────────┐
   │ 测试文件                  │ 用例 │ 覆盖模块                   │ 核心职责        │
   │                           │ 数   │                            │                 │
   ├───────────────────────────┼──────┼────────────────────────────┼─────────────────┤
   │ test_chunking.py          │ 3    │ app/rag/chunking           │ Markdown        │
   │                           │      │                            │ 分块策略        │
   │ test_retrieval.py         │ 7    │ app/rag/retriever          │ RAG 检索与引用  │
   │ test_answer_generator.py  │ 5    │ app/llm/answer_generator   │ 答案生成与引用  │
   │                           │      │                            │ 绑定            │
   │ test_schema.py            │ 6    │ app/models/schemas         │ Pydantic        │
   │                           │      │                            │ 模型校验        │
   │ test_log_parser.py        │ 4    │ app/services/log_parser    │ 日志结构化解析  │
   │ test_grafana_adapter.py   │ 5    │ app/services/grafana_adapt │ Grafana         │
   │                           │      │ er                         │ 数据源适配      │
   │ test_observability_adapte │ 8    │ app/services/evidence_prov │ 可观测性证据采  │
   │ rs.py                     │      │ iders                      │ 集              │
   │ test_loop_storage.py      │ 15   │ app/services/loop_storage  │ Loop 会话持久化 │
   │ test_oncall_loop_runtime. │ 12   │ app/services/oncall_loop_r │ Ralph Loop      │
   │ py                        │      │ untime                     │ 诊断循环        │
   │ test_productization.py    │ 7    │ 多模块                     │ 产品化集成验收  │
   └───────────────────────────┴──────┴────────────────────────────┴─────────────────┘

✓ Update successful! The new version will be used on your next run.
''',
      status: TaskStatus.turnIdle,
      taskTitle: '让显示所有测试文件',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(summary.displaySummary, startsWith('核心测试文件汇总如下：共 10 个测试文件'));
    expect(summary.displaySummary, contains('test_chunking.py'));
    expect(summary.displaySummary, contains('test_answer_generator.py'));
    expect(summary.displaySummary, contains('test_loop_storage.py'));
    expect(summary.displaySummary, contains('test_observability_adapters.py'));
    expect(summary.displaySummary, contains('test_oncall_loop_runtime.py'));
    expect(summary.displaySummary, isNot(contains('│')));
    expect(summary.displaySummary, isNot(contains('┌')));
    expect(summary.displaySummary, isNot(contains('Update successful')));
  });

  test('rule provider summarizes generic table results', () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
检查结果如下：
| 模块 | 状态 | 说明 |
| --- | --- | --- |
| API | 通过 | 3 个接口可用 |
| 数据库 | 失败 | 连接超时 |
''',
      status: TaskStatus.turnIdle,
      taskTitle: '检查系统状态',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(
        summary.displaySummary, '检查结果如下：共 2 行，分别是：API，通过，3 个接口可用；数据库，失败，连接超时。');
    expect(summary.speechSummary, contains('API'));
    expect(summary.displaySummary, isNot(contains('|')));
    expect(summary.displaySummary, isNot(contains('---')));
  });

  test('rule provider merges wrapped table cells before summarizing', () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
核心模块清单如下：
┌──────────────┬────────────────────────────────┬──────────────────────────────┐
│ 模块         │ 路径                           │ 职责                         │
├──────────────┼────────────────────────────────┼──────────────────────────────┤
│ 核心配       │ app/core/                      │ 应用配置（config.py）、数据库连接 │
│ 置           │                                │ （database.py）               │
│ 事故分       │ app/services/incident_analyzer │ 事故诊断分析                  │
│ 析           │ .py                            │                              │
│ Runbook      │ app/services/runbook_matcher.p │ Runbook 知识检索与匹配        │
│ 匹配         │ y                              │                              │
│ Evidence     │ app/services/evidence_provider │ 可观测性证据采集：Prometheus  │
│ Providers    │ s/                             │ 指标、Tempo 追踪、Loki 日志   │
└──────────────┴────────────────────────────────┴──────────────────────────────┘
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出核心模块清单',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(summary.displaySummary,
        contains('核心配置：app/core/，应用配置（config.py）、数据库连接（database.py）'));
    expect(summary.displaySummary,
        contains('事故分析：app/services/incident_analyzer.py，事故诊断分析'));
    expect(summary.displaySummary,
        contains('Runbook匹配：app/services/runbook_matcher.py，Runbook 知识检索与匹配'));
    expect(
        summary.displaySummary,
        contains(
            'Evidence Providers：app/services/evidence_providers/，可观测性证据采集：Prometheus指标、Tempo 追踪、Loki 日志'));
    expect(summary.displaySummary,
        isNot(contains('app/services/runbook_matcher.p，Runbook')));
    expect(summary.displaySummary, isNot(contains('│')));
  });

  test('rule provider merges single-cell wrapped table labels', () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
核心模块清单如下：
┌────────────┬──────────────────────────────┬──────────────────────┐
│ 模块       │ 路径                         │ 职责                 │
├────────────┼──────────────────────────────┼──────────────────────┤
│ 事故存     │ app/services/incident_store.py │ 事故持久化（SQLite） │
│ 储         │                              │                      │
│ Loop       │ app/services/loop_storage.py │ Loop 会话持久化      │
│ 存储       │                              │                      │
│ 应用入     │ app/main.py                  │ FastAPI 应用创建与启动 │
│ 口         │                              │                      │
└────────────┴──────────────────────────────┴──────────────────────┘
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出核心模块清单',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(summary.displaySummary,
        contains('事故存储：app/services/incident_store.py，事故持久化（SQLite）'));
    expect(summary.displaySummary,
        contains('Loop存储：app/services/loop_storage.py，Loop 会话持久化'));
    expect(
        summary.displaySummary, contains('应用入口：app/main.py，FastAPI 应用创建与启动'));
    expect(summary.displaySummary, isNot(contains('事故存：')));
    expect(summary.displaySummary, isNot(contains('应用入：')));
  });

  test('rule provider merges right-column wrapped table descriptions',
      () async {
    const tableOutput = OutputSummaryRequest(
      cleanedOutput: '''
核心模块清单如下：
┌────────────┬──────────┬──────────────────────────────────────┐
│ 模块       │ 路径     │ 职责                                 │
├────────────┼──────────┼──────────────────────────────────────┤
│ RAG        │ app/rag/ │ 知识库分块（chunking）、向量化       │
│ 引擎       │          │ （embedding）、BM25                  │
│            │          │ 检索、向量存储、检索器、ingestion、 │
│            │          │ 知识库 lint                          │
│ LLM        │ app/llm/ │ Prompt 模板（prompts）、答案生成     │
│ 生成       │          │ （answer_generator）、Grounded 答案  │
│            │          │ （grounded_answer）                  │
│ 评估       │ app/evaluation/ │ RAG 评估（evaluate.py）、Loop 评估 │
│            │          │ （evaluate_loop.py）                 │
└────────────┴──────────┴──────────────────────────────────────┘
''',
      status: TaskStatus.turnIdle,
      taskTitle: '输出核心模块清单',
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(tableOutput);

    expect(
        summary.displaySummary,
        contains(
            'RAG引擎：app/rag/，知识库分块（chunking）、向量化（embedding）、BM25检索、向量存储、检索器、ingestion、知识库 lint'));
    expect(
        summary.displaySummary,
        contains(
            'LLM生成：app/llm/，Prompt 模板（prompts）、答案生成（answer_generator）、Grounded 答案（grounded_answer）'));
    expect(
        summary.displaySummary,
        contains(
            '评估：app/evaluation/，RAG 评估（evaluate.py）、Loop 评估（evaluate_loop.py）'));
    expect(summary.displaySummary, isNot(contains('BM25；')));
    expect(summary.displaySummary, isNot(contains('│')));
  });

  test('local model provider falls back when unavailable', () async {
    final summary = await const LocalSmallModelSummaryProvider().summarize(
      request,
    );

    expect(summary.displaySummary, '实际的 pets 有 momo、luna、nori。');
    expect(summary.fallbackReason, 'local small model unavailable');
  });

  test('local model provider falls back on timeout', () async {
    final provider = LocalSmallModelSummaryProvider(
      timeout: const Duration(milliseconds: 1),
      runner: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const OutputSummary(
          displaySummary: 'model summary',
          speechSummary: 'model summary',
        );
      },
    );

    final summary = await provider.summarize(request);

    expect(summary.displaySummary, '实际的 pets 有 momo、luna、nori。');
    expect(summary.fallbackReason, startsWith('local small model failed:'));
  });

  test('local model capability detects unsupported device and falls back',
      () async {
    final provider = LocalSmallModelSummaryProvider(
      availabilityCheck: () async => false,
      runner: (_) async => const OutputSummary(
        displaySummary: 'model summary',
        speechSummary: 'model summary',
      ),
    );

    final capability = await provider.capability();
    final summary = await provider.summarize(request);

    expect(capability.available, isFalse);
    expect(capability.message, contains('不支持'));
    expect(summary.displaySummary, '实际的 pets 有 momo、luna、nori。');
    expect(summary.fallbackReason, 'local small model not supported');
  });

  test('selectable provider switches to safe local model summary', () async {
    final provider = SelectableOutputSummaryProvider(
      localModel: LocalSmallModelSummaryProvider(
        runner: (_) async => const OutputSummary(
          displaySummary: '已完成处理。password=hunter2',
          speechSummary: '已完成处理。token=secret-token',
        ),
      ),
    );

    final ruleSummary = await provider.summarize(request);
    provider.setPreferLocalModel(true);
    final modelSummary = await provider.summarize(request);

    expect(ruleSummary.displaySummary, '实际的 pets 有 momo、luna、nori。');
    expect(modelSummary.displaySummary, contains('password=[REDACTED]'));
    expect(modelSummary.displaySummary, isNot(contains('hunter2')));
    expect(modelSummary.speechSummary, contains('token=[REDACTED]'));
    expect(modelSummary.speechSummary, isNot(contains('secret-token')));
  });

  test('selectable provider keeps structured tables on rule summary', () async {
    final provider = SelectableOutputSummaryProvider(
      localModel: LocalSmallModelSummaryProvider(
        runner: (_) async => const OutputSummary(
          displaySummary: '''
│ 测试文件 │ 用例 │
│ test_chunking.py │ 3 │
│ test_retrieval.py │ 7 │
''',
          speechSummary: '竖线 测试文件 竖线 用例',
        ),
      ),
    )..setPreferLocalModel(true);

    final summary = await provider.summarize(
      const OutputSummaryRequest(
        cleanedOutput: '''
核心测试文件汇总如下：
│ 测试文件 │ 用例 │
│ test_chunking.py │ 3 │
│ test_retrieval.py │ 7 │
''',
        status: TaskStatus.turnIdle,
        taskTitle: '显示所有测试文件',
      ),
    );

    expect(summary.displaySummary,
        '核心测试文件汇总如下：共 2 个测试文件，包括 test_chunking.py、test_retrieval.py。');
    expect(summary.speechSummary, contains('共2个测试文件'));
    expect(summary.displaySummary, isNot(contains('│')));
  });

  test('local model never receives unredacted task output or prompt text',
      () async {
    OutputSummaryRequest? receivedRequest;
    final provider = LocalSmallModelSummaryProvider(
      runner: (modelRequest) async {
        receivedRequest = modelRequest;
        return const OutputSummary(
          displaySummary: '摘要完成。',
          speechSummary: '摘要完成。',
        );
      },
    );

    await provider.summarize(
      const OutputSummaryRequest(
        cleanedOutput: '已连接 password=hunter2 token=secret-token',
        status: TaskStatus.turnIdle,
        taskTitle: '检查 api_key=private-key',
        promptInputs: [
          '使用 cookie=session-value',
          '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
        ],
        agentCommand: 'qodercli access_key=machine-token',
      ),
    );

    final modelInput = receivedRequest!;
    expect(modelInput.cleanedOutput, contains('password=[REDACTED]'));
    expect(modelInput.cleanedOutput, contains('token=[REDACTED]'));
    expect(modelInput.taskTitle, contains('api_key=[REDACTED]'));
    expect(modelInput.promptInputs.first, contains('cookie=[REDACTED]'));
    expect(modelInput.promptInputs.last, '[REDACTED_PRIVATE_KEY]');
    expect(modelInput.agentCommand, contains('access_key=[REDACTED]'));
    expect(modelInput.cleanedOutput, isNot(contains('hunter2')));
    expect(modelInput.promptInputs, isNot(contains('session-value')));
  });

  test('local model fallback receives a redacted request', () async {
    OutputSummaryRequest? fallbackRequest;
    final provider = LocalSmallModelSummaryProvider(
      fallback: _CapturingSummaryProvider(
        onSummarize: (safeRequest) {
          fallbackRequest = safeRequest;
          return const OutputSummary(
            displaySummary: '规则摘要。',
            speechSummary: '规则摘要。',
          );
        },
      ),
    );

    await provider.summarize(
      const OutputSummaryRequest(
        cleanedOutput: 'password=hunter2',
        status: TaskStatus.turnIdle,
      ),
    );

    expect(fallbackRequest!.cleanedOutput, 'password=[REDACTED]');
  });

  test('rule summary redacts secrets before display and speech', () async {
    const sensitive = OutputSummaryRequest(
      cleanedOutput: '已连接成功，password=hunter2 token=secret-token。',
      status: TaskStatus.turnIdle,
    );

    final summary =
        await const RuleBasedOutputSummaryProvider().summarize(sensitive);

    expect(summary.displaySummary, contains('password=[REDACTED]'));
    expect(summary.displaySummary, contains('token=[REDACTED]'));
    expect(summary.speechSummary, isNot(contains('hunter2')));
    expect(summary.speechSummary, isNot(contains('secret-token')));
  });

  test('speech summary excludes raw terminal noise', () async {
    const noisy = OutputSummaryRequest(
      cleanedOutput: '''
│ >_ OpenAI Codex (v0.130.0)
Use /skills to list available skills
⚠ Skipped loading 1 skill(s) due to invalid SKILL.md files.
/Users/ironion/.codex/skills/work-decision-guard/SKILL.md: invalid YAML
You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro).
已找到 SUMMER。
''',
      status: TaskStatus.failed,
      taskTitle: '检查 SUMMER',
    );

    final summary = await const RuleBasedOutputSummaryProvider().summarize(
      noisy,
    );

    expect(summary.speechSummary, contains('重试'));
    expect(summary.speechSummary, contains('已找到SUMMER'));
    expect(summary.speechSummary, isNot(contains('SKILL.md')));
    expect(summary.speechSummary, isNot(contains('/Users/ironion')));
    expect(summary.speechSummary, isNot(contains('Use /skills')));
  });
}

class _CapturingSummaryProvider implements OutputSummaryProvider {
  const _CapturingSummaryProvider({required this.onSummarize});

  final OutputSummary Function(OutputSummaryRequest request) onSummarize;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    return onSummarize(request);
  }
}
