import 'approval_state.dart';

/// Derived work state generated from runtime events,
/// approval state, deliverables, and output summary.
///
/// This is the primary UI-facing abstraction that
/// replaces direct [TaskStatus] consumption.
class WorkState {
  const WorkState({
    required this.taskId,
    required this.phase,
    required this.headline,
    required this.detail,
    this.approval,
    this.lastDeliverableId,
    this.deliverableCount = 0,
    this.updatedAt,
  });

  final String taskId;
  final WorkPhase phase;
  final String headline;
  final String detail;
  final NativeTerminalApproval? approval;
  final String? lastDeliverableId;
  final int deliverableCount;
  final DateTime? updatedAt;

  /// Whether the task needs user attention right now.
  bool get needsAttention {
    return phase == WorkPhase.needsApproval ||
        phase == WorkPhase.needsDecision ||
        phase == WorkPhase.needsReview ||
        phase == WorkPhase.needsInstruction;
  }

  /// Natural language work status for UI display.
  String get statusText {
    final buffer = StringBuffer(headline);
    if (detail.isNotEmpty) {
      buffer.write('\n');
      buffer.write(detail);
    }
    return buffer.toString();
  }

  WorkState copyWith({
    String? taskId,
    WorkPhase? phase,
    String? headline,
    String? detail,
    NativeTerminalApproval? approval,
    String? lastDeliverableId,
    int? deliverableCount,
    DateTime? updatedAt,
  }) {
    return WorkState(
      taskId: taskId ?? this.taskId,
      phase: phase ?? this.phase,
      headline: headline ?? this.headline,
      detail: detail ?? this.detail,
      approval: approval ?? this.approval,
      lastDeliverableId: lastDeliverableId ?? this.lastDeliverableId,
      deliverableCount: deliverableCount ?? this.deliverableCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'task_id': taskId,
      'phase': phase.name,
      'headline': headline,
      'detail': detail,
      'approval': approval?.toJson(),
      'last_deliverable_id': lastDeliverableId,
      'deliverable_count': deliverableCount,
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory WorkState.fromJson(Map<String, Object?> json) {
    final approvalJson = json['approval'];
    return WorkState(
      taskId: json['task_id'] as String? ?? '',
      phase: WorkPhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => WorkPhase.idle,
      ),
      headline: json['headline'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      approval: approvalJson is Map<String, Object?>
          ? NativeTerminalApproval.fromJson(approvalJson)
          : null,
      lastDeliverableId: json['last_deliverable_id'] as String?,
      deliverableCount: json['deliverable_count'] as int? ?? 0,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }
}

/// High-level work phase derived from runtime events.
enum WorkPhase {
  /// Task has not started.
  idle,

  /// Agent is actively working.
  working,

  /// Output is quiet, agent may be thinking or between turns.
  quieting,

  /// Turn is idle, waiting for next instruction.
  turnIdle,

  /// Agent needs user approval for a terminal action.
  needsApproval,

  /// Agent needs user to make a decision.
  needsDecision,

  /// Agent has produced a deliverable awaiting review.
  needsReview,

  /// Agent is waiting for user instruction.
  needsInstruction,

  /// Task completed successfully.
  completed,

  /// Task failed.
  failed,

  /// Task was stopped by user.
  stopped,
}
