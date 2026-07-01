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
    expect(slicer.rawCalls, 0);
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
    expect(slicer.rawCalls, 2);
  });

  test('running and attention turns are not deliverable candidates', () {
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
  int rawCalls = 0;
  int cleanedCalls = 0;

  @override
  String rawOutputForTurn(
    List<NativeOutputTurn> turns,
    int index, {
    List<String> extraFilterTexts = const [],
    int? maxOutputChars,
  }) {
    rawCalls += 1;
    return super.rawOutputForTurn(
      turns,
      index,
      extraFilterTexts: extraFilterTexts,
      maxOutputChars: maxOutputChars,
    );
  }

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
