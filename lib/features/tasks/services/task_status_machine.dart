import '../../../core/models/task_status.dart';

class TaskStatusMachine {
  TaskStatus next(TaskStatus current, TaskStatus target) {
    final allowed = _allowedTargets[current] ?? const {};
    if (!allowed.contains(target)) {
      throw StateError('Invalid task status transition: $current -> $target');
    }
    return target;
  }

  static const Map<TaskStatus, Set<TaskStatus>> _allowedTargets = {
    TaskStatus.draft: {TaskStatus.pending},
    TaskStatus.pending: {TaskStatus.running, TaskStatus.failed},
    TaskStatus.running: {
      TaskStatus.paused,
      TaskStatus.stopped,
      TaskStatus.needApproval,
      TaskStatus.completed,
      TaskStatus.failed,
    },
    TaskStatus.paused: {TaskStatus.running, TaskStatus.stopped, TaskStatus.failed},
    TaskStatus.needApproval: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.failed,
    },
    TaskStatus.stopped: {},
    TaskStatus.completed: {},
    TaskStatus.failed: {},
  };
}
