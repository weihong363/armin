import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/tasks/models/metric_event.dart';

void main() {
  test('MetricEvent records event payload', () {
    final now = DateTime(2026, 5, 16);
    final event = MetricEvent.create(
      taskId: 'task-1',
      eventType: 'task_started',
      payloadJson: '{"agent_command":"codex"}',
      now: now,
    );

    expect(event.taskId, 'task-1');
    expect(event.eventType, 'task_started');
    expect(event.payloadJson, contains('codex'));
    expect(event.createdAt, now);
  });
}
