class SecretEntry {
  const SecretEntry({
    required this.name,
    required this.value,
    required this.usage,
    this.oneTimeOnly = true,
  });

  final String name;
  final String value;
  final String usage;
  final bool oneTimeOnly;

  String get placeholder => '$name: [REDACTED]';

  SecretRedactedRecord toRedactedRecord({
    String taskId = '',
    DateTime? createdAt,
  }) {
    return SecretRedactedRecord(
      id: taskId.isEmpty ? name : 'secret-$taskId-$name',
      taskId: taskId,
      name: name,
      usage: usage,
      redactedValue: '[REDACTED]',
      scope: oneTimeOnly ? 'current_task_only' : 'reusable',
      placeholder: placeholder,
      oneTimeOnly: oneTimeOnly,
      createdAt: createdAt,
    );
  }
}

class SecretRedactedRecord {
  const SecretRedactedRecord({
    this.id = '',
    this.taskId = '',
    required this.name,
    required this.usage,
    this.redactedValue = '[REDACTED]',
    this.scope = 'current_task_only',
    required this.placeholder,
    required this.oneTimeOnly,
    this.createdAt,
  });

  final String id;
  final String taskId;
  final String name;
  final String usage;
  final String redactedValue;
  final String scope;
  final String placeholder;
  final bool oneTimeOnly;
  final DateTime? createdAt;
}
