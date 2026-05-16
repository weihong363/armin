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
}
