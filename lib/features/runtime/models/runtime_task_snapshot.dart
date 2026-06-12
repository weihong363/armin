import '../../../core/models/task_status.dart';

enum RuntimeTaskStatus {
  pending,
  running,
  waitingUser,
  completed,
  failed,
  cancelled,
}

class RuntimeTaskSnapshot {
  const RuntimeTaskSnapshot({
    required this.taskId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.sessionId = '',
    this.summary = '',
    this.currentStep = '',
    this.action = '',
    this.progress = 0,
    this.lastLogOffset = 0,
    this.checkpoint = '',
  });

  final String taskId;
  final RuntimeTaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String sessionId;
  final String summary;
  final String currentStep;
  final String action;
  final int progress;
  final int lastLogOffset;
  final String checkpoint;

  factory RuntimeTaskSnapshot.fromTaskStatus({
    required String taskId,
    required TaskStatus status,
    required DateTime createdAt,
    required DateTime updatedAt,
    String sessionId = '',
    String summary = '',
    String currentStep = '',
  }) {
    return RuntimeTaskSnapshot(
      taskId: taskId,
      status: _runtimeStatusFromTaskStatus(status),
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionId: sessionId,
      summary: summary,
      currentStep: currentStep,
    );
  }

  RuntimeTaskSnapshot copyWith({
    RuntimeTaskStatus? status,
    DateTime? updatedAt,
    String? sessionId,
    String? summary,
    String? currentStep,
    String? action,
    int? progress,
    int? lastLogOffset,
    String? checkpoint,
  }) {
    return RuntimeTaskSnapshot(
      taskId: taskId,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sessionId: sessionId ?? this.sessionId,
      summary: summary ?? this.summary,
      currentStep: currentStep ?? this.currentStep,
      action: action ?? this.action,
      progress: progress ?? this.progress,
      lastLogOffset: lastLogOffset ?? this.lastLogOffset,
      checkpoint: checkpoint ?? this.checkpoint,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'task_id': taskId,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'session_id': sessionId,
      'summary': summary,
      'current_step': currentStep,
      'action': action,
      'progress': progress,
      'last_log_offset': lastLogOffset,
      'checkpoint': checkpoint,
    };
  }

  factory RuntimeTaskSnapshot.fromJson(Map<String, Object?> json) {
    return RuntimeTaskSnapshot(
      taskId: json['task_id'] as String? ?? '',
      status: RuntimeTaskStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => RuntimeTaskStatus.pending,
      ),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
      sessionId: json['session_id'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      currentStep: json['current_step'] as String? ?? '',
      action: json['action'] as String? ?? '',
      progress: json['progress'] as int? ?? 0,
      lastLogOffset: json['last_log_offset'] as int? ?? 0,
      checkpoint: json['checkpoint'] as String? ?? '',
    );
  }
}

RuntimeTaskStatus _runtimeStatusFromTaskStatus(TaskStatus status) {
  return switch (status) {
    TaskStatus.draft || TaskStatus.pending => RuntimeTaskStatus.pending,
    TaskStatus.running ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      RuntimeTaskStatus.running,
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.paused =>
      RuntimeTaskStatus.waitingUser,
    TaskStatus.completed ||
    TaskStatus.userCompleted =>
      RuntimeTaskStatus.completed,
    TaskStatus.failed || TaskStatus.userFailed => RuntimeTaskStatus.failed,
    TaskStatus.stopped => RuntimeTaskStatus.cancelled,
  };
}
