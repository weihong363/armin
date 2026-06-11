import '../models/approval_state.dart';
import '../models/runtime_diagnostics.dart';
import '../models/runtime_task_snapshot.dart';
import '../models/work_state.dart';
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

  /// Per-task diagnostics for debugging (not exposed to end users).
  final Map<String, RuntimeDiagnostics> _diagnostics = {};

  /// Per-task WorkState for UI consumption.
  final Map<String, WorkState> _workStates = {};

  /// Returns diagnostic snapshot for a task.
  RuntimeDiagnostics? diagnostics(String taskId) => _diagnostics[taskId];

  /// Returns current WorkState for a task.
  WorkState? workState(String taskId) => _workStates[taskId];

  Future<RuntimeTaskSnapshot> createTask(RuntimeTaskSnapshot task) async {
    _validateTaskId(task.taskId);
    await taskStore.saveTask(task);
    _publish(RuntimeEventType.taskCreated, task);
    _ensureDiagnostics(task.taskId);
    _updateWorkState(task.taskId, WorkPhase.idle, 'Task created.', '');
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
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          runId: session.id,
          sessionName: session.tmuxSessionName,
          observerState: 'attached',
          updatedAt: observedAt,
        ));
    _publishDirect(RuntimeEventType.observerAttached, taskId, observedAt, updated);
    _updateWorkState(taskId, WorkPhase.working, 'Agent started.', '');
    return updated;
  }

  Future<RuntimeTaskSnapshot> pauseTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.waitingUser,
      RuntimeEventType.taskPaused,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> resumeTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.running,
      RuntimeEventType.taskResumed,
      summary: summary,
      now: now,
    );
  }

  Future<RuntimeTaskSnapshot> stopTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) {
    return _transition(
      taskId,
      RuntimeTaskStatus.cancelled,
      RuntimeEventType.taskStopped,
      summary: summary,
      now: now,
    );
  }

  /// Publish observer attached event.
  void notifyObserverAttached(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.observerAttached, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          observerState: 'attached',
          updatedAt: observedAt,
        ));
  }

  /// Publish observer detached event.
  void notifyObserverDetached(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.observerDetached, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          observerState: 'detached',
          updatedAt: observedAt,
        ));
  }

  /// Publish connection lost event.
  void notifyConnectionLost(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.connectionLost, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          observerState: 'connection_lost',
          updatedAt: observedAt,
        ));
  }

  /// Publish connection restored event.
  void notifyConnectionRestored(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.connectionRestored, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          observerState: 'attached',
          updatedAt: observedAt,
        ));
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

  /// Publish an approval requested event.
  void notifyApprovalRequested(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalRequested, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          approvalState: ApprovalState.pending,
          updatedAt: observedAt,
        ));
    _updateWorkState(taskId, WorkPhase.needsApproval, 'Agent needs your approval.', '');
  }

  /// Publish an approval resolving event (user action sent to terminal).
  void notifyApprovalResolving(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalResolving, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          approvalState: ApprovalState.resolving,
          updatedAt: observedAt,
        ));
    _updateWorkState(taskId, WorkPhase.working, 'Processing your decision...', '');
  }

  /// Publish an approval resolved event.
  void notifyApprovalResolved(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalResolved, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          approvalState: ApprovalState.resolved,
          updatedAt: observedAt,
        ));
    _updateWorkState(taskId, WorkPhase.working, 'Agent continuing.', '');
  }

  /// Publish an approval rejected event.
  void notifyApprovalRejected(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalRejected, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          approvalState: ApprovalState.resolved,
          updatedAt: observedAt,
        ));
  }

  /// Publish an approval failed event.
  void notifyApprovalFailed(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalFailed, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          approvalState: ApprovalState.failed,
          updatedAt: observedAt,
        ));
    _updateWorkState(taskId, WorkPhase.needsApproval,
        'Approval action failed.', 'Please try again.');
  }

  /// Publish an output updated event.
  void notifyOutputUpdated(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.outputUpdated, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          lastObservedOutputTime: observedAt,
          updatedAt: observedAt,
        ));
  }

  /// Publish a deliverable updated event.
  void notifyDeliverableUpdated(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.deliverableUpdated, taskId, observedAt, null);
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          lastDeliverableUpdate: observedAt,
          updatedAt: observedAt,
        ));
  }

  /// Publish a review submitted event.
  void notifyReviewSubmitted(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.reviewSubmitted, taskId, observedAt, null);
    _updateWorkState(taskId, WorkPhase.working, 'Review submitted.', '');
  }

  // ─── Private helpers ───

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
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          lastRuntimeEventType: eventType.wireName,
          eventCount: d.eventCount + 1,
          updatedAt: updated.updatedAt,
        ));
    // Update WorkState based on transition
    switch (status) {
      case RuntimeTaskStatus.running:
        _updateWorkState(taskId, WorkPhase.working, '', summary);
      case RuntimeTaskStatus.waitingUser:
        _updateWorkState(taskId, WorkPhase.turnIdle, 'Waiting for you.', summary);
      case RuntimeTaskStatus.completed:
        _updateWorkState(taskId, WorkPhase.completed, 'Task completed.', summary);
      case RuntimeTaskStatus.failed:
        _updateWorkState(taskId, WorkPhase.failed, 'Task failed.', summary);
      case RuntimeTaskStatus.cancelled:
        _updateWorkState(taskId, WorkPhase.stopped, 'Task stopped.', summary);
      case RuntimeTaskStatus.pending:
        break;
    }
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
    _diagnosticsUpdate(snapshot.taskId, (d) => d.copyWith(
          lastRuntimeEventType: type.wireName,
          eventCount: d.eventCount + 1,
          updatedAt: snapshot.updatedAt,
        ));
  }

  /// Publishes an event without requiring a snapshot.
  void _publishDirect(
    RuntimeEventType type,
    String taskId,
    DateTime createdAt,
    RuntimeTaskSnapshot? snapshot,
  ) {
    eventBus.publish(
      RuntimeEvent(
        type: type,
        taskId: taskId,
        createdAt: createdAt,
        snapshot: snapshot,
      ),
    );
  }

  void _ensureDiagnostics(String taskId) {
    _diagnostics.putIfAbsent(
      taskId,
      () => RuntimeDiagnostics(
        taskId: taskId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  void _diagnosticsUpdate(
    String taskId,
    RuntimeDiagnostics Function(RuntimeDiagnostics) update,
  ) {
    final current = _diagnostics[taskId];
    if (current != null) {
      _diagnostics[taskId] = update(current);
    } else {
      _ensureDiagnostics(taskId);
      final created = _diagnostics[taskId]!;
      _diagnostics[taskId] = update(created);
    }
  }

  void _updateWorkState(
    String taskId,
    WorkPhase phase,
    String headline,
    String detail,
  ) {
    _workStates[taskId] = WorkState(
      taskId: taskId,
      phase: phase,
      headline: headline,
      detail: detail,
      updatedAt: DateTime.now(),
    );
    _diagnosticsUpdate(taskId, (d) => d.copyWith(
          workPhase: phase,
          updatedAt: DateTime.now(),
        ));
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
