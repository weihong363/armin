enum TaskStatus {
  draft,
  pending,
  running,
  paused,
  stopped,
  needApproval,
  turnIdle,
  needAttention,
  runtimeLost,
  userCompleted,
  userFailed,
  completed,
  failed,
}

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.draft:
        return 'Draft';
      case TaskStatus.pending:
        return 'Pending';
      case TaskStatus.running:
        return 'Running';
      case TaskStatus.paused:
        return 'Paused';
      case TaskStatus.stopped:
        return 'Stopped';
      case TaskStatus.needApproval:
        return 'Needs approval';
      case TaskStatus.turnIdle:
        return 'Turn idle';
      case TaskStatus.needAttention:
        return 'Needs attention';
      case TaskStatus.runtimeLost:
        return 'Runtime lost';
      case TaskStatus.userCompleted:
        return 'Completed by user';
      case TaskStatus.userFailed:
        return 'Failed by user';
      case TaskStatus.completed:
        return 'Completed';
      case TaskStatus.failed:
        return 'Failed';
    }
  }
}
