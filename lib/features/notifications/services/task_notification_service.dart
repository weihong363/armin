import 'dart:async';

import 'package:flutter/services.dart';

enum TaskNotificationKind {
  approvalRequired,
  needsInstruction,
  resultReady,
  runtimeLost,
  taskCompleted,
  taskFailed,
  scheduleSkipped,
}

enum TaskNotificationPermission { granted, denied, unsupported }

class TaskNotification {
  const TaskNotification({
    required this.id,
    required this.taskId,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.turnId,
    this.evidenceFingerprint,
  });

  final String id;
  final String taskId;
  final TaskNotificationKind kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? turnId;
  final String? evidenceFingerprint;
}

abstract interface class TaskNotificationService {
  Future<TaskNotificationPermission> permissionStatus();

  Future<TaskNotificationPermission> requestPermission();

  Future<void> show(TaskNotification notification);

  Stream<String> get openedTaskIds;

  Future<String?> consumePendingTaskId();
}

class NoopTaskNotificationService implements TaskNotificationService {
  const NoopTaskNotificationService();

  @override
  Future<TaskNotificationPermission> permissionStatus() async =>
      TaskNotificationPermission.unsupported;

  @override
  Future<TaskNotificationPermission> requestPermission() async =>
      TaskNotificationPermission.unsupported;

  @override
  Future<void> show(TaskNotification notification) async {}

  @override
  Stream<String> get openedTaskIds => const Stream<String>.empty();

  @override
  Future<String?> consumePendingTaskId() async => null;
}

/// Native system-notification adapter for the production app path.
///
/// This adapter only surfaces user-visible Runtime events. It never mutates
/// task state, so notification delivery cannot create a second Runtime source.
class NativeTaskNotificationService implements TaskNotificationService {
  NativeTaskNotificationService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const _channel = MethodChannel('com.ironion.armin/task_notifications');
  final _openedTaskIds = StreamController<String>.broadcast();

  @override
  Stream<String> get openedTaskIds => _openedTaskIds.stream;

  @override
  Future<TaskNotificationPermission> permissionStatus() async {
    final granted = await _channel.invokeMethod<bool>('permissionStatus');
    return granted == true
        ? TaskNotificationPermission.granted
        : TaskNotificationPermission.denied;
  }

  @override
  Future<TaskNotificationPermission> requestPermission() async {
    final granted =
        await _channel.invokeMethod<bool>('requestPermission') ?? false;
    return granted
        ? TaskNotificationPermission.granted
        : TaskNotificationPermission.denied;
  }

  @override
  Future<void> show(TaskNotification notification) async {
    if (await permissionStatus() != TaskNotificationPermission.granted) {
      return;
    }
    await _channel.invokeMethod<void>('show', {
      'id': notification.id,
      'taskId': notification.taskId,
      'kind': notification.kind.name,
      'title': notification.title,
      'body': notification.body,
    });
  }

  @override
  Future<String?> consumePendingTaskId() {
    return _channel.invokeMethod<String>('consumePendingTaskId');
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'opened') {
      return;
    }
    final taskId = (call.arguments as Map<Object?, Object?>?)?['taskId']
        ?.toString()
        .trim();
    if (taskId != null && taskId.isNotEmpty) {
      _openedTaskIds.add(taskId);
    }
  }
}
