class TaskResult {
  const TaskResult({
    this.id = '',
    this.taskId = '',
    required this.status,
    required this.summary,
    required this.changedFiles,
    required this.validation,
    required this.risks,
    required this.nextActions,
    this.createdAt,
  });

  final String id;
  final String taskId;
  final String status;
  final String summary;
  final List<String> changedFiles;
  final List<String> validation;
  final List<String> risks;
  final List<String> nextActions;
  final DateTime? createdAt;

  factory TaskResult.fromJson(Map<String, Object?> json) {
    return TaskResult(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      status: json['status'] as String? ?? 'failed',
      summary: json['summary'] as String? ?? '',
      changedFiles: _stringList(json['changedFiles']),
      validation: _stringList(json['validation']),
      risks: _stringList(json['risks']),
      nextActions: _stringList(json['nextActions']),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'status': status,
      'summary': summary,
      'changedFiles': changedFiles,
      'validation': validation,
      'risks': risks,
      'nextActions': nextActions,
      'createdAt': createdAt?.toIso8601String(),
    };
  }
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const [];
}
