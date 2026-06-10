import '../models/runtime_task_snapshot.dart';
import 'runtime_event_bus.dart';
import 'runtime_session_manager.dart';
import 'runtime_task_store.dart';
import 'task_watcher.dart';

class BridgeRuntime {
  BridgeRuntime({
    required this.taskStore,
    required this.eventBus,
    RuntimeSessionManager? sessionManager,
    TaskWatcher? watcher,
  })  : sessionManager = sessionManager ?? RuntimeSessionManager(),
        watcher = watcher ?? TaskWatcher();

  final RuntimeTaskStore taskStore;
  final RuntimeEventBus eventBus;
  final RuntimeSessionManager sessionManager;
  final TaskWatcher watcher;

  Future<RuntimeTaskSnapshot> createTask(RuntimeTaskSnapshot task) async {
    _validateTaskId(task.taskId);
    await taskStore.saveTask(task);
    _publish(RuntimeEventType.taskCreated, task);
    return task;
  }

  Future<RuntimeTaskSnapshot> startTask({
    required String taskId,
    required String sessionName,
    required String projectPath,
    required String tmuxSessionName,
    DateTime? now,
  }) async {
    _validateTaskId(taskId);
    final observedAt = now ?? DateTime.now();
    final current = await _requireTask(taskId);
    final session = sessionManager.createOrRestore(
      name: sessionName,
      projectPath: projectPath,
      tmuxSessionName: tmuxSessionName,
      now: observedAt,
    );
    sessionManager.attachTask(session.id, taskId, now: observedAt);
    final updated = current.copyWith(
      status: RuntimeTaskStatus.running,
      sessionId: session.id,
      updatedAt: observedAt,
    );
    await taskStore.saveTask(updated);
    _publish(RuntimeEventType.taskStarted, updated);
    return updated;
  }

  Future<RuntimeTaskSnapshot?> observeOutput({
    required String taskId,
    required String capturedOutput,
    DateTime? now,
  }) async {
    _validateTaskId(taskId);
    final current = await _requireTask(taskId);
    final update = watcher.observe(
      taskId: taskId,
      capturedOutput: capturedOutput,
    );
    if (!update.hasUsefulUpdate) {
      return null;
    }
    final observedAt = now ?? DateTime.now();
    final nextStatus = update.status ?? current.status;
    final updated = current.copyWith(
      status: nextStatus,
      updatedAt: observedAt,
      action: update.action.isEmpty ? current.action : update.action,
      currentStep: update.action.isEmpty ? current.currentStep : update.action,
      progress: update.progress ?? current.progress,
      lastLogOffset: update.lastOffset,
      checkpoint:
          update.checkpoint.isEmpty ? current.checkpoint : update.checkpoint,
      summary: update.action.isEmpty ? current.summary : update.action,
    );
    await taskStore.saveTask(updated);
    _publish(_eventTypeForStatus(nextStatus), updated);
    return updated;
  }

  Future<RuntimeTaskSnapshot> markWaitingUser(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.waitingUser,
      RuntimeEventType.taskWaitingUser,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> completeTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.completed,
      RuntimeEventType.taskCompleted,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> failTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.failed,
      RuntimeEventType.taskFailed,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> cancelTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.cancelled,
      RuntimeEventType.taskCancelled,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> _transition(
    String taskId,
    RuntimeTaskStatus status,
    RuntimeEventType eventType, {
    required String summary,
    DateTime? now,
  }) async {
    _validateTaskId(taskId);
    final current = await _requireTask(taskId);
    final updated = current.copyWith(
      status: status,
      updatedAt: now ?? DateTime.now(),
      summary: summary.trim().isEmpty ? current.summary : summary.trim(),
    );
    await taskStore.saveTask(updated);
    _publish(eventType, updated);
    return updated;
  }

  Future<RuntimeTaskSnapshot> _requireTask(String taskId) async {
    final task = await taskStore.loadTask(taskId);
    if (task == null) {
      throw StateError('Runtime task not found: $taskId');
    }
    return task;
  }

  void _publish(RuntimeEventType type, RuntimeTaskSnapshot snapshot) {
    eventBus.publish(
      RuntimeEvent(
        type: type,
        taskId: snapshot.taskId,
        createdAt: snapshot.updatedAt,
        snapshot: snapshot,
      ),
    );
  }

  RuntimeEventType _eventTypeForStatus(RuntimeTaskStatus status) {
    return switch (status) {
      RuntimeTaskStatus.pending => RuntimeEventType.taskCreated,
      RuntimeTaskStatus.running => RuntimeEventType.taskProgress,
      RuntimeTaskStatus.waitingUser => RuntimeEventType.taskWaitingUser,
      RuntimeTaskStatus.completed => RuntimeEventType.taskCompleted,
      RuntimeTaskStatus.failed => RuntimeEventType.taskFailed,
      RuntimeTaskStatus.cancelled => RuntimeEventType.taskCancelled,
    };
  }

  void _validateTaskId(String taskId) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'Task id is required.');
    }
  }
}
