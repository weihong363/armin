class MetricEvent {
  const MetricEvent({
    required this.id,
    required this.taskId,
    required this.eventType,
    required this.payloadJson,
    required this.createdAt,
  });

  factory MetricEvent.create({
    required String taskId,
    required String eventType,
    required String payloadJson,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return MetricEvent(
      id: 'metric-${timestamp.microsecondsSinceEpoch}',
      taskId: taskId,
      eventType: eventType,
      payloadJson: payloadJson,
      createdAt: timestamp,
    );
  }

  final String id;
  final String taskId;
  final String eventType;
  final String payloadJson;
  final DateTime createdAt;

  factory MetricEvent.fromJson(Map<String, Object?> json) {
    return MetricEvent(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      eventType: json['eventType'] as String? ?? '',
      payloadJson: json['payloadJson'] as String? ?? '{}',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'eventType': eventType,
      'payloadJson': payloadJson,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
