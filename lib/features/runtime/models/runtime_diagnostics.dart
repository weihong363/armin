import 'approval_state.dart';
import 'work_state.dart';

/// Lightweight runtime diagnostics for debugging only.
///
/// Not exposed directly to end users.
class RuntimeDiagnostics {
  const RuntimeDiagnostics({
    required this.taskId,
    this.runId,
    this.sessionName,
    this.paneId,
    this.observerState,
    this.approvalState = ApprovalState.none,
    this.lastRuntimeEventType,
    this.lastDeliverableUpdate,
    this.lastObservedOutputTime,
    this.workPhase = WorkPhase.idle,
    this.eventCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String taskId;
  final String? runId;
  final String? sessionName;
  final String? paneId;
  final String? observerState;
  final ApprovalState approvalState;
  final String? lastRuntimeEventType;
  final DateTime? lastDeliverableUpdate;
  final DateTime? lastObservedOutputTime;
  final WorkPhase workPhase;
  final int eventCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  RuntimeDiagnostics copyWith({
    String? taskId,
    String? runId,
    String? sessionName,
    String? paneId,
    String? observerState,
    ApprovalState? approvalState,
    String? lastRuntimeEventType,
    DateTime? lastDeliverableUpdate,
    DateTime? lastObservedOutputTime,
    WorkPhase? workPhase,
    int? eventCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return RuntimeDiagnostics(
      taskId: taskId ?? this.taskId,
      runId: runId ?? this.runId,
      sessionName: sessionName ?? this.sessionName,
      paneId: paneId ?? this.paneId,
      observerState: observerState ?? this.observerState,
      approvalState: approvalState ?? this.approvalState,
      lastRuntimeEventType: lastRuntimeEventType ?? this.lastRuntimeEventType,
      lastDeliverableUpdate:
          lastDeliverableUpdate ?? this.lastDeliverableUpdate,
      lastObservedOutputTime:
          lastObservedOutputTime ?? this.lastObservedOutputTime,
      workPhase: workPhase ?? this.workPhase,
      eventCount: eventCount ?? this.eventCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'task_id': taskId,
      'run_id': runId,
      'session_name': sessionName,
      'pane_id': paneId,
      'observer_state': observerState,
      'approval_state': approvalState.name,
      'last_runtime_event_type': lastRuntimeEventType,
      'last_deliverable_update': lastDeliverableUpdate?.toIso8601String(),
      'last_observed_output_time': lastObservedOutputTime?.toIso8601String(),
      'work_phase': workPhase.name,
      'event_count': eventCount,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'RuntimeDiagnostics('
        'taskId=$taskId, '
        'observerState=$observerState, '
        'approvalState=${approvalState.name}, '
        'workPhase=${workPhase.name}, '
        'lastEvent=$lastRuntimeEventType, '
        'events=$eventCount)';
  }
}
