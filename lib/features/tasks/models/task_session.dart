import '../../agent/models/agent_approval_config.dart';
import '../../hosts/models/host_config.dart';
import '../../runtime/models/approval_state.dart';
import 'execution_log.dart';
import 'metric_event.dart';
import 'native_output_turn.dart';
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
    this.approvalMode = AgentApprovalMode.balanced,
    this.startedAt,
    this.scheduledFor,
    this.completedAt,
    this.parentTaskId,
    this.workerLabel,
    this.shortSummary = '',
    this.summary,
    this.nativeApproval,
    this.voiceInputs = const [],
    this.draftRecord,
    this.promptRecord,
    this.executionLogs = const [],
    this.nativeApprovalRequests = const [],
    this.metricEvents = const [],
    this.subtasks = const [],
    this.turns = const [],
  });

  final String id;
  final HostConfig host;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? scheduledFor;
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
  final AgentApprovalMode approvalMode;
  final String shortSummary;
  final String? summary;
  final NativeTerminalApproval? nativeApproval;
  final List<VoiceInput> voiceInputs;
  final TaskDraft? draftRecord;
  final PromptRecord? promptRecord;
  final List<ExecutionLog> executionLogs;
  final List<NativeTerminalApproval> nativeApprovalRequests;
  final List<MetricEvent> metricEvents;
  final List<Subtask> subtasks;
  final List<NativeOutputTurn> turns;

  String get displayTitle {
    final trimmed = title.trim();
    return trimmed.isEmpty ? '未命名任务' : trimmed;
  }

  factory TaskSession.fromJson(Map<String, Object?> json) {
    final hostJson = json['host'];
    if (hostJson is! Map<String, Object?>) {
      throw const FormatException(
          'TaskSession JSON must include a valid host object.');
    }
    return TaskSession(
      id: json['id'] as String? ?? '',
      host: HostConfig.fromJson(hostJson),
      title: json['title'] as String? ?? '',
      createdAt: _date(json['createdAt']),
      updatedAt: _date(json['updatedAt']),
      startedAt: _nullableDate(json['startedAt']),
      scheduledFor: _nullableDate(json['scheduledFor']),
      completedAt: _nullableDate(json['completedAt']),
      parentTaskId: json['parentTaskId'] as String?,
      workerLabel: json['workerLabel'] as String?,
      rawSttText: json['rawSttText'] as String? ?? '',
      cleanedDraft: json['cleanedDraft'] as String? ?? '',
      userText: json['userText'] as String? ?? '',
      context: json['context'] as String? ?? '',
      constraints: _constraintsFromJson(json['constraints']),
      finalPrompt: json['finalPrompt'] as String? ?? '',
      secretRecords: _listOf(
        json['secretRecords'],
        SecretRedactedRecord.fromJson,
      ),
      rawLog: json['rawLog'] as String? ?? '',
      approvalMode: _approvalModeFromJson(json['approvalMode']),
      shortSummary: json['shortSummary'] as String? ?? '',
      summary: json['summary'] as String?,
      nativeApproval: _objectOf(
        json['nativeApproval'],
        NativeTerminalApproval.fromJson,
      ),
      voiceInputs: _listOf(json['voiceInputs'], VoiceInput.fromJson),
      draftRecord: _objectOf(json['draftRecord'], TaskDraft.fromJson),
      promptRecord: _objectOf(json['promptRecord'], PromptRecord.fromJson),
      executionLogs: _listOf(json['executionLogs'], ExecutionLog.fromJson),
      nativeApprovalRequests: _listOf(
        json['nativeApprovalRequests'],
        NativeTerminalApproval.fromJson,
      ),
      metricEvents: _listOf(json['metricEvents'], MetricEvent.fromJson),
      subtasks: _listOf(json['subtasks'], Subtask.fromJson),
      turns: _listOf(json['turns'], NativeOutputTurn.fromJson),
    );
  }

  TaskSession copyWith({
    String? id,
    HostConfig? host,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? scheduledFor,
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
    AgentApprovalMode? approvalMode,
    String? shortSummary,
    String? summary,
    NativeTerminalApproval? nativeApproval,
    List<VoiceInput>? voiceInputs,
    TaskDraft? draftRecord,
    PromptRecord? promptRecord,
    List<ExecutionLog>? executionLogs,
    List<NativeTerminalApproval>? nativeApprovalRequests,
    List<MetricEvent>? metricEvents,
    List<Subtask>? subtasks,
    List<NativeOutputTurn>? turns,
    bool clearNativeApproval = false,
    bool clearScheduledFor = false,
  }) {
    return TaskSession(
      id: id ?? this.id,
      host: host ?? this.host,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      startedAt: startedAt ?? this.startedAt,
      scheduledFor:
          clearScheduledFor ? null : scheduledFor ?? this.scheduledFor,
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
      approvalMode: approvalMode ?? this.approvalMode,
      shortSummary: shortSummary ?? this.shortSummary,
      summary: summary ?? this.summary,
      nativeApproval:
          clearNativeApproval ? null : nativeApproval ?? this.nativeApproval,
      voiceInputs: voiceInputs ?? this.voiceInputs,
      draftRecord: draftRecord ?? this.draftRecord,
      promptRecord: promptRecord ?? this.promptRecord,
      executionLogs: executionLogs ?? this.executionLogs,
      nativeApprovalRequests:
          nativeApprovalRequests ?? this.nativeApprovalRequests,
      metricEvents: metricEvents ?? this.metricEvents,
      subtasks: subtasks ?? this.subtasks,
      turns: turns ?? this.turns,
    );
  }

  Map<String, Object?> toJson() {
    final safeHost = host.toSafePersistedCopy();
    final password = host.password.trim();
    String safeText(String value) => _redactRuntimePassword(value, password);
    Map<String, Object?> safePromptRecord(PromptRecord record) {
      final json = record.toJson();
      json['finalPrompt'] = safeText(record.finalPrompt);
      return json;
    }

    Map<String, Object?> safeExecutionLog(ExecutionLog log) {
      final json = log.toJson();
      json['rawOutput'] = safeText(log.rawOutput);
      return json;
    }

    Map<String, Object?> safeMetricEvent(MetricEvent event) {
      final json = event.toJson();
      json['payloadJson'] = safeText(event.payloadJson);
      return json;
    }

    Map<String, Object?> safeTurn(NativeOutputTurn turn) {
      final json = turn.toJson();
      json['rawOutput'] = safeText(turn.rawOutput);
      json['cleanedOutput'] = safeText(turn.cleanedOutput);
      json['userInput'] = safeText(turn.userInput);
      return json;
    }

    return {
      'id': id,
      'host': safeHost.toJson(),
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'scheduledFor': scheduledFor?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'parentTaskId': parentTaskId,
      'workerLabel': workerLabel,
      'rawSttText': rawSttText,
      'cleanedDraft': cleanedDraft,
      'userText': userText,
      'context': context,
      'constraints': constraints.map((constraint) => constraint.name).toList(),
      'finalPrompt': safeText(finalPrompt),
      'secretRecords': secretRecords.map((record) => record.toJson()).toList(),
      'rawLog': safeText(rawLog),
      'approvalMode': approvalMode.name,
      'shortSummary': safeText(shortSummary),
      'summary': summary == null ? null : safeText(summary!),
      'nativeApproval': nativeApproval?.toJson(),
      'voiceInputs': voiceInputs.map((input) => input.toJson()).toList(),
      'draftRecord': draftRecord?.toJson(),
      'promptRecord':
          promptRecord == null ? null : safePromptRecord(promptRecord!),
      'executionLogs': executionLogs.map(safeExecutionLog).toList(),
      'nativeApprovalRequests':
          nativeApprovalRequests.map((approval) => approval.toJson()).toList(),
      'metricEvents': metricEvents.map(safeMetricEvent).toList(),
      'subtasks': subtasks.map((subtask) => subtask.toJson()).toList(),
      'turns': turns.map(safeTurn).toList(),
    };
  }
}

String _redactRuntimePassword(String value, String password) {
  if (password.isEmpty || value.isEmpty) {
    return value;
  }
  return value.replaceAll(password, '[REDACTED_PASSWORD]');
}

DateTime _date(Object? value) {
  return DateTime.tryParse(value as String? ?? '') ?? DateTime.now();
}

AgentApprovalMode _approvalModeFromJson(Object? value) {
  final name = value as String? ?? '';
  return AgentApprovalMode.values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => AgentApprovalMode.balanced,
  );
}

DateTime? _nullableDate(Object? value) {
  return DateTime.tryParse(value as String? ?? '');
}

Set<TaskConstraint> _constraintsFromJson(Object? value) {
  if (value is! List) {
    return const {};
  }
  return value
      .whereType<String>()
      .map(
        (name) => TaskConstraint.values.firstWhere(
          (constraint) => constraint.name == name,
          orElse: () => TaskConstraint.minimalChange,
        ),
      )
      .toSet();
}

T? _objectOf<T>(
  Object? value,
  T Function(Map<String, Object?> json) fromJson,
) {
  if (value is Map<String, Object?>) {
    return fromJson(value);
  }
  return null;
}

List<T> _listOf<T>(
  Object? value,
  T Function(Map<String, Object?> json) fromJson,
) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<Map<String, Object?>>()
      .map(fromJson)
      .toList(growable: false);
}
