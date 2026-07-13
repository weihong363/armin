import 'dart:async';

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
  final Map<String, Future<void>> _durableWriteChains = {};

  /// Per-task diagnostics for debugging (not exposed to end users).
  final Map<String, RuntimeDiagnostics> _diagnostics = {};

  /// Per-task WorkState for UI consumption.
  final Map<String, WorkState> _workStates = {};
  final Map<String, String> _reconcileHashes = {};
  final Map<String, int> _reconcileStableCounts = {};
  Timer? _reconcileTimer;
  bool _reconcileRunning = false;

  /// Returns diagnostic snapshot for a task.
  RuntimeDiagnostics? diagnostics(String taskId) => _diagnostics[taskId];

  /// Returns current WorkState for a task.
  WorkState? workState(String taskId) => _workStates[taskId];

  void startReconcileLoop({
    required Future<List<RuntimeReconcileTarget>> Function() loadTargets,
    required Future<RuntimeRemoteProbe> Function(RuntimeReconcileTarget target)
        probe,
    required Future<void> Function(RuntimeReconcileDecision decision)
        onDecision,
    Duration interval = const Duration(seconds: 30),
    int maxTasksPerRun = 3,
    Duration probeTimeout = const Duration(seconds: 3),
  }) {
    _reconcileTimer ??= Timer.periodic(interval, (_) {
      unawaited(_runReconcileLoop(
        loadTargets: loadTargets,
        probe: probe,
        onDecision: onDecision,
        maxTasksPerRun: maxTasksPerRun,
        probeTimeout: probeTimeout,
      ));
    });
  }

  void stopReconcileLoop() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  Future<List<RuntimeReconcileDecision>> reconcileOnce({
    required List<RuntimeReconcileTarget> targets,
    required Future<RuntimeRemoteProbe> Function(RuntimeReconcileTarget target)
        probe,
    int maxTasksPerRun = 3,
    Duration probeTimeout = const Duration(seconds: 3),
  }) async {
    if (_reconcileRunning) {
      return const [];
    }
    _reconcileRunning = true;
    final decisions = <RuntimeReconcileDecision>[];
    try {
      final candidates = targets
          .where((target) => target.status == RuntimeTaskStatus.running)
          .take(maxTasksPerRun);
      for (final target in candidates) {
        final RuntimeRemoteProbe remoteProbe;
        try {
          remoteProbe = await probe(target).timeout(probeTimeout);
        } on TimeoutException {
          continue;
        } catch (_) {
          continue;
        }
        final decision = _reconcileDecisionFor(target, remoteProbe);
        if (decision.action != RuntimeReconcileAction.none) {
          decisions.add(decision);
        }
      }
      return decisions;
    } finally {
      _reconcileRunning = false;
    }
  }

  Future<RuntimeTaskSnapshot?> taskSnapshot(String taskId) {
    _validateTaskId(taskId);
    return taskStore.loadTask(taskId);
  }

  Future<List<RuntimeEvent>> archivedEvents({
    required String taskId,
    int? afterArchiveId,
    int limit = 100,
  }) async {
    _validateTaskId(taskId);
    if (limit <= 0 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 500.');
    }
    final store = taskStore;
    if (store is! RuntimePersistenceStore) return const [];
    return store.loadEvents(
      taskId: taskId,
      afterArchiveId: afterArchiveId,
      limit: limit,
    );
  }

  Future<void> drainDurableWrites() async {
    while (_durableWriteChains.isNotEmpty) {
      await Future.wait(_durableWriteChains.values.toList(growable: false));
    }
  }

  Future<int?> replayArchivedEvents({
    required String taskId,
    int? afterArchiveId,
    int limit = 100,
    required FutureOr<void> Function(RuntimeEvent event) onEvent,
  }) async {
    final events = await archivedEvents(
      taskId: taskId,
      afterArchiveId: afterArchiveId ?? 0,
      limit: limit,
    );
    for (final event in events) {
      await onEvent(event);
    }
    return events.isEmpty ? afterArchiveId : events.last.archiveId;
  }

  Future<RuntimeTaskSnapshot> projectTaskState({
    required String taskId,
    required RuntimeTaskStatus status,
    required WorkState workState,
    String summary = '',
    DateTime? now,
  }) async {
    _validateTaskId(taskId);
    final observedAt = now ?? DateTime.now();
    final current = await _requireTask(taskId);
    final projectedWorkState = workState.copyWith(updatedAt: observedAt);
    final updated = current.copyWith(
      status: status,
      updatedAt: observedAt,
      summary: summary.trim().isEmpty ? current.summary : summary.trim(),
      workState: projectedWorkState,
    );
    await taskStore.saveTask(updated);
    _workStates[taskId] = projectedWorkState;
    await _saveWorkState(projectedWorkState);
    _diagnosticsUpdate(
      taskId,
      (d) => d.copyWith(
        workPhase: projectedWorkState.phase,
        updatedAt: observedAt,
      ),
    );
    return updated;
  }

  Future<void> restoreDurableState() async {
    final store = taskStore;
    if (store is! RuntimePersistenceStore) {
      return;
    }
    final snapshots = await store.loadTasks();
    for (final snapshot in snapshots) {
      if (snapshot.lastOutputFingerprint.isEmpty) {
        continue;
      }
      watcher.restoreCheckpoint(
        taskId: snapshot.taskId,
        lastOffset: snapshot.lastLogOffset,
        outputFingerprint: snapshot.lastOutputFingerprint,
      );
    }
    final workStates = await store.loadWorkStates();
    for (final state in workStates) {
      _workStates[state.taskId] = state;
      _diagnosticsUpdate(
          state.taskId,
          (d) => d.copyWith(
                workPhase: state.phase,
                updatedAt: state.updatedAt,
              ));
    }
    final events = await store.loadEvents();
    for (final event in events) {
      _diagnosticsUpdate(
          event.taskId,
          (d) => d.copyWith(
                lastRuntimeEventType: event.type.wireName,
                eventCount: d.eventCount + 1,
                updatedAt: event.createdAt,
              ));
    }
  }

  Future<void> _runReconcileLoop({
    required Future<List<RuntimeReconcileTarget>> Function() loadTargets,
    required Future<RuntimeRemoteProbe> Function(RuntimeReconcileTarget target)
        probe,
    required Future<void> Function(RuntimeReconcileDecision decision)
        onDecision,
    required int maxTasksPerRun,
    required Duration probeTimeout,
  }) async {
    try {
      final targets = await loadTargets();
      if (targets.isEmpty) {
        // No reconciable targets — loop is idle.
        return;
      }
      final decisions = await reconcileOnce(
        targets: targets,
        probe: probe,
        maxTasksPerRun: maxTasksPerRun,
        probeTimeout: probeTimeout,
      );
      for (final decision in decisions) {
        await onDecision(decision);
      }
    } catch (error) {
      // silently skip reconcile errors
    }
  }

  RuntimeReconcileDecision _reconcileDecisionFor(
    RuntimeReconcileTarget target,
    RuntimeRemoteProbe probe,
  ) {
    if (!probe.sessionExists) {
      return RuntimeReconcileDecision.refresh(
        taskId: target.taskId,
        reason: RuntimeReconcileReason.sessionMissing,
      );
    }
    if (probe.needsAttention) {
      return RuntimeReconcileDecision.refresh(
        taskId: target.taskId,
        reason: RuntimeReconcileReason.needsAttention,
      );
    }
    if (probe.hasExitedMarker) {
      return RuntimeReconcileDecision.refresh(
        taskId: target.taskId,
        reason: RuntimeReconcileReason.exited,
      );
    }
    final snapshot = probe.snapshot.trim();
    if (snapshot.isEmpty) {
      return RuntimeReconcileDecision.none(target.taskId);
    }
    final hash = snapshot.hashCode.toString();
    final previousHash = _reconcileHashes[target.taskId];
    if (previousHash != hash) {
      _reconcileHashes[target.taskId] = hash;
      _reconcileStableCounts[target.taskId] = 1;
      return RuntimeReconcileDecision.none(target.taskId);
    }
    final stableCount = (_reconcileStableCounts[target.taskId] ?? 1) + 1;
    _reconcileStableCounts[target.taskId] = stableCount;
    if (stableCount >= 2) {
      _reconcileStableCounts.remove(target.taskId);
      return RuntimeReconcileDecision.none(target.taskId);
    }
    return RuntimeReconcileDecision.none(target.taskId);
  }

  Future<RuntimeTaskSnapshot> createTask(RuntimeTaskSnapshot task) async {
    _validateTaskId(task.taskId);
    await taskStore.saveTask(task);
    _publish(RuntimeEventType.taskCreated, task);
    _ensureDiagnostics(task.taskId);
    final explicitWorkState = task.workState;
    if (explicitWorkState != null) {
      _workStates[task.taskId] = explicitWorkState;
      await _saveWorkState(explicitWorkState);
      _diagnosticsUpdate(
        task.taskId,
        (d) => d.copyWith(
          workPhase: explicitWorkState.phase,
          updatedAt: explicitWorkState.updatedAt ?? task.updatedAt,
        ),
      );
    } else {
      final phase = _phaseForTaskStatus(task.status);
      _updateWorkState(
        task.taskId,
        phase,
        _headlineForPhase(phase),
        task.summary,
      );
    }
    return task;
  }

  WorkPhase _phaseForTaskStatus(RuntimeTaskStatus status) {
    return switch (status) {
      RuntimeTaskStatus.pending => WorkPhase.idle,
      RuntimeTaskStatus.running => WorkPhase.working,
      RuntimeTaskStatus.waitingUser => WorkPhase.turnIdle,
      RuntimeTaskStatus.completed => WorkPhase.completed,
      RuntimeTaskStatus.failed => WorkPhase.failed,
      RuntimeTaskStatus.cancelled => WorkPhase.stopped,
    };
  }

  String _headlineForPhase(WorkPhase phase) {
    return switch (phase) {
      WorkPhase.idle => 'Task created.',
      WorkPhase.working => 'Agent started.',
      WorkPhase.quieting => 'Observer detached.',
      WorkPhase.turnIdle => '等待你的指示',
      WorkPhase.needsApproval => 'Waiting for approval.',
      WorkPhase.needsDecision => 'Waiting for decision.',
      WorkPhase.needsInstruction => 'Waiting for instruction.',
      WorkPhase.needsReview => 'Waiting for review.',
      WorkPhase.completed => 'Task completed.',
      WorkPhase.failed => 'Task failed.',
      WorkPhase.stopped => 'Task stopped.',
    };
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
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              runId: session.id,
              sessionName: session.tmuxSessionName,
              observerState: 'attached',
              updatedAt: observedAt,
            ));
    _publishDirect(
        RuntimeEventType.observerAttached, taskId, observedAt, updated);
    _updateWorkState(taskId, WorkPhase.working, 'Agent started.', '');
    return updated;
  }

  Future<RuntimeTaskSnapshot> pauseTask(
    String taskId, {
    String summary = '',
    DateTime? now,
  }) async {
    final updated = await _transition(
      taskId,
      RuntimeTaskStatus.waitingUser,
      RuntimeEventType.taskPaused,
      summary: summary,
      now: now,
      workPhase: WorkPhase.quieting,
      workHeadline: 'Task paused.',
    );
    return updated;
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
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              observerState: 'attached',
              updatedAt: observedAt,
            ));
  }

  /// Publish observer detached event.
  void notifyObserverDetached(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.observerDetached, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              observerState: 'detached',
              updatedAt: observedAt,
            ));
    _updateWorkState(taskId, WorkPhase.quieting, 'Observer detached.', '');
  }

  /// Publish connection lost event.
  void notifyConnectionLost(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.connectionLost, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              observerState: 'connection_lost',
              updatedAt: observedAt,
            ));
    _updateWorkState(taskId, WorkPhase.quieting, '连接已暂停', '');
  }

  /// Publish connection restored event.
  void notifyConnectionRestored(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(
        RuntimeEventType.connectionRestored, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
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
    if (update.isDuplicate || !update.hasUsefulUpdate) {
      return null;
    }
    final observedAt = now ?? DateTime.now();
    final updated = current.copyWith(
      status: current.status,
      updatedAt: observedAt,
      action: update.action.isEmpty ? current.action : update.action,
      currentStep: update.action.isEmpty ? current.currentStep : update.action,
      progress: update.progress ?? current.progress,
      lastLogOffset: update.lastOffset,
      lastOutputFingerprint: update.outputFingerprint,
      checkpoint:
          update.checkpoint.isEmpty ? current.checkpoint : update.checkpoint,
      summary: update.action.isEmpty ? current.summary : update.action,
    );
    await taskStore.saveTask(updated);
    _publishDirect(RuntimeEventType.outputUpdated, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              lastObservedOutputTime: observedAt,
              updatedAt: observedAt,
            ));
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
  void notifyApprovalRequested(
    String taskId, {
    NativeTerminalApproval? approval,
    DateTime? now,
  }) {
    final observedAt = now ?? DateTime.now();
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              approvalState: ApprovalState.pending,
              updatedAt: observedAt,
            ));
    _updateWorkState(
      taskId,
      WorkPhase.needsApproval,
      approval?.question ?? '这个任务需要你做决定',
      '',
      approval: approval,
    );
    _publishDirect(
        RuntimeEventType.approvalRequested, taskId, observedAt, null);
  }

  /// Publish an approval resolving event (user action sent to terminal).
  void notifyApprovalResolving(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(
        RuntimeEventType.approvalResolving, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              approvalState: ApprovalState.resolving,
              updatedAt: observedAt,
            ));
    _updateWorkState(
        taskId, WorkPhase.working, 'Processing your decision...', '');
  }

  /// Publish an approval resolved event.
  void notifyApprovalResolved(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalResolved, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              approvalState: ApprovalState.resolved,
              updatedAt: observedAt,
            ));
    _updateWorkState(taskId, WorkPhase.working, 'Agent continuing.', '');
  }

  /// Publish an approval rejected event.
  void notifyApprovalRejected(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalRejected, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              approvalState: ApprovalState.resolved,
              updatedAt: observedAt,
            ));
  }

  /// Publish an approval failed event.
  void notifyApprovalFailed(String taskId, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    _publishDirect(RuntimeEventType.approvalFailed, taskId, observedAt, null);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              approvalState: ApprovalState.failed,
              updatedAt: observedAt,
            ));
    _updateWorkState(taskId, WorkPhase.needsApproval, 'Approval action failed.',
        'Please try again.');
  }

  /// Publish an output updated event with optional output summary.
  void notifyOutputUpdated(String taskId, {DateTime? now, String? output}) {
    final observedAt = now ?? DateTime.now();
    final trimmed = output?.trim() ?? '';
    final snapshot = trimmed.isNotEmpty
        ? RuntimeTaskSnapshot(
            taskId: taskId,
            status: RuntimeTaskStatus.running,
            createdAt: observedAt,
            updatedAt: observedAt,
            summary: trimmed,
          )
        : null;
    _publishDirect(
        RuntimeEventType.outputUpdated, taskId, observedAt, snapshot);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              lastObservedOutputTime: observedAt,
              updatedAt: observedAt,
            ));
  }

  /// Publish a deliverable updated event with optional deliverable summary.
  Future<void> notifyDeliverableUpdated(
    String taskId, {
    required String deliverableSummary,
    required String turnId,
    required String evidenceFingerprint,
    DateTime? now,
  }) async {
    final observedAt = now ?? DateTime.now();
    final trimmed = deliverableSummary.trim();
    if (trimmed.isEmpty || turnId.trim().isEmpty) return;
    final current = await _requireTask(taskId);
    final snapshot = current.copyWith(
      updatedAt: observedAt,
      summary: trimmed,
    );
    final event = RuntimeEvent(
      type: RuntimeEventType.deliverableUpdated,
      taskId: taskId,
      createdAt: observedAt,
      snapshot: snapshot,
      turnId: turnId,
      evidenceFingerprint: evidenceFingerprint,
    );
    await _enqueueDurableWrite(taskId, () => _saveEvent(event));
    final currentWorkState = _workStates[taskId];
    if (currentWorkState != null &&
        currentWorkState.lastDeliverableId != evidenceFingerprint) {
      final updatedWorkState = currentWorkState.copyWith(
        lastDeliverableId: evidenceFingerprint,
        deliverableCount: currentWorkState.deliverableCount + 1,
        updatedAt: observedAt,
      );
      _workStates[taskId] = updatedWorkState;
      await _enqueueDurableWrite(
        taskId,
        () => _saveWorkState(updatedWorkState),
      );
    }
    eventBus.publish(event);
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
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
    WorkPhase? workPhase,
    String? workHeadline,
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
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              lastRuntimeEventType: eventType.wireName,
              eventCount: d.eventCount + 1,
              updatedAt: updated.updatedAt,
            ));
    if (workPhase != null) {
      _updateWorkState(
        taskId,
        workPhase,
        workHeadline ?? '',
        summary,
      );
      return updated;
    }
    // Update WorkState based on transition.
    switch (status) {
      case RuntimeTaskStatus.running:
        _updateWorkState(taskId, WorkPhase.working, '', summary);
      case RuntimeTaskStatus.waitingUser:
        _updateWorkState(taskId, WorkPhase.turnIdle, '等待你的指示', summary);
      case RuntimeTaskStatus.completed:
        _updateWorkState(
            taskId, WorkPhase.completed, 'Task completed.', summary);
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
    final event = RuntimeEvent(
      type: type,
      taskId: snapshot.taskId,
      createdAt: snapshot.updatedAt,
      snapshot: snapshot,
    );
    eventBus.publish(event);
    unawaited(
      _enqueueDurableWrite(snapshot.taskId, () => _saveEvent(event)),
    );
    _diagnosticsUpdate(
        snapshot.taskId,
        (d) => d.copyWith(
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
    final event = RuntimeEvent(
      type: type,
      taskId: taskId,
      createdAt: createdAt,
      snapshot: snapshot,
    );
    eventBus.publish(event);
    if (_shouldPersistEvent(type)) {
      unawaited(_enqueueDurableWrite(taskId, () => _saveEvent(event)));
    }
  }

  bool _shouldPersistEvent(RuntimeEventType type) {
    return type != RuntimeEventType.outputUpdated;
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
    String detail, {
    NativeTerminalApproval? approval,
  }) {
    final current = _workStates[taskId];
    final state = WorkState(
      taskId: taskId,
      phase: phase,
      headline: headline,
      detail: detail,
      approval: approval,
      lastDeliverableId: current?.lastDeliverableId,
      deliverableCount: current?.deliverableCount ?? 0,
      updatedAt: DateTime.now(),
    );
    _workStates[taskId] = state;
    unawaited(_enqueueDurableWrite(taskId, () => _saveWorkState(state)));
    _diagnosticsUpdate(
        taskId,
        (d) => d.copyWith(
              workPhase: phase,
              updatedAt: DateTime.now(),
            ));
  }

  void _validateTaskId(String taskId) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'Task id is required.');
    }
  }

  Future<void> _saveEvent(RuntimeEvent event) async {
    final store = taskStore;
    if (store is RuntimePersistenceStore) {
      await store.saveEvent(event);
    }
  }

  Future<void> _saveWorkState(WorkState state) async {
    final store = taskStore;
    if (store is RuntimePersistenceStore) {
      await store.saveWorkState(state);
    }
  }

  Future<void> _enqueueDurableWrite(
    String taskId,
    Future<void> Function() write,
  ) {
    final previous = _durableWriteChains[taskId] ?? Future<void>.value();
    final next = previous.then((_) => write());
    _durableWriteChains[taskId] = next;
    return next.whenComplete(() {
      if (identical(_durableWriteChains[taskId], next)) {
        _durableWriteChains.remove(taskId);
      }
    });
  }
}

enum RuntimeReconcileAction {
  none,
  refresh,
}

enum RuntimeReconcileReason {
  none,
  sessionMissing,
  needsAttention,
  exited,
  stableOutput,
}

class RuntimeReconcileTarget {
  const RuntimeReconcileTarget({
    required this.taskId,
    required this.status,
  });

  final String taskId;
  final RuntimeTaskStatus status;
}

class RuntimeRemoteProbe {
  const RuntimeRemoteProbe({
    required this.sessionExists,
    this.snapshot = '',
    this.needsAttention = false,
    this.hasExitedMarker = false,
    this.exitMarkerCount = 0,
  });

  final bool sessionExists;
  final String snapshot;
  final bool needsAttention;
  final bool hasExitedMarker;
  final int exitMarkerCount;
}

class RuntimeReconcileDecision {
  const RuntimeReconcileDecision({
    required this.taskId,
    required this.action,
    this.reason = RuntimeReconcileReason.none,
  });

  const RuntimeReconcileDecision.none(String taskId)
      : this(
          taskId: taskId,
          action: RuntimeReconcileAction.none,
        );

  const RuntimeReconcileDecision.refresh({
    required String taskId,
    required RuntimeReconcileReason reason,
  }) : this(
          taskId: taskId,
          action: RuntimeReconcileAction.refresh,
          reason: reason,
        );

  final String taskId;
  final RuntimeReconcileAction action;
  final RuntimeReconcileReason reason;
}
