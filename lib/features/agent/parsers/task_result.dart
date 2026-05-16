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
}
