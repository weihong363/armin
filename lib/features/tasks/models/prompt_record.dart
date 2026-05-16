class PromptRecord {
  const PromptRecord({
    required this.id,
    required this.taskId,
    required this.finalPrompt,
    required this.templateVersion,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final String finalPrompt;
  final String templateVersion;
  final DateTime createdAt;

  factory PromptRecord.fromJson(Map<String, Object?> json) {
    return PromptRecord(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      finalPrompt: json['finalPrompt'] as String? ?? '',
      templateVersion: json['templateVersion'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'finalPrompt': finalPrompt,
      'templateVersion': templateVersion,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
