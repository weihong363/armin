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

  test('appendControlled updates repeated log updates', () {
    final first = MetricEvent.create(
      taskId: 'task-1',
      eventType: 'log_update',
      payloadJson: '{"bytes":10}',
      now: DateTime(2026, 5, 16, 10),
    );
    final second = MetricEvent.create(
      taskId: 'task-1',
      eventType: 'log_update',
      payloadJson: '{"bytes":20}',
      now: DateTime(2026, 5, 16, 10, 0, 1),
    );

    final events = MetricEvent.appendControlled(
      MetricEvent.appendControlled(const [], first),
      second,
    );

    expect(events, hasLength(1));
    expect(events.single.payloadJson, '{"bytes":20}');
  });

  test('appendControlled skips invalid empty metrics', () {
    final invalid = MetricEvent(
      id: 'metric-empty',
      taskId: 'task-1',
      eventType: '',
      payloadJson: '{}',
      createdAt: DateTime(2026, 5, 16),
    );

    final events = MetricEvent.appendControlled(const [], invalid);

    expect(events, isEmpty);
  });

  test('createIfUseful skips zero-byte log updates before construction', () {
    final event = MetricEvent.createIfUseful(
      taskId: 'task-1',
      eventType: 'log_update',
      payloadJson: '{"bytes":0}',
      now: DateTime(2026, 5, 16),
    );

    expect(event, isNull);
  });

  test('createIfUseful keeps informative log updates', () {
    final event = MetricEvent.createIfUseful(
      taskId: 'task-1',
      eventType: 'log_update',
      payloadJson: '{"bytes":24}',
      now: DateTime(2026, 5, 16),
    );

    expect(event, isNotNull);
    expect(event!.payloadJson, '{"bytes":24}');
  });

  test('appendControlled caps event count', () {
    var events = <MetricEvent>[];
    for (var index = 0; index < 5; index++) {
      events = MetricEvent.appendControlled(
        events,
        MetricEvent.create(
          taskId: 'task-1',
          eventType: 'event_$index',
          payloadJson: '{"index":$index}',
          now: DateTime(2026, 5, 16, 10, 0, index),
        ),
        maxEvents: 3,
      );
    }

    expect(events, hasLength(3));
    expect(events.map((event) => event.eventType), [
      'event_2',
      'event_3',
      'event_4',
    ]);
  });
}
