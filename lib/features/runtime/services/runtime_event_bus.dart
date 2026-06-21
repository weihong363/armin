import 'dart:async';

import '../models/runtime_task_snapshot.dart';

enum RuntimeEventType {
  taskCreated,
  taskStarted,
  taskProgress,
  taskWaitingUser,
  taskCompleted,
  taskFailed,
  taskCancelled,
  taskPaused,
  taskResumed,
  taskStopped,
  outputUpdated,
  deliverableUpdated,
  approvalRequested,
  approvalResolving,
  approvalResolved,
  approvalRejected,
  approvalFailed,
  observerAttached,
  observerDetached,
  connectionLost,
  connectionRestored,
  reviewSubmitted,
  waitingForInstruction,
  waitingForReview,
  waitingForApproval,
}

extension RuntimeEventTypeWireName on RuntimeEventType {
  String get wireName {
    return switch (this) {
      RuntimeEventType.taskCreated => 'TASK_CREATED',
      RuntimeEventType.taskStarted => 'TASK_STARTED',
      RuntimeEventType.taskProgress => 'TASK_PROGRESS',
      RuntimeEventType.taskWaitingUser => 'TASK_WAITING_USER',
      RuntimeEventType.taskCompleted => 'TASK_COMPLETED',
      RuntimeEventType.taskFailed => 'TASK_FAILED',
      RuntimeEventType.taskCancelled => 'TASK_CANCELLED',
      RuntimeEventType.taskPaused => 'TASK_PAUSED',
      RuntimeEventType.taskResumed => 'TASK_RESUMED',
      RuntimeEventType.taskStopped => 'TASK_STOPPED',
      RuntimeEventType.outputUpdated => 'OUTPUT_UPDATED',
      RuntimeEventType.deliverableUpdated => 'DELIVERABLE_UPDATED',
      RuntimeEventType.approvalRequested => 'APPROVAL_REQUESTED',
      RuntimeEventType.approvalResolving => 'APPROVAL_RESOLVING',
      RuntimeEventType.approvalResolved => 'APPROVAL_RESOLVED',
      RuntimeEventType.approvalRejected => 'APPROVAL_REJECTED',
      RuntimeEventType.approvalFailed => 'APPROVAL_FAILED',
      RuntimeEventType.observerAttached => 'OBSERVER_ATTACHED',
      RuntimeEventType.observerDetached => 'OBSERVER_DETACHED',
      RuntimeEventType.connectionLost => 'CONNECTION_LOST',
      RuntimeEventType.connectionRestored => 'CONNECTION_RESTORED',
      RuntimeEventType.reviewSubmitted => 'REVIEW_SUBMITTED',
      RuntimeEventType.waitingForInstruction => 'WAITING_FOR_INSTRUCTION',
      RuntimeEventType.waitingForReview => 'WAITING_FOR_REVIEW',
      RuntimeEventType.waitingForApproval => 'WAITING_FOR_APPROVAL',
    };
  }

  static RuntimeEventType fromWireName(String wireName) {
    for (final type in RuntimeEventType.values) {
      if (type.wireName == wireName) {
        return type;
      }
    }
    return RuntimeEventType.taskProgress;
  }
}

class RuntimeEvent {
  const RuntimeEvent({
    required this.type,
    required this.taskId,
    required this.createdAt,
    this.snapshot,
    this.message = '',
    this.turnId,
    this.evidenceFingerprint,
  });

  final RuntimeEventType type;
  final String taskId;
  final DateTime createdAt;
  final RuntimeTaskSnapshot? snapshot;
  final String message;
  final String? turnId;
  final String? evidenceFingerprint;

  Map<String, Object?> toJson() {
    return {
      'type': type.wireName,
      'task_id': taskId,
      'created_at': createdAt.toIso8601String(),
      'snapshot': snapshot?.toJson(),
      'message': message,
      'turn_id': turnId,
      'evidence_fingerprint': evidenceFingerprint,
    };
  }

  factory RuntimeEvent.fromJson(Map<String, Object?> json) {
    final snapshotJson = json['snapshot'];
    return RuntimeEvent(
      type: RuntimeEventTypeWireName.fromWireName(
        json['type'] as String? ?? '',
      ),
      taskId: json['task_id'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      snapshot: snapshotJson is Map<String, Object?>
          ? RuntimeTaskSnapshot.fromJson(snapshotJson)
          : null,
      message: json['message'] as String? ?? '',
      turnId: json['turn_id'] as String?,
      evidenceFingerprint: json['evidence_fingerprint'] as String?,
    );
  }
}

class RuntimeEventBus {
  RuntimeEventBus();

  final _controller = StreamController<RuntimeEvent>.broadcast();

  Stream<RuntimeEvent> get events => _controller.stream;

  void publish(RuntimeEvent event) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(event);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
