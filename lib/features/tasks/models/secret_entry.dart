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

  factory SecretRedactedRecord.fromJson(Map<String, Object?> json) {
    return SecretRedactedRecord(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      usage: json['usage'] as String? ?? '',
      redactedValue: json['redactedValue'] as String? ?? '[REDACTED]',
      scope: json['scope'] as String? ?? 'current_task_only',
      placeholder: json['placeholder'] as String? ?? '',
      oneTimeOnly: json['oneTimeOnly'] as bool? ?? true,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'name': name,
      'usage': usage,
      'redactedValue': redactedValue,
      'scope': scope,
      'placeholder': placeholder,
      'oneTimeOnly': oneTimeOnly,
      'createdAt': createdAt?.toIso8601String(),
    };
  }
}
