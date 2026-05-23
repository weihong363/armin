import 'package:flutter_test/flutter_test.dart';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/tasks/services/task_status_machine.dart';

void main() {
  test('allows valid task status transitions', () {
    final machine = TaskStatusMachine();

    expect(
        machine.next(TaskStatus.draft, TaskStatus.pending), TaskStatus.pending);
    expect(machine.next(TaskStatus.pending, TaskStatus.running),
        TaskStatus.running);
    expect(
      machine.next(TaskStatus.running, TaskStatus.needApproval),
      TaskStatus.needApproval,
    );
    expect(
      machine.next(TaskStatus.needApproval, TaskStatus.running),
      TaskStatus.running,
    );
    expect(
        machine.next(TaskStatus.running, TaskStatus.paused), TaskStatus.paused);
    expect(machine.next(TaskStatus.paused, TaskStatus.running),
        TaskStatus.running);
    expect(machine.next(TaskStatus.running, TaskStatus.stopped),
        TaskStatus.stopped);
    expect(machine.next(TaskStatus.running, TaskStatus.completed),
        TaskStatus.completed);
    expect(machine.next(TaskStatus.running, TaskStatus.turnIdle),
        TaskStatus.turnIdle);
    expect(machine.next(TaskStatus.turnIdle, TaskStatus.running),
        TaskStatus.running);
    expect(machine.next(TaskStatus.turnIdle, TaskStatus.userCompleted),
        TaskStatus.userCompleted);
    expect(machine.next(TaskStatus.running, TaskStatus.observerDetached),
        TaskStatus.observerDetached);
    expect(machine.next(TaskStatus.observerDetached, TaskStatus.running),
        TaskStatus.running);
  });

  test('rejects invalid task status transitions', () {
    final machine = TaskStatusMachine();

    expect(
      () => machine.next(TaskStatus.completed, TaskStatus.running),
      throwsStateError,
    );
  });
}
