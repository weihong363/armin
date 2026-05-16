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
}
