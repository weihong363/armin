import '../../../core/models/task_status.dart';
import '../../agent/parsers/approval_request.dart';
import '../../agent/parsers/task_result.dart';
import '../../hosts/models/host_config.dart';
import 'execution_log.dart';
import 'metric_event.dart';
import 'prompt_record.dart';
import 'secret_entry.dart';
import 'subtask.dart';
import 'task_constraint.dart';
import 'task_draft.dart';
import 'voice_input.dart';

class TaskSession {
  const TaskSession({
    required this.id,
    required this.host,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.rawSttText,
    required this.cleanedDraft,
    required this.userText,
    required this.context,
    required this.constraints,
    required this.finalPrompt,
    required this.secretRecords,
    required this.rawLog,
    this.startedAt,
    this.completedAt,
    this.parentTaskId,
    this.workerLabel,
    this.shortSummary = '',
    this.summary,
    this.result,
    this.approval,
    this.voiceInputs = const [],
    this.draftRecord,
    this.promptRecord,
    this.executionLogs = const [],
    this.approvalRequests = const [],
    this.metricEvents = const [],
    this.subtasks = const [],
  });

  final String id;
  final HostConfig host;
  final String title;
  final TaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? parentTaskId;
  final String? workerLabel;
  final String rawSttText;
  final String cleanedDraft;
  final String userText;
  final String context;
  final Set<TaskConstraint> constraints;
  final String finalPrompt;
  final List<SecretRedactedRecord> secretRecords;
  final String rawLog;
  final String shortSummary;
  final String? summary;
  final TaskResult? result;
  final ApprovalRequest? approval;
  final List<VoiceInput> voiceInputs;
  final TaskDraft? draftRecord;
  final PromptRecord? promptRecord;
  final List<ExecutionLog> executionLogs;
  final List<ApprovalRequest> approvalRequests;
  final List<MetricEvent> metricEvents;
  final List<Subtask> subtasks;

  TaskSession copyWith({
    String? id,
    HostConfig? host,
    String? title,
    TaskStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? parentTaskId,
    String? workerLabel,
    String? rawSttText,
    String? cleanedDraft,
    String? userText,
    String? context,
    Set<TaskConstraint>? constraints,
    String? finalPrompt,
    List<SecretRedactedRecord>? secretRecords,
    String? rawLog,
    String? shortSummary,
    String? summary,
    TaskResult? result,
    ApprovalRequest? approval,
    List<VoiceInput>? voiceInputs,
    TaskDraft? draftRecord,
    PromptRecord? promptRecord,
    List<ExecutionLog>? executionLogs,
    List<ApprovalRequest>? approvalRequests,
    List<MetricEvent>? metricEvents,
    List<Subtask>? subtasks,
    bool clearApproval = false,
  }) {
    return TaskSession(
      id: id ?? this.id,
      host: host ?? this.host,
      title: title ?? this.title,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      workerLabel: workerLabel ?? this.workerLabel,
      rawSttText: rawSttText ?? this.rawSttText,
      cleanedDraft: cleanedDraft ?? this.cleanedDraft,
      userText: userText ?? this.userText,
      context: context ?? this.context,
      constraints: constraints ?? this.constraints,
      finalPrompt: finalPrompt ?? this.finalPrompt,
      secretRecords: secretRecords ?? this.secretRecords,
      rawLog: rawLog ?? this.rawLog,
      shortSummary: shortSummary ?? this.shortSummary,
      summary: summary ?? this.summary,
      result: result ?? this.result,
      approval: clearApproval ? null : approval ?? this.approval,
      voiceInputs: voiceInputs ?? this.voiceInputs,
      draftRecord: draftRecord ?? this.draftRecord,
      promptRecord: promptRecord ?? this.promptRecord,
      executionLogs: executionLogs ?? this.executionLogs,
      approvalRequests: approvalRequests ?? this.approvalRequests,
      metricEvents: metricEvents ?? this.metricEvents,
      subtasks: subtasks ?? this.subtasks,
    );
  }
}
