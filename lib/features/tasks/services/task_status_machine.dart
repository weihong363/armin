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
      TaskStatus.turnIdle,
      TaskStatus.needAttention,
      TaskStatus.observerDetached,
      TaskStatus.runtimeLost,
      TaskStatus.userCompleted,
      TaskStatus.userFailed,
      TaskStatus.completed,
      TaskStatus.failed,
    },
    TaskStatus.paused: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.failed
    },
    TaskStatus.needApproval: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.failed,
    },
    TaskStatus.turnIdle: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.userCompleted,
      TaskStatus.userFailed,
      TaskStatus.runtimeLost,
    },
    TaskStatus.needAttention: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.observerDetached,
      TaskStatus.userCompleted,
      TaskStatus.userFailed,
      TaskStatus.runtimeLost,
    },
    TaskStatus.observerDetached: {
      TaskStatus.running,
      TaskStatus.stopped,
      TaskStatus.userFailed,
      TaskStatus.runtimeLost,
    },
    TaskStatus.stopped: {},
    TaskStatus.runtimeLost: {},
    TaskStatus.userCompleted: {},
    TaskStatus.userFailed: {},
    TaskStatus.completed: {},
    TaskStatus.failed: {},
  };
}
