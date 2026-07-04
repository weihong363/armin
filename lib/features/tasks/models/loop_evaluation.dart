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

enum LoopUserActionKind {
  continueTask,
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
