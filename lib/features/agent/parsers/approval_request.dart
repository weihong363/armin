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

  factory ApprovalRequest.fromJson(Map<String, Object?> json) {
    return ApprovalRequest(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      command: json['command'] as String? ?? '',
      risk: json['risk'] as String? ?? 'medium',
      status: json['status'] as String? ?? 'pending',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      resolvedAt: DateTime.tryParse(json['resolvedAt'] as String? ?? ''),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'reason': reason,
      'command': command,
      'risk': risk,
      'status': status,
      'createdAt': createdAt?.toIso8601String(),
      'resolvedAt': resolvedAt?.toIso8601String(),
    };
  }
}
