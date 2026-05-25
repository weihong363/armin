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
