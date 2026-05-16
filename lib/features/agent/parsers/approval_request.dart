class ApprovalRequest {
  const ApprovalRequest({
    this.id = '',
    this.taskId = '',
    required this.reason,
    required this.command,
    required this.risk,
    this.status = 'pending',
    this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String taskId;
  final String reason;
  final String command;
  final String risk;
  final String status;
  final DateTime? createdAt;
  final DateTime? resolvedAt;
}
