enum NativeOutputTurnStatus {
  running,
  turnIdle,
  needAttention,
  runtimeLost,
  failed,
  completedByUser,
  failedByUser,
  stopped,
}

class NativeOutputTurn {
  const NativeOutputTurn({
    required this.id,
    required this.taskId,
    required this.turnIndex,
    required this.userInput,
    required this.rawOutput,
    required this.cleanedOutput,
    required this.startedAt,
    required this.lastOutputAt,
    required this.status,
    this.idleDetectedAt,
    this.userDecision,
  });

  final String id;
  final String taskId;
  final int turnIndex;
  final String userInput;
  final String rawOutput;
  final String cleanedOutput;
  final DateTime startedAt;
  final DateTime lastOutputAt;
  final DateTime? idleDetectedAt;
  final NativeOutputTurnStatus status;
  final String? userDecision;

  factory NativeOutputTurn.fromJson(Map<String, Object?> json) {
    return NativeOutputTurn(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      turnIndex: json['turnIndex'] as int? ?? 1,
      userInput: json['userInput'] as String? ?? '',
      rawOutput: json['rawOutput'] as String? ?? '',
      cleanedOutput: json['cleanedOutput'] as String? ?? '',
      startedAt: _date(json['startedAt']),
      lastOutputAt: _date(json['lastOutputAt']),
      idleDetectedAt: _nullableDate(json['idleDetectedAt']),
      status: _statusFromJson(json['status']),
      userDecision: json['userDecision'] as String?,
    );
  }

  NativeOutputTurn copyWith({
    String? id,
    String? taskId,
    int? turnIndex,
    String? userInput,
    String? rawOutput,
    String? cleanedOutput,
    DateTime? startedAt,
    DateTime? lastOutputAt,
    DateTime? idleDetectedAt,
    NativeOutputTurnStatus? status,
    String? userDecision,
  }) {
    return NativeOutputTurn(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      turnIndex: turnIndex ?? this.turnIndex,
      userInput: userInput ?? this.userInput,
      rawOutput: rawOutput ?? this.rawOutput,
      cleanedOutput: cleanedOutput ?? this.cleanedOutput,
      startedAt: startedAt ?? this.startedAt,
      lastOutputAt: lastOutputAt ?? this.lastOutputAt,
      idleDetectedAt: idleDetectedAt ?? this.idleDetectedAt,
      status: status ?? this.status,
      userDecision: userDecision ?? this.userDecision,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'turnIndex': turnIndex,
      'userInput': userInput,
      'rawOutput': rawOutput,
      'cleanedOutput': cleanedOutput,
      'startedAt': startedAt.toIso8601String(),
      'lastOutputAt': lastOutputAt.toIso8601String(),
      'idleDetectedAt': idleDetectedAt?.toIso8601String(),
      'status': status.name,
      'userDecision': userDecision,
    };
  }
}

DateTime _date(Object? value) {
  return DateTime.tryParse(value as String? ?? '') ?? DateTime.now();
}

DateTime? _nullableDate(Object? value) {
  return DateTime.tryParse(value as String? ?? '');
}

NativeOutputTurnStatus _statusFromJson(Object? value) {
  final name = value as String? ?? '';
  return NativeOutputTurnStatus.values.firstWhere(
    (status) => status.name == name,
    orElse: () => NativeOutputTurnStatus.running,
  );
}
