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
}
