import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class ScheduledTaskWakeService {
  Future<void> initialize();

  Future<bool> schedule(String taskId, DateTime scheduledFor);

  Future<void> cancel(String taskId);
}

class NoopScheduledTaskWakeService implements ScheduledTaskWakeService {
  const NoopScheduledTaskWakeService();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> schedule(String taskId, DateTime scheduledFor) async => false;

  @override
  Future<void> cancel(String taskId) async {}
}

class NativeScheduledTaskWakeService implements ScheduledTaskWakeService {
  const NativeScheduledTaskWakeService({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'com.ironion.armin/scheduled_tasks';
  final MethodChannel _channel;

  @override
  Future<void> initialize() async {
    if (!_isSupportedPlatform) return;
    await _channel.invokeMethod<void>('initialize');
  }

  @override
  Future<bool> schedule(String taskId, DateTime scheduledFor) async {
    if (!_isSupportedPlatform) return false;
    return await _channel.invokeMethod<bool>('schedule', {
          'taskId': taskId,
          'scheduledAtMillis': scheduledFor.millisecondsSinceEpoch,
        }) ??
        false;
  }

  @override
  Future<void> cancel(String taskId) async {
    if (!_isSupportedPlatform) return;
    await _channel.invokeMethod<void>('cancel', {'taskId': taskId});
  }

  bool get _isSupportedPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
