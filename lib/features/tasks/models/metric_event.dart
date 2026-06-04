import 'dart:convert';

class MetricEvent {
  static const maxStoredEvents = 80;

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

  static MetricEvent? createIfUseful({
    required String taskId,
    required String eventType,
    required String payloadJson,
    DateTime? now,
  }) {
    if (!_hasUsefulContent(eventType: eventType, payloadJson: payloadJson)) {
      return null;
    }
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

  bool get hasUsefulPayload {
    return _hasUsefulContent(
      eventType: eventType,
      payloadJson: payloadJson,
    );
  }

  String get mergeKey {
    final type = eventType.trim();
    if (_coalescedEventTypes.contains(type)) {
      return type;
    }
    return '$type|${payloadJson.trim()}';
  }

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

  static List<MetricEvent> appendControlled(
    List<MetricEvent> events,
    MetricEvent event, {
    int maxEvents = maxStoredEvents,
  }) {
    if (!event.hasUsefulPayload) {
      return _tail(events, maxEvents);
    }
    final nextEvents = List<MetricEvent>.of(events);
    final existingIndex = nextEvents.lastIndexWhere(
      (item) => item.mergeKey == event.mergeKey,
    );
    if (existingIndex >= 0) {
      nextEvents[existingIndex] = event;
    } else {
      nextEvents.add(event);
    }
    return _tail(nextEvents, maxEvents);
  }

  static List<MetricEvent> _tail(List<MetricEvent> events, int maxEvents) {
    if (events.length <= maxEvents) {
      return List<MetricEvent>.unmodifiable(events);
    }
    return List<MetricEvent>.unmodifiable(
      events.skip(events.length - maxEvents),
    );
  }

  static const Set<String> _coalescedEventTypes = {
    'log_update',
    'turn_idle',
    'need_attention',
    'runtime_control',
  };

  static bool _hasUsefulContent({
    required String eventType,
    required String payloadJson,
  }) {
    final payload = payloadJson.trim();
    if (eventType.trim().isEmpty ||
        payload.isEmpty ||
        payload == '{}' ||
        payload == 'null') {
      return false;
    }
    if (eventType.trim() != 'log_update') {
      return true;
    }
    return _logUpdateBytes(payload) > 0;
  }

  static int _logUpdateBytes(String payloadJson) {
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is Map<String, dynamic>) {
        final bytes = decoded['bytes'];
        if (bytes is int) {
          return bytes;
        }
        if (bytes is num) {
          return bytes.toInt();
        }
      }
    } catch (_) {
      return 0;
    }
    return 0;
  }
}
