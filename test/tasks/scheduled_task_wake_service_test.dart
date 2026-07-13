import 'package:armin/features/tasks/services/scheduled_task_wake_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/scheduled_tasks');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'schedule';
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native service schedules and cancels one platform alarm per task',
      () async {
    const service = NativeScheduledTaskWakeService(channel: channel);
    final scheduledFor = DateTime.fromMillisecondsSinceEpoch(1750000000000);

    await service.initialize();
    expect(await service.schedule('task-1', scheduledFor), isTrue);
    await service.cancel('task-1');

    expect(calls.map((call) => call.method), [
      'initialize',
      'schedule',
      'cancel',
    ]);
    expect(calls[1].arguments, {
      'taskId': 'task-1',
      'scheduledAtMillis': scheduledFor.millisecondsSinceEpoch,
    });
    expect(calls[2].arguments, {'taskId': 'task-1'});
  });

  test('native service stays inactive on unsupported platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const service = NativeScheduledTaskWakeService(channel: channel);

    await service.initialize();
    expect(await service.schedule('task-1', DateTime.now()), isFalse);
    await service.cancel('task-1');

    expect(calls, isEmpty);
  });
}
