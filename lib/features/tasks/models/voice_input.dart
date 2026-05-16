class VoiceInput {
  const VoiceInput({
    required this.id,
    required this.taskId,
    required this.rawSttText,
    required this.language,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final String rawSttText;
  final String language;
  final DateTime createdAt;

  factory VoiceInput.fromJson(Map<String, Object?> json) {
    return VoiceInput(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      rawSttText: json['rawSttText'] as String? ?? '',
      language: json['language'] as String? ?? 'zh-CN',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'rawSttText': rawSttText,
      'language': language,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
