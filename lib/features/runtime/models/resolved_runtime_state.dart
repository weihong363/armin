import '../../../core/models/task_status.dart';
import '../../tasks/models/task_session.dart';
import 'approval_state.dart';
import 'work_state.dart';

class ResolvedRuntimeState {
  const ResolvedRuntimeState({
    required this.taskStatus,
    required this.phase,
    required this.headline,
    required this.detail,
    this.approval,
    this.lastDeliverableId,
    this.deliverableCount = 0,
    this.updatedAt,
  });

  final TaskStatus taskStatus;
  final WorkPhase phase;
  final String headline;
  final String detail;
  final NativeTerminalApproval? approval;
  final String? lastDeliverableId;
  final int deliverableCount;
  final DateTime? updatedAt;

  bool get needsAttention =>
      phase == WorkPhase.needsApproval ||
      phase == WorkPhase.needsDecision ||
      phase == WorkPhase.needsReview ||
      phase == WorkPhase.needsInstruction ||
      phase == WorkPhase.turnIdle ||
      phase == WorkPhase.failed;

  String get statusText {
    if (detail.trim().isEmpty) return headline;
    return '$headline\n$detail';
  }

  WorkState toWorkState(String taskId) {
    return WorkState(
      taskId: taskId,
      phase: phase,
      headline: headline,
      detail: detail,
      approval: approval,
      lastDeliverableId: lastDeliverableId,
      deliverableCount: deliverableCount,
      updatedAt: updatedAt,
    );
  }
}

ResolvedRuntimeState resolveRuntimeState(
  TaskSession task, {
  required TaskStatus taskStatus,
  WorkState? workState,
}) {
  final phase = runtimePhaseForTaskStatus(taskStatus);
  final projectedHeadline = runtimeHeadlineForTaskStatus(taskStatus);
  final keepRuntimeText = workState != null && workState.phase == phase;
  return ResolvedRuntimeState(
    taskStatus: taskStatus,
    phase: phase,
    headline: keepRuntimeText ? workState.headline : projectedHeadline,
    detail: keepRuntimeText ? workState.detail : '',
    approval: workState?.approval ?? task.nativeApproval,
    lastDeliverableId: workState?.lastDeliverableId,
    deliverableCount: workState?.deliverableCount ?? 0,
    updatedAt: task.updatedAt,
  );
}

bool isRuntimeStateConsistent({
  required TaskStatus taskStatus,
  required WorkState? workState,
}) {
  return workState == null ||
      workState.phase == runtimePhaseForTaskStatus(taskStatus);
}

WorkPhase runtimePhaseForTaskStatus(TaskStatus status) {
  return switch (status) {
    TaskStatus.draft || TaskStatus.pending => WorkPhase.idle,
    TaskStatus.running => WorkPhase.working,
    TaskStatus.paused ||
    TaskStatus.observerDetached ||
    TaskStatus.runtimeLost =>
      WorkPhase.quieting,
    TaskStatus.turnIdle => WorkPhase.turnIdle,
    TaskStatus.needApproval => WorkPhase.needsApproval,
    TaskStatus.needAttention => WorkPhase.needsInstruction,
    TaskStatus.completed || TaskStatus.userCompleted => WorkPhase.completed,
    TaskStatus.failed || TaskStatus.userFailed => WorkPhase.failed,
    TaskStatus.stopped => WorkPhase.stopped,
  };
}

String runtimeHeadlineForTaskStatus(TaskStatus status) {
  return switch (status) {
    TaskStatus.draft => 'Task drafted.',
    TaskStatus.pending => 'Task scheduled.',
    TaskStatus.running => 'Agent started.',
    TaskStatus.paused => 'Task paused.',
    TaskStatus.observerDetached => 'Observer detached.',
    TaskStatus.runtimeLost => '连接已暂停',
    TaskStatus.turnIdle => '等待你的指示',
    TaskStatus.needApproval => '这个任务需要你做决定',
    TaskStatus.needAttention => '等待你的输入',
    TaskStatus.completed || TaskStatus.userCompleted => 'Task completed.',
    TaskStatus.failed || TaskStatus.userFailed => 'Task failed.',
    TaskStatus.stopped => 'Task stopped.',
  };
}
