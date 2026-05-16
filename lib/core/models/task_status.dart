enum TaskStatus {
  draft,
  pending,
  running,
  needApproval,
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
      case TaskStatus.needApproval:
        return 'Needs approval';
      case TaskStatus.completed:
        return 'Completed';
      case TaskStatus.failed:
        return 'Failed';
    }
  }
}
