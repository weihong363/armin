import 'dart:async';

import '../models/runtime_task_snapshot.dart';

enum RuntimeEventType {
  taskCreated,
  taskStarted,
  taskProgress,
  taskWaitingUser,
  taskCompleted,
  taskFailed,
  taskCancelled,
}

extension RuntimeEventTypeWireName on RuntimeEventType {
  String get wireName {
    return switch (this) {
      RuntimeEventType.taskCreated => 'TASK_CREATED',
      RuntimeEventType.taskStarted => 'TASK_STARTED',
      RuntimeEventType.taskProgress => 'TASK_PROGRESS',
      RuntimeEventType.taskWaitingUser => 'TASK_WAITING_USER',
      RuntimeEventType.taskCompleted => 'TASK_COMPLETED',
      RuntimeEventType.taskFailed => 'TASK_FAILED',
      RuntimeEventType.taskCancelled => 'TASK_CANCELLED',
    };
  }
}

class RuntimeEvent {
  const RuntimeEvent({
    required this.type,
    required this.taskId,
    required this.createdAt,
    this.snapshot,
    this.message = '',
  });

  final RuntimeEventType type;
  final String taskId;
  final DateTime createdAt;
  final RuntimeTaskSnapshot? snapshot;
  final String message;
}

class RuntimeEventBus {
  RuntimeEventBus();

  final _controller = StreamController<RuntimeEvent>.broadcast();

  Stream<RuntimeEvent> get events => _controller.stream;

  void publish(RuntimeEvent event) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(event);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
