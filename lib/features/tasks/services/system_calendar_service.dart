import 'package:flutter/services.dart';

import '../models/task_session.dart';

enum SystemCalendarPermission { granted, denied }

abstract interface class SystemCalendarService {
  Future<SystemCalendarPermission> permissionStatus();

  Future<SystemCalendarPermission> requestPermission();

  Future<bool> upsertScheduledTask(TaskSession task);

  Future<void> removeScheduledTask(String taskId);
}

class NoopSystemCalendarService implements SystemCalendarService {
  const NoopSystemCalendarService();

  @override
  Future<SystemCalendarPermission> permissionStatus() async =>
      SystemCalendarPermission.denied;

  @override
  Future<SystemCalendarPermission> requestPermission() async =>
      SystemCalendarPermission.denied;

  @override
  Future<bool> upsertScheduledTask(TaskSession task) async => false;

  @override
  Future<void> removeScheduledTask(String taskId) async {}
}

class NativeSystemCalendarService implements SystemCalendarService {
  const NativeSystemCalendarService({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'com.ironion.armin/system_calendar';
  final MethodChannel _channel;

  @override
  Future<SystemCalendarPermission> permissionStatus() async =>
      _permission(await _channel.invokeMethod<bool>('permissionStatus'));

  @override
  Future<SystemCalendarPermission> requestPermission() async =>
      _permission(await _channel.invokeMethod<bool>('requestPermission'));

  @override
  Future<bool> upsertScheduledTask(TaskSession task) async {
    final scheduledFor = task.scheduledFor;
    if (scheduledFor == null) return false;
    return await _channel.invokeMethod<bool>('upsertEvent', {
          'taskId': task.id,
          'title': task.displayTitle,
          'description': task.userText.trim(),
          'startAtMillis': scheduledFor.millisecondsSinceEpoch,
          'recurrence': task.recurrence.name,
        }) ??
        false;
  }

  @override
  Future<void> removeScheduledTask(String taskId) =>
      _channel.invokeMethod<void>('removeEvent', {'taskId': taskId});

  SystemCalendarPermission _permission(bool? granted) => granted == true
      ? SystemCalendarPermission.granted
      : SystemCalendarPermission.denied;
}
