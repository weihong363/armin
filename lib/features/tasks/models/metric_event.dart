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
}
