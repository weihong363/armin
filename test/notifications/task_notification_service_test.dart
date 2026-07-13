import 'package:armin/features/notifications/services/task_notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ironion.armin/task_notifications');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('show checks permission without requesting it implicitly', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'permissionStatus') return false;
      return null;
    });
    final service = NativeTaskNotificationService();

    await service.show(_notification());

    expect(calls, ['permissionStatus']);
  });

  test('permission request is only made through explicit action', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'requestPermission';
    });
    final service = NativeTaskNotificationService();

    final status = await service.requestPermission();

    expect(status, TaskNotificationPermission.granted);
    expect(calls, ['requestPermission']);
  });
}

TaskNotification _notification() => TaskNotification(
      id: 'task-result',
      taskId: 'task-1',
      kind: TaskNotificationKind.resultReady,
      title: '结果可验收',
      body: '任务已完成',
      createdAt: DateTime(2026, 7, 12),
    );
