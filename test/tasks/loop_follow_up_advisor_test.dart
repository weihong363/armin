import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/loop_follow_up_advisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const advisor = LoopFollowUpAdvisor();

  test('suggests tests when implementation lacks validation evidence', () {
    final task = _task(
      constraints: const {TaskConstraint.runTestsAfterChanges},
    );

    final suggestions = advisor.suggest(task);

    expect(
        suggestions.map((item) => item.id), contains('request_test_evidence'));
    expect(suggestions.first.draft, contains('测试命令'));
  });

  test('does not suggest tests when latest deliverable has test evidence', () {
    final task = _task(
      constraints: const {TaskConstraint.runTestsAfterChanges},
      summary: '已实现倒计时组件，运行 flutter test test/countdown_test.dart 全部通过。',
    );

    final suggestions = advisor.suggest(task);

    expect(
      suggestions.map((item) => item.id),
      isNot(contains('request_test_evidence')),
    );
  });

  test('prioritizes blocker before other suggestions', () {
    final task = _task(
      summary: '实现失败，permission denied，无法写入目标目录。',
    );

    final suggestions = advisor.suggest(task);

    expect(suggestions.first.id, 'resolve_blocker');
    expect(suggestions.first.draft, contains('最小解除步骤'));
  });

  test('asks for file evidence when implementation omits file list', () {
    final task = _task();

    final suggestions = advisor.suggest(task);

    expect(
        suggestions.map((item) => item.id), contains('request_file_evidence'));
    expect(
        suggestions.map((item) => item.id), contains('request_test_evidence'));
  });

  test('does not ask for file evidence when latest result lists files', () {
    final task = _task(
      summary: '已修复 lib/main.dart 和 test/countdown_test.dart，测试通过。',
    );

    final suggestions = advisor.suggest(task);

    expect(
      suggestions.map((item) => item.id),
      isNot(contains('request_file_evidence')),
    );
  });

  test('asks to clarify thin results', () {
    final task = _task(summary: '项目已看完。');

    final suggestions = advisor.suggest(task);

    expect(suggestions.map((item) => item.id), contains('clarify_completion'));
    expect(suggestions.single.draft, contains('已完成内容'));
  });

  test('checks constraints when analyze-only task reports modifications', () {
    final task = _task(
      constraints: const {
        TaskConstraint.analyzeOnly,
        TaskConstraint.noGitCommit,
      },
      summary: '已修改 pubspec.yaml 并提交 git commit。',
    );

    final suggestions = advisor.suggest(task);

    expect(suggestions.map((item) => item.id), contains('check_constraints'));
    expect(
      suggestions.firstWhere((item) => item.id == 'check_constraints').draft,
      contains('是否修改了文件'),
    );
  });

  test('uses only latest deliverable and ignores old turn content', () {
    final task = _task(
      previousSummary: '旧结果提到 permission denied 和 failed。',
      summary: '已完成项目简介，当前可验收。',
    );

    final suggestions = advisor.suggest(task);

    expect(
        suggestions.map((item) => item.id), isNot(contains('resolve_blocker')));
  });

  test('does not emit status-button suggestions', () {
    final task = _task();

    final suggestions = advisor.suggest(task);
    final text = suggestions.map((item) => item.draft).join('\n');

    expect(text, isNot(contains('标记完成')));
    expect(text, isNot(contains('点击继续')));
  });
}

TaskSession _task({
  String summary = '已实现倒计时组件交互和状态更新。',
  String? previousSummary,
  Set<TaskConstraint> constraints = const {},
}) {
  final now = DateTime(2026, 7, 3);
  final turns = <NativeOutputTurn>[
    if (previousSummary != null)
      _turn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '旧任务',
        summary: previousSummary,
        now: now,
      ),
    _turn(
      id: previousSummary == null ? 'turn-1' : 'turn-2',
      taskId: 'task-1',
      turnIndex: previousSummary == null ? 1 : 2,
      userInput: '完成当前任务',
      summary: summary,
      now: now,
    ),
  ];
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Local',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-test',
      agentCommand: 'qodercli',
      createdAt: now,
      updatedAt: now,
    ),
    title: '测试任务',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: '测试任务',
    userText: '测试任务',
    context: '',
    constraints: constraints,
    finalPrompt: '测试任务',
    secretRecords: const [],
    approvalMode: AgentApprovalMode.aggressive,
    turns: turns,
  );
}

NativeOutputTurn _turn({
  required String id,
  required String taskId,
  required int turnIndex,
  required String userInput,
  required String summary,
  required DateTime now,
}) {
  return NativeOutputTurn(
    id: id,
    taskId: taskId,
    turnIndex: turnIndex,
    userInput: userInput,
    rawOutput: summary,
    cleanedOutput: summary,
    startedAt: now,
    lastOutputAt: now,
    status: NativeOutputTurnStatus.turnIdle,
    deliverable: TurnDeliverable(
      displaySummary: summary,
      speechSummary: summary,
      evidenceFingerprint: 'fingerprint-$id',
    ),
  );
}
