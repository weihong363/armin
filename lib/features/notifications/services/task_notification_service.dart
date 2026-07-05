enum TaskNotificationKind {
  approvalRequired,
  needsInstruction,
  resultReady,
  runtimeLost,
  taskCompleted,
  taskFailed,
}

class TaskNotification {
  const TaskNotification({
    required this.id,
    required this.taskId,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.turnId,
    this.evidenceFingerprint,
  });

  final String id;
  final String taskId;
  final TaskNotificationKind kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? turnId;
  final String? evidenceFingerprint;
}

abstract interface class TaskNotificationService {
  Future<void> show(TaskNotification notification);
}

class NoopTaskNotificationService implements TaskNotificationService {
  const NoopTaskNotificationService();

  @override
  Future<void> show(TaskNotification notification) async {}
}
