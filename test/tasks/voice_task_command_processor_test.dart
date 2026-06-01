import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/services/voice_task_command_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const processor = VoiceTaskCommandProcessor();

  test('maps stop and completion phrases to local task actions', () {
    final stop = processor.interpret('停一下', TaskStatus.running);
    final complete = processor.interpret('这个任务完成了', TaskStatus.turnIdle);

    expect(stop.action, VoiceTaskAction.stopTask);
    expect(complete.action, VoiceTaskAction.markCompleted);
    expect(stop.instruction, isEmpty);
    expect(complete.instruction, isEmpty);
  });

  test('maps read result phrases to local speech action', () {
    final result = processor.interpret('读一下结果', TaskStatus.turnIdle);

    expect(result.instruction, isEmpty);
    expect(result.label, '朗读当前结果');
  });

  test('maps continue according to current task state', () {
    final paused = processor.interpret('继续执行', TaskStatus.paused);
    final detached = processor.interpret('恢复任务', TaskStatus.observerDetached);
    final idle = processor.interpret('继续', TaskStatus.turnIdle);

    expect(paused.action, VoiceTaskAction.resumeTask);
    expect(detached.action, VoiceTaskAction.reconnectObserver);
    expect(idle.action, VoiceTaskAction.sendInstruction);
    expect(idle.instruction, '请继续当前任务。');
  });

  test('extracts spoken constraints while preserving instruction', () {
    final result = processor.interpret('先别大改，并且不要提交 Git', TaskStatus.turnIdle);

    expect(result.action, VoiceTaskAction.sendInstruction);
    expect(result.instruction, '先别大改，并且不要提交 Git');
    expect(result.constraints, contains(TaskConstraint.minimalChange));
    expect(result.constraints, contains(TaskConstraint.noGitCommit));
    expect(result.isSemanticMatch, isTrue);
  });

  test('maps terminal prompt responses to option selection actions', () {
    final allow = processor.interpret('允许一次', TaskStatus.needAttention);
    final reject = processor.interpret('拒绝', TaskStatus.needAttention);

    expect(allow.action, VoiceTaskAction.selectTerminalOption);
    expect(allow.terminalOptionKey, '1');
    expect(allow.label, '允许一次');
    expect(reject.action, VoiceTaskAction.selectTerminalOption);
    expect(reject.terminalOptionKey, '4');
    expect(reject.label, '拒绝');
  });

  test('maps approval prompts to approve and reject actions', () {
    final approve = processor.interpret('批准', TaskStatus.needApproval);
    final reject = processor.interpret('拒绝', TaskStatus.needApproval);

    expect(approve.action, VoiceTaskAction.resolveApprovalRequest);
    expect(approve.approvalApproved, isTrue);
    expect(approve.label, '批准当前请求');
    expect(reject.action, VoiceTaskAction.resolveApprovalRequest);
    expect(reject.approvalApproved, isFalse);
    expect(reject.label, '拒绝当前请求');
  });
}
