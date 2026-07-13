class LoopTurnMetrics {
  const LoopTurnMetrics({
    required this.inputLength,
    required this.outputSummaryLength,
    required this.approvalCount,
    required this.retryCount,
    required this.waitMs,
    required this.hasDeliverable,
  });

  final int inputLength;
  final int outputSummaryLength;
  final int approvalCount;
  final int retryCount;
  final int waitMs;
  final bool hasDeliverable;

  factory LoopTurnMetrics.fromJson(Map<String, Object?> json) {
    return LoopTurnMetrics(
      inputLength: _int(json['inputLength']),
      outputSummaryLength: _int(json['outputSummaryLength']),
      approvalCount: _int(json['approvalCount']),
      retryCount: _int(json['retryCount']),
      waitMs: _int(json['waitMs']),
      hasDeliverable: json['hasDeliverable'] as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'inputLength': inputLength,
      'outputSummaryLength': outputSummaryLength,
      'approvalCount': approvalCount,
      'retryCount': retryCount,
      'waitMs': waitMs,
      'hasDeliverable': hasDeliverable,
    };
  }
}

class LoopEvaluation {
  static const metricEventType = 'loop_evaluated';

  const LoopEvaluation({
    required this.id,
    required this.taskId,
    required this.turnId,
    required this.turnIndex,
    required this.status,
    required this.createdAt,
    required this.metrics,
  });

  final String id;
  final String taskId;
  final String turnId;
  final int turnIndex;
  final String status;
  final DateTime createdAt;
  final LoopTurnMetrics metrics;

  factory LoopEvaluation.fromJson(Map<String, Object?> json) {
    return LoopEvaluation(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      turnId: json['turnId'] as String? ?? '',
      turnIndex: _int(json['turnIndex']),
      status: json['status'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      metrics: LoopTurnMetrics.fromJson(
        _map(json['metrics']),
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'turnId': turnId,
      'turnIndex': turnIndex,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      'metrics': metrics.toJson(),
    };
  }
}

class LoopResultReference {
  const LoopResultReference({
    required this.turnId,
    required this.turnIndex,
    required this.summaryLength,
    required this.evidenceFingerprint,
  });

  final String turnId;
  final int turnIndex;
  final int summaryLength;
  final String evidenceFingerprint;

  factory LoopResultReference.fromJson(Map<String, Object?> json) {
    return LoopResultReference(
      turnId: json['turnId'] as String? ?? '',
      turnIndex: _int(json['turnIndex']),
      summaryLength: _int(json['summaryLength']),
      evidenceFingerprint: json['evidenceFingerprint'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'turnId': turnId,
      'turnIndex': turnIndex,
      'summaryLength': summaryLength,
      'evidenceFingerprint': evidenceFingerprint,
    };
  }
}

class LoopResultSummary {
  static const metricEventType = 'loop_result_summary';

  const LoopResultSummary({
    required this.id,
    required this.taskId,
    required this.createdAt,
    required this.latestTurnId,
    required this.latestTurnIndex,
    required this.latestEvidenceFingerprint,
    required this.resultCount,
    required this.acceptedCount,
    required this.redoCount,
    required this.completedCount,
    required this.failedCount,
    required this.summaryText,
    required this.results,
  });

  final String id;
  final String taskId;
  final DateTime createdAt;
  final String latestTurnId;
  final int latestTurnIndex;
  final String latestEvidenceFingerprint;
  final int resultCount;
  final int acceptedCount;
  final int redoCount;
  final int completedCount;
  final int failedCount;
  final String summaryText;
  final List<LoopResultReference> results;

  factory LoopResultSummary.fromJson(Map<String, Object?> json) {
    final results = json['results'];
    return LoopResultSummary(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      latestTurnId: json['latestTurnId'] as String? ?? '',
      latestTurnIndex: _int(json['latestTurnIndex']),
      latestEvidenceFingerprint:
          json['latestEvidenceFingerprint'] as String? ?? '',
      resultCount: _int(json['resultCount']),
      acceptedCount: _int(json['acceptedCount']),
      redoCount: _int(json['redoCount']),
      completedCount: _int(json['completedCount']),
      failedCount: _int(json['failedCount']),
      summaryText: json['summaryText'] as String? ?? '',
      results: results is List
          ? results
              .whereType<Map<String, Object?>>()
              .map(LoopResultReference.fromJson)
              .toList(growable: false)
          : const [],
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'createdAt': createdAt.toIso8601String(),
      'latestTurnId': latestTurnId,
      'latestTurnIndex': latestTurnIndex,
      'latestEvidenceFingerprint': latestEvidenceFingerprint,
      'resultCount': resultCount,
      'acceptedCount': acceptedCount,
      'redoCount': redoCount,
      'completedCount': completedCount,
      'failedCount': failedCount,
      'summaryText': summaryText,
      'results': results.map((result) => result.toJson()).toList(),
    };
  }
}

enum LoopUserActionKind {
  continueTask,
  acceptResult,
  markCompleted,
  markFailed,
  rejectOrRedo,
}

class LoopUserAction {
  static const metricEventType = 'loop_user_action';

  const LoopUserAction({
    required this.id,
    required this.taskId,
    required this.kind,
    required this.createdAt,
    required this.turnId,
    required this.turnIndex,
    required this.status,
    this.nextTurnId,
    this.nextTurnIndex,
    this.instructionLength = 0,
    this.source = 'text',
  });

  final String id;
  final String taskId;
  final LoopUserActionKind kind;
  final DateTime createdAt;
  final String turnId;
  final int turnIndex;
  final String status;
  final String? nextTurnId;
  final int? nextTurnIndex;
  final int instructionLength;
  final String source;

  factory LoopUserAction.fromJson(Map<String, Object?> json) {
    return LoopUserAction(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      kind: _userActionKind(json['kind']),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      turnId: json['turnId'] as String? ?? '',
      turnIndex: _int(json['turnIndex']),
      status: json['status'] as String? ?? '',
      nextTurnId: json['nextTurnId'] as String?,
      nextTurnIndex: _nullableInt(json['nextTurnIndex']),
      instructionLength: _int(json['instructionLength']),
      source: json['source'] as String? ?? 'text',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'kind': kind.name,
      'createdAt': createdAt.toIso8601String(),
      'turnId': turnId,
      'turnIndex': turnIndex,
      'status': status,
      'nextTurnId': nextTurnId,
      'nextTurnIndex': nextTurnIndex,
      'instructionLength': instructionLength,
      'source': source,
    };
  }
}

enum LoopAutoActionState {
  sent,
  confirmed,
  skipped,
  rejected,
}

class LoopAutoAction {
  static const metricEventType = 'loop_auto_action';

  const LoopAutoAction({
    required this.id,
    required this.taskId,
    required this.actionId,
    required this.createdAt,
    required this.turnId,
    required this.turnIndex,
    required this.evidenceFingerprint,
    required this.policy,
    required this.state,
    required this.instructionLength,
  });

  final String id;
  final String taskId;
  final String actionId;
  final DateTime createdAt;
  final String turnId;
  final int turnIndex;
  final String evidenceFingerprint;
  final String policy;
  final LoopAutoActionState state;
  final int instructionLength;

  String get dedupeKey => '$turnId|$evidenceFingerprint|$actionId';

  factory LoopAutoAction.fromJson(Map<String, Object?> json) {
    return LoopAutoAction(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      actionId: json['actionId'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      turnId: json['turnId'] as String? ?? '',
      turnIndex: _int(json['turnIndex']),
      evidenceFingerprint: json['evidenceFingerprint'] as String? ?? '',
      policy: json['policy'] as String? ?? '',
      state: _autoActionState(json['state']),
      instructionLength: _int(json['instructionLength']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'actionId': actionId,
      'createdAt': createdAt.toIso8601String(),
      'turnId': turnId,
      'turnIndex': turnIndex,
      'evidenceFingerprint': evidenceFingerprint,
      'policy': policy,
      'state': state.name,
      'instructionLength': instructionLength,
    };
  }
}

enum LoopApprovalEventKind {
  requested,
  approved,
  rejected,
  optionSelected,
  customResponse,
}

class LoopApprovalEvent {
  static const metricEventType = 'loop_approval_event';

  const LoopApprovalEvent({
    required this.id,
    required this.taskId,
    required this.approvalId,
    required this.kind,
    required this.createdAt,
    required this.turnId,
    required this.turnIndex,
    required this.status,
    this.questionLength = 0,
    this.optionCount = 0,
    this.selectedOptionKey,
    this.customResponseLength = 0,
    this.source = 'terminal',
  });

  final String id;
  final String taskId;
  final String approvalId;
  final LoopApprovalEventKind kind;
  final DateTime createdAt;
  final String turnId;
  final int turnIndex;
  final String status;
  final int questionLength;
  final int optionCount;
  final String? selectedOptionKey;
  final int customResponseLength;
  final String source;

  factory LoopApprovalEvent.fromJson(Map<String, Object?> json) {
    return LoopApprovalEvent(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      approvalId: json['approvalId'] as String? ?? '',
      kind: _approvalEventKind(json['kind']),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      turnId: json['turnId'] as String? ?? '',
      turnIndex: _int(json['turnIndex']),
      status: json['status'] as String? ?? '',
      questionLength: _int(json['questionLength']),
      optionCount: _int(json['optionCount']),
      selectedOptionKey: json['selectedOptionKey'] as String?,
      customResponseLength: _int(json['customResponseLength']),
      source: json['source'] as String? ?? 'terminal',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'approvalId': approvalId,
      'kind': kind.name,
      'createdAt': createdAt.toIso8601String(),
      'turnId': turnId,
      'turnIndex': turnIndex,
      'status': status,
      'questionLength': questionLength,
      'optionCount': optionCount,
      'selectedOptionKey': selectedOptionKey,
      'customResponseLength': customResponseLength,
      'source': source,
    };
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

int? _nullableInt(Object? value) {
  if (value == null) return null;
  return _int(value);
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

LoopUserActionKind _userActionKind(Object? value) {
  final name = value as String? ?? '';
  return LoopUserActionKind.values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => LoopUserActionKind.continueTask,
  );
}

LoopAutoActionState _autoActionState(Object? value) {
  final raw = value as String? ?? '';
  return LoopAutoActionState.values.firstWhere(
    (kind) => kind.name == raw,
    orElse: () => LoopAutoActionState.skipped,
  );
}

LoopApprovalEventKind _approvalEventKind(Object? value) {
  final name = value as String? ?? '';
  return LoopApprovalEventKind.values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => LoopApprovalEventKind.requested,
  );
}
