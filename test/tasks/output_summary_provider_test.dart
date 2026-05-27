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
    expect(summary.speechSummary, contains('实际的 pets 有 momo、luna、nori'));
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

    expect(summary.speechSummary, contains('额度已用完，请稍后重试'));
    expect(summary.speechSummary, contains('已找到 SUMMER'));
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
