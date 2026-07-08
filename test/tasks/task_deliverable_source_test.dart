import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
import 'package:armin/features/tasks/services/task_deliverable_source.dart';
import 'package:armin/features/tasks/services/turn_output_slicer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('candidate lookup is lightweight and does not slice output', () {
    final now = DateTime(2026, 6, 18);
    final turns = List.generate(
      20,
      (index) => _turn(
        id: 'turn-$index',
        index: index + 1,
        input: '执行 $index',
        output: 'large-output\n' * 500,
        now: now,
      ),
    );
    final slicer = _CountingTurnOutputSlicer();
    final source = TaskDeliverableSource(turnOutputSlicer: slicer);

    expect(source.latestCandidate(turns)?.turn.id, 'turn-19');
    expect(source.candidateCount(turns), 20);
    expect(source.candidates(turns, limit: 3), hasLength(3));
    expect(slicer.cleanedCalls, 0);
  });

  test('resolved deliverable summarizes evidence only when requested',
      () async {
    final now = DateTime(2026, 6, 18);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '输出旧结果',
        output: '旧结果',
        now: now,
      ),
      _turn(
        id: 'turn-2',
        index: 2,
        input: '继续',
        output: '''
输出旧结果
旧结果
继续
新结果
''',
        now: now,
      ),
    ];
    final slicer = _CountingTurnOutputSlicer();
    final source = TaskDeliverableSource(turnOutputSlicer: slicer);
    final candidate = source.latestCandidate(turns)!;
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: '新结果摘要',
        speechSummary: '新结果语音摘要',
      ),
    );

    final evidence = source.evidenceFor(turns, candidate);
    final resolved = await source.resolve(
      turns,
      candidate,
      provider: provider,
      context: const DeliverableResolveContext(
        status: TaskStatus.turnIdle,
        taskTitle: 'Task',
        agentCommand: 'codex',
      ),
    );

    expect(evidence?.text, '新结果');
    expect(provider.lastRequest?.cleanedOutput, '新结果');
    expect(resolved?.displaySummary, '新结果摘要');
    expect(resolved?.speechSummary, '新结果语音摘要');
    expect(resolved?.provenance.turnId, 'turn-2');
    expect(slicer.cleanedCalls, 2);
  });

  test('deliverable evidence prefers cleaned output over raw terminal log',
      () async {
    final now = DateTime(2026, 7, 7);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: 'Read project',
        rawOutput: '''
Armin context governance:
## User task
Read project
▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines
▪ ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT
''',
        cleanedOutput:
            'ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];
    const source = TaskDeliverableSource();
    final candidate = source.latestCandidate(turns)!;
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'clean summary',
        speechSummary: 'clean speech',
      ),
    );

    await source.resolve(
      turns,
      candidate,
      provider: provider,
      context: const DeliverableResolveContext(
        status: TaskStatus.turnIdle,
        taskTitle: 'Task',
        agentCommand: 'qodercli',
      ),
    );

    expect(provider.lastRequest?.cleanedOutput,
        'ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT');
    expect(provider.lastRequest?.cleanedOutput, isNot(contains('User task')));
    expect(provider.lastRequest?.cleanedOutput, isNot(contains('Read(')));
  });

  test('deliverable evidence does not fall back to raw terminal output',
      () async {
    final now = DateTime(2026, 7, 7);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '确认 stats',
        rawOutput: '''
确认 stats
Thinking
 │ Everything is already in place and working.
▪ GET /stats/{code} 已经实现了，3 个相关测试全部通过。
''',
        cleanedOutput: '这个已经在上一轮实现了。让我确认一下当前代码状态。',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];
    const source = TaskDeliverableSource();
    final candidate = source.latestCandidate(turns)!;
    final resolved = await source.resolve(
      turns,
      candidate,
      provider: _CapturingSummaryProvider(
        const OutputSummary(
          displaySummary: 'stats summary',
          speechSummary: 'stats speech',
        ),
      ),
      context: const DeliverableResolveContext(
        status: TaskStatus.turnIdle,
        taskTitle: 'Task',
        agentCommand: 'qodercli',
      ),
    );

    expect(resolved, isNull);
  });

  test('attention turn with final evidence can become deliverable candidate',
      () {
    final now = DateTime(2026, 7, 8);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '输出项目简介',
        output: 'ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT',
        now: now,
        status: NativeOutputTurnStatus.needAttention,
      ),
    ];
    const source = TaskDeliverableSource();

    expect(source.latestCandidate(turns)?.turn.id, 'turn-1');
    expect(source.candidateCount(turns), 1);
    expect(source.evidenceFor(turns, source.latestCandidate(turns)!)?.text,
        contains('ARMIN_LOOP_LONG_D1'));
  });

  test('running and pure attention turns are not deliverable candidates', () {
    final now = DateTime(2026, 6, 18);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '执行任务',
        output: '仍在执行',
        now: now,
        status: NativeOutputTurnStatus.running,
      ),
      _turn(
        id: 'turn-2',
        index: 2,
        input: '继续',
        output: '需要用户处理',
        now: now,
        status: NativeOutputTurnStatus.needAttention,
      ),
    ];
    const source = TaskDeliverableSource();

    expect(source.latestCandidate(turns), isNull);
    expect(source.candidateCount(turns), 0);
    expect(source.candidates(turns, limit: turns.length), isEmpty);
  });

  test('attention prompt echo marker is not a deliverable candidate', () {
    final now = DateTime(2026, 6, 18);
    const prompt = '''
Read pubspec.yaml. Final answer must include:
ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT
''';
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: prompt,
        output: '''
ARMIN_DIAG: monitor_version=phase2.6-settled-v8
## User task
Read pubspec.yaml. Final answer must include:
ARMIN_LOOP_LONG_D1 status=PASS files_changed=0 next=WAIT
▪ Let me read the pubspec.yaml file.
''',
        now: now,
        status: NativeOutputTurnStatus.needAttention,
      ),
    ];
    const source = TaskDeliverableSource();

    expect(source.latestCandidate(turns), isNull);
    expect(source.candidateCount(turns), 0);
  });
}

class _CapturingSummaryProvider implements OutputSummaryProvider {
  _CapturingSummaryProvider(this.summary);

  final OutputSummary summary;
  OutputSummaryRequest? lastRequest;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    lastRequest = request;
    return summary;
  }
}

class _CountingTurnOutputSlicer extends TurnOutputSlicer {
  int cleanedCalls = 0;

  @override
  String outputForTurn(
    List<NativeOutputTurn> turns,
    int index, {
    List<String> extraFilterTexts = const [],
    int? maxOutputChars,
  }) {
    cleanedCalls += 1;
    return super.outputForTurn(
      turns,
      index,
      extraFilterTexts: extraFilterTexts,
      maxOutputChars: maxOutputChars,
    );
  }
}

NativeOutputTurn _turn({
  required String id,
  required int index,
  required String input,
  required String output,
  required DateTime now,
  NativeOutputTurnStatus status = NativeOutputTurnStatus.turnIdle,
}) {
  return NativeOutputTurn(
    id: id,
    taskId: 'task-1',
    turnIndex: index,
    userInput: input,
    rawOutput: output,
    cleanedOutput: output,
    startedAt: now,
    lastOutputAt: now,
    status: status,
  );
}
