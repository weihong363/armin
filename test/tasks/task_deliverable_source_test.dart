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

  test('resolved deliverable stores loop outcome outside visible summary',
      () async {
    final now = DateTime(2026, 7, 13);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '读取项目名',
        output: '''
项目名为：countdown_widgets
ARMIN_LOOP_OUTCOME_BEGIN
state=CONTINUE
next_action=运行最小测试
acceptance=UNKNOWN
ARMIN_LOOP_OUTCOME_END
''',
        now: now,
      ),
    ];
    const source = TaskDeliverableSource();
    final candidate = source.latestCandidate(turns)!;
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: '项目名为：countdown_widgets',
        speechSummary: '项目名为：countdown_widgets',
      ),
    );

    final resolved = await source.resolve(
      turns,
      candidate,
      provider: provider,
      context: const DeliverableResolveContext(
        status: TaskStatus.turnIdle,
        taskTitle: '读取项目名',
        agentCommand: 'qodercli',
      ),
    );

    expect(provider.lastRequest?.cleanedOutput, '项目名为：countdown_widgets');
    expect(resolved?.displaySummary, '项目名为：countdown_widgets');
    expect(resolved?.loopState, 'continueWork');
    expect(resolved?.loopNextAction, '运行最小测试');
  });

  test('loop outcome can be recovered from the same turn raw event', () async {
    final now = DateTime(2026, 7, 13);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '读取项目名',
        rawOutput: '''
▪ 项目名为：countdown_widgets
ARMIN_LOOP_OUTCOME_BEGIN
state=CONTINUE
next_action=读取导出文件
acceptance=PASS
ARMIN_LOOP_OUTCOME_END
''',
        cleanedOutput: '▪ 项目名为：countdown_widgets',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];
    const source = TaskDeliverableSource();
    final resolved = await source.resolve(
      turns,
      source.latestCandidate(turns)!,
      provider: _CapturingSummaryProvider(
        const OutputSummary(
          displaySummary: '项目名为：countdown_widgets',
          speechSummary: '项目名为：countdown_widgets',
        ),
      ),
      context: const DeliverableResolveContext(
        status: TaskStatus.turnIdle,
        taskTitle: '读取项目名',
        agentCommand: 'qodercli',
      ),
    );

    expect(resolved?.displaySummary, '项目名为：countdown_widgets');
    expect(resolved?.loopState, 'continueWork');
    expect(resolved?.loopNextAction, '读取导出文件');
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

  test('loop protocol prompt echo is not deliverable evidence', () {
    final now = DateTime(2026, 7, 13);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '读取项目名',
        output: '''
> Armin context governance:
## Armin Loop Runtime Protocol
ARMIN_LOOP_OUTCOME_BEGIN
state=DONE | CONTINUE | BLOCKED
next_action=下一步具体动作
ARMIN_LOOP_OUTCOME_END
x You've reached your credit usage limit. Please upgrade your subscription plan.
''',
        now: now,
        status: NativeOutputTurnStatus.needAttention,
      ),
    ];
    const source = TaskDeliverableSource();

    expect(source.latestCandidate(turns), isNull);
  });

  test(
      'attention qoder final marker after agent output is deliverable evidence',
      () {
    final now = DateTime(2026, 7, 9);
    const prompt = '''
Read pubspec.yaml. Final answer must include:
ARMIN_REAL_QODER_REGRESSION_D1 status=PASS files_changed=0 next=WAIT
''';
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: prompt,
        output: '''
> Read pubspec.yaml. Final answer must include:
  ARMIN_REAL_QODER_REGRESSION_D1 status=PASS files_changed=0 next=WAIT

▪ Let me read the pubspec.yaml file first.
▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines

▪ The pubspec.yaml file shows this is a Flutter package named "countdown_widgets".

  ARMIN_REAL_QODER_REGRESSION_D1 status=PASS files_changed=0 next=WAIT

YOLO Shift+Tab to Auto
Mode Try /effort or /context-window to adjust model settings
* Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''',
        now: now,
        status: NativeOutputTurnStatus.needAttention,
      ),
    ];
    const source = TaskDeliverableSource();

    expect(source.latestCandidate(turns)?.turn.id, 'turn-1');
    expect(source.evidenceFor(turns, source.latestCandidate(turns)!)?.text,
        contains('ARMIN_REAL_QODER_REGRESSION_D1'));
  });

  test('natural qoder final block is the only deliverable evidence', () {
    final now = DateTime(2026, 7, 12);
    final turns = [
      _turn(
        id: 'turn-1',
        index: 1,
        input: '输出项目名称以及简介',
        output: '''
▪ Let me check package.json for the project name and description.
▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines
▪ The project is named countdown_widgets and its description is: "A package containing
  various countdown widgets for Flutter applications."

  This is a Flutter package that provides countdown-related UI widgets for Flutter
  applications.
Shift+Tab to Accept Edits      Try /effort or /context-window to adjust model settings
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''',
        now: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];
    const source = TaskDeliverableSource();
    final candidate = source.latestCandidate(turns)!;

    final evidence = source.evidenceFor(turns, candidate)!.text;

    expect(evidence, contains('The project is named countdown_widgets'));
    expect(evidence, contains('countdown-related UI widgets'));
    expect(evidence, isNot(contains('Let me check')));
    expect(evidence, isNot(contains('Read(')));
    expect(evidence, isNot(contains('Shift+Tab')));
    expect(evidence, isNot(contains('Model · ctx')));
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
