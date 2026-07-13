import '../../agent/models/agent_approval_config.dart';
import '../../hosts/models/host_config.dart';
import '../../runtime/models/approval_state.dart';
import 'metric_event.dart';
import 'native_output_turn.dart';
import 'prompt_record.dart';
import 'secret_entry.dart';
import 'subtask.dart';
import 'task_constraint.dart';
import 'task_draft.dart';
import 'task_recurrence.dart';
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
    this.approvalMode = AgentApprovalMode.balanced,
    this.startedAt,
    this.scheduledFor,
    this.calendarSyncEnabled = false,
    this.recurrence = TaskRecurrence.once,
    this.completedAt,
    this.parentTaskId,
    this.workerLabel,
    this.nativeApproval,
    this.voiceInputs = const [],
    this.draftRecord,
    this.promptRecord,
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
  final bool calendarSyncEnabled;
  final TaskRecurrence recurrence;
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
  final AgentApprovalMode approvalMode;
  final NativeTerminalApproval? nativeApproval;
  final List<VoiceInput> voiceInputs;
  final TaskDraft? draftRecord;
  final PromptRecord? promptRecord;
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
      calendarSyncEnabled: json['calendarSyncEnabled'] == true,
      recurrence: TaskRecurrence.values.firstWhere(
        (value) => value.name == json['recurrence'],
        orElse: () => TaskRecurrence.once,
      ),
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
      approvalMode: _approvalModeFromJson(json['approvalMode']),
      nativeApproval: _objectOf(
        json['nativeApproval'],
        NativeTerminalApproval.fromJson,
      ),
      voiceInputs: _listOf(json['voiceInputs'], VoiceInput.fromJson),
      draftRecord: _objectOf(json['draftRecord'], TaskDraft.fromJson),
      promptRecord: _objectOf(json['promptRecord'], PromptRecord.fromJson),
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
    bool? calendarSyncEnabled,
    TaskRecurrence? recurrence,
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
    AgentApprovalMode? approvalMode,
    NativeTerminalApproval? nativeApproval,
    List<VoiceInput>? voiceInputs,
    TaskDraft? draftRecord,
    PromptRecord? promptRecord,
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
      calendarSyncEnabled: calendarSyncEnabled ?? this.calendarSyncEnabled,
      recurrence: recurrence ?? this.recurrence,
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
      approvalMode: approvalMode ?? this.approvalMode,
      nativeApproval:
          clearNativeApproval ? null : nativeApproval ?? this.nativeApproval,
      voiceInputs: voiceInputs ?? this.voiceInputs,
      draftRecord: draftRecord ?? this.draftRecord,
      promptRecord: promptRecord ?? this.promptRecord,
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
      'calendarSyncEnabled': calendarSyncEnabled,
      'recurrence': recurrence.name,
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
      'approvalMode': approvalMode.name,
      'nativeApproval': nativeApproval?.toJson(),
      'voiceInputs': voiceInputs.map((input) => input.toJson()).toList(),
      'draftRecord': draftRecord?.toJson(),
      'promptRecord':
          promptRecord == null ? null : safePromptRecord(promptRecord!),
      'nativeApprovalRequests':
          nativeApprovalRequests.map((approval) => approval.toJson()).toList(),
      'metricEvents': metricEvents.map(safeMetricEvent).toList(),
      'subtasks': subtasks.map((subtask) => subtask.toJson()).toList(),
      'turns': turns.map(safeTurn).toList(),
    };
  }

  Map<String, Object?> toCompactJson() {
    final safeHost = host.toSafePersistedCopy();
    final password = host.password.trim();
    String safeText(String value) => _redactRuntimePassword(value, password);
    Map<String, Object?> safePromptRecord(PromptRecord record) {
      final json = record.toJson();
      json['finalPrompt'] = safeText(record.finalPrompt);
      return json;
    }

    Map<String, Object?> safeMetricEvent(MetricEvent event) {
      final json = event.toJson();
      json['payloadJson'] = safeText(event.payloadJson);
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
      'calendarSyncEnabled': calendarSyncEnabled,
      'recurrence': recurrence.name,
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
      'approvalMode': approvalMode.name,
      'nativeApproval': nativeApproval?.toJson(),
      'voiceInputs': voiceInputs.map((input) => input.toJson()).toList(),
      'draftRecord': draftRecord?.toJson(),
      'promptRecord':
          promptRecord == null ? null : safePromptRecord(promptRecord!),
      'nativeApprovalRequests':
          nativeApprovalRequests.map((approval) => approval.toJson()).toList(),
      'metricEvents': metricEvents.map(safeMetricEvent).toList(),
      'subtasks': subtasks.map((subtask) => subtask.toJson()).toList(),
      'turns': turns.map(_compactTurnJson).toList(growable: false),
    };
  }

  Map<String, Object?> _compactTurnJson(NativeOutputTurn turn) {
    final password = host.password.trim();
    String safeText(String value) => _redactRuntimePassword(value, password);
    return {
      'id': turn.id,
      'taskId': turn.taskId,
      'turnIndex': turn.turnIndex,
      'userInput': safeText(turn.userInput),
      'rawOutput': '',
      'cleanedOutput': '',
      'startedAt': turn.startedAt.toIso8601String(),
      'lastOutputAt': turn.lastOutputAt.toIso8601String(),
      'idleDetectedAt': turn.idleDetectedAt?.toIso8601String(),
      'status': turn.status.name,
      'userDecision': turn.userDecision,
      'deliverable': turn.deliverable?.toJson(),
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
