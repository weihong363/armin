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
}
