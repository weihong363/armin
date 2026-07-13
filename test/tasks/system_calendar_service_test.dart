import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/task_recurrence.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/system_calendar_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('calendar event carries stable task identity, schedule and recurrence',
      () async {
    const channel = MethodChannel('test/system_calendar');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final scheduledFor = DateTime(2026, 7, 14, 9, 30);
    final task = _task(scheduledFor);
    final opened = await const NativeSystemCalendarService(channel: channel)
        .upsertScheduledTask(task);

    expect(opened, isTrue);
    expect(captured?.method, 'upsertEvent');
    expect(captured?.arguments, {
      'taskId': 'calendar-task',
      'title': '检查项目状态',
      'description': '检查项目状态并输出摘要',
      'startAtMillis': scheduledFor.millisecondsSinceEpoch,
      'recurrence': 'weekly',
    });
  });

  test('calendar permission result is explicit', () async {
    const channel = MethodChannel('test/system_calendar_permission');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (call) async => call.method == 'requestPermission');
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const service = NativeSystemCalendarService(channel: channel);
    expect(await service.permissionStatus(), SystemCalendarPermission.denied);
    expect(await service.requestPermission(), SystemCalendarPermission.granted);
  });
}

TaskSession _task(DateTime scheduledFor) {
  final now = DateTime(2026, 7, 13);
  return TaskSession(
    id: 'calendar-task',
    host: HostConfig(
      id: 'host',
      name: 'Local Mac',
      host: '10.0.2.2',
      port: 22,
      username: 'user',
      authType: HostAuthType.password,
      projectPath: '/tmp/project',
      tmuxSessionName: 'armin-calendar',
      agentCommand: 'qodercli',
      createdAt: now,
      updatedAt: now,
    ),
    title: '检查项目状态',
    createdAt: now,
    updatedAt: now,
    scheduledFor: scheduledFor,
    recurrence: TaskRecurrence.weekly,
    rawSttText: '',
    cleanedDraft: '',
    userText: '检查项目状态并输出摘要',
    context: '',
    constraints: const {},
    finalPrompt: '',
    secretRecords: const [],
    approvalMode: AgentApprovalMode.balanced,
  );
}
