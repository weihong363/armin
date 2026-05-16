class ExecutionLog {
  const ExecutionLog({
    required this.id,
    required this.taskId,
    required this.rawOutput,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final String rawOutput;
  final DateTime createdAt;

  factory ExecutionLog.fromJson(Map<String, Object?> json) {
    return ExecutionLog(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      rawOutput: json['rawOutput'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'rawOutput': rawOutput,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
