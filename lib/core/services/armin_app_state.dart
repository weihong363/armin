import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../features/agent/models/agent_approval_config.dart';
import '../../features/agent/parsers/terminal_prompt.dart';
import '../../features/agent/parsers/terminal_prompt_parser.dart';
import '../../features/agent/services/agent_output_cleaner.dart';
import '../../features/agent/services/agent_runtime_adapter.dart';
import '../../features/agent/services/agent_runtime_config.dart';
import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/services/native_output_observer.dart';
import '../../features/agent/services/runtime_policy.dart';
import '../../features/agent/services/ssh_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/notifications/services/task_notification_service.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/runtime/models/approval_state.dart';
import '../../features/runtime/models/resolved_runtime_state.dart';
import '../../features/runtime/models/runtime_diagnostics.dart';
import '../../features/runtime/models/runtime_task_snapshot.dart';
import '../../features/runtime/models/work_state.dart';
import '../../features/runtime/services/bridge_runtime.dart';
import '../../features/runtime/services/runtime_event_bus.dart';
import '../../features/runtime/services/runtime_task_store.dart';
import '../../features/runtime/services/sqlite_runtime_persistence_store.dart';
import '../../features/tasks/models/loop_evaluation.dart';
import '../../features/tasks/models/metric_event.dart';
import '../../features/tasks/models/native_output_turn.dart';
import '../../features/tasks/models/task_constraint.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/tasks/models/voice_input.dart';
import '../../features/tasks/services/loop_evaluation_assistant.dart';
import '../../features/tasks/services/output_summary_provider.dart';
import '../../features/tasks/services/secret_redactor.dart';
import '../../features/tasks/services/task_deliverable_source.dart';
import '../../features/voice/services/device_voice_service.dart';
import '../../features/voice/services/task_speech_policy.dart';
import '../../features/voice/services/voice_service.dart';
import '../models/task_status.dart';
import '../storage/sqlite_task_history_store.dart';
import '../storage/task_history_store.dart';

OutputSummaryProvider _defaultOutputSummaryProvider() =>
    const RuleBasedOutputSummaryProvider();

class ArminAppState extends ChangeNotifier {
  static const _deliverableSource = TaskDeliverableSource();
  static const _loopEvaluationAssistant = LoopEvaluationAssistant();
  static const _appDiagnosticsEnabled = bool.fromEnvironment('ARMIN_APP_DIAG');
  static const _maxAutopilotActionsPerTask = 3;

  ArminAppState({
    required TaskHistoryStore store,
    required this.agentSessionService,
    required this.voiceService,
    TaskNotificationService? taskNotificationService,
    TaskSpeechPolicy? taskSpeechPolicy,
    OutputSummaryProvider? outputSummaryProvider,
    this.speechSettings = const TaskSpeechSettings(),
    RuntimeEventBus? runtimeEventBus,
    BridgeRuntime? bridgeRuntime,
    bool enableRemoteReconcile = false,
    Duration remoteReconcileInterval = const Duration(seconds: 10),
    Duration remoteSnapshotPollInterval = const Duration(seconds: 5),
  })  : _store = store,
        _taskSpeechPolicy = taskSpeechPolicy ?? const TaskSpeechPolicy(),
        taskNotificationService =
            taskNotificationService ?? const NoopTaskNotificationService(),
        outputSummaryProvider =
            outputSummaryProvider ?? _defaultOutputSummaryProvider(),
        _enableRemoteReconcile = enableRemoteReconcile,
        _remoteReconcileInterval = remoteReconcileInterval,
        _remoteSnapshotPollInterval = remoteSnapshotPollInterval,
        // ignore: unnecessary_this
        this.runtimeEventBus = runtimeEventBus ?? RuntimeEventBus() {
    // ignore: unnecessary_this
    this.bridgeRuntime = bridgeRuntime ??
        BridgeRuntime(
          taskStore: InMemoryRuntimeTaskStore(),
          eventBus: this.runtimeEventBus,
        );
    _configureOutputSummaryProvider();
  }

  ArminAppState.run({
    TaskHistoryStore? store,
    AgentSessionService? agentSessionService,
    VoiceService? voiceService,
    TaskNotificationService? taskNotificationService,
    OutputSummaryProvider? outputSummaryProvider,
  })  : _store = store ??
            (() {
              final runtimeStore = SQLiteRuntimePersistenceStore();
              return SQLiteTaskHistoryStore(runtimeStore: runtimeStore);
            })(),
        agentSessionService = agentSessionService ?? SSHAgentSessionService(),
        voiceService = voiceService ?? DeviceVoiceService(),
        taskNotificationService =
            taskNotificationService ?? const NoopTaskNotificationService(),
        _taskSpeechPolicy = const TaskSpeechPolicy(),
        outputSummaryProvider =
            outputSummaryProvider ?? _defaultOutputSummaryProvider(),
        speechSettings = const TaskSpeechSettings(),
        _enableRemoteReconcile = true,
        _remoteReconcileInterval = const Duration(seconds: 10),
        _remoteSnapshotPollInterval = const Duration(seconds: 5),
        runtimeEventBus = RuntimeEventBus() {
    // Share the same SQLite store for both BridgeRuntime and task history.
    final sharedStore =
        _store is SQLiteTaskHistoryStore ? _store.runtimeStore : null;
    bridgeRuntime = BridgeRuntime(
      taskStore: sharedStore ?? SQLiteRuntimePersistenceStore(),
      eventBus: runtimeEventBus,
    );
    _configureOutputSummaryProvider();
  }

  final TaskHistoryStore _store;
  final AgentSessionService agentSessionService;
  final VoiceService voiceService;
  final TaskNotificationService taskNotificationService;
  final TaskSpeechPolicy _taskSpeechPolicy;
  final OutputSummaryProvider outputSummaryProvider;
  final SecretRedactor _secretRedactor = const SecretRedactor();
  TaskSpeechSettings speechSettings;
  final RuntimeEventBus runtimeEventBus;
  late final BridgeRuntime bridgeRuntime;
  final Set<String> _bridgedTaskIds = {};
  final Map<String, Future<void>> _bridgeCreateFutures = {};
  final Map<String, Future<void>> _runtimeSyncChains = {};
  Future<void> _autopilotQueue = Future<void>.value();
  final Map<String, String> _publishedDeliverableFingerprints = {};
  final Map<String, int> _lastRuntimeOutputHashes = {};
  final Map<String, DateTime> _lastRuntimeOutputNotifiedAt = {};
  final Set<String> _autoApprovalsInFlight = {};
  final Set<String> _keepObserverAttachedTaskIds = {};
  final Map<String, ValueNotifier<TaskSession?>> _taskSnapshots = {};
  final ValueNotifier<HomeTaskSnapshot> homeSnapshot =
      ValueNotifier(HomeTaskSnapshot.empty());
  String _homeSnapshotSignature = '';
  final Map<String, int> _remoteExitMarkerCounts = {};

  List<HostConfig> hosts = const [];
  List<TaskSession> tasks = const [];
  List<ProjectPathConfig> projectPaths = const [];
  bool ready = false;
  bool _disposed = false;

  /// Maximum concurrent active (non-terminal) tasks.
  int maxActiveTasks = _defaultMaxActiveTasks;
  static const int _defaultMaxActiveTasks = 5;
  static const Duration _runtimeOutputNotifyInterval =
      Duration(milliseconds: 250);

  /// Active tasks: any task that is NOT in a terminal state.
  /// Terminal states: completed, userCompleted, failed, userFailed, stopped.
  List<TaskSession> get activeTasks {
    return tasks.where((t) => !_isTerminalTask(t)).toList(growable: false);
  }

  bool _isTerminalTask(TaskSession task) {
    return _isTerminal(_taskStatus(task));
  }

  TaskStatus _taskStatus(TaskSession task) =>
      _taskStatusFromWorkState(bridgeRuntime.workState(task.id), task);

  TaskStatus taskStatus(TaskSession task) => _taskStatus(task);

  TaskStatus _projectedTaskStatus(TaskSession task) {
    final latestTurn = task.turns.lastOrNull;
    if (task.scheduledFor != null && task.startedAt == null) {
      return TaskStatus.pending;
    }
    if (task.nativeApproval?.state == ApprovalState.pending) {
      return TaskStatus.needApproval;
    }
    if (latestTurn != null) {
      return switch (latestTurn.status) {
        NativeOutputTurnStatus.running => TaskStatus.running,
        NativeOutputTurnStatus.turnIdle => TaskStatus.turnIdle,
        NativeOutputTurnStatus.needAttention => TaskStatus.needAttention,
        NativeOutputTurnStatus.runtimeLost => TaskStatus.runtimeLost,
        NativeOutputTurnStatus.failed => TaskStatus.failed,
        NativeOutputTurnStatus.completedByUser => TaskStatus.userCompleted,
        NativeOutputTurnStatus.failedByUser => TaskStatus.userFailed,
        NativeOutputTurnStatus.stopped => TaskStatus.stopped,
      };
    }
    if (task.completedAt != null) return TaskStatus.completed;
    if (task.startedAt != null) return TaskStatus.running;
    return TaskStatus.draft;
  }

  TaskStatus _taskStatusFromWorkState(
    WorkState? workState,
    TaskSession task,
  ) {
    if (workState == null) {
      return _projectedTaskStatus(task);
    }
    return switch (workState.phase) {
      WorkPhase.idle =>
        task.scheduledFor == null ? TaskStatus.draft : TaskStatus.pending,
      WorkPhase.quieting => _quietingTaskStatus(workState),
      WorkPhase.turnIdle => TaskStatus.turnIdle,
      WorkPhase.needsApproval => TaskStatus.needApproval,
      WorkPhase.needsDecision ||
      WorkPhase.needsInstruction =>
        TaskStatus.needAttention,
      WorkPhase.needsReview => TaskStatus.turnIdle,
      WorkPhase.completed => TaskStatus.completed,
      WorkPhase.failed => TaskStatus.failed,
      WorkPhase.stopped => TaskStatus.stopped,
      WorkPhase.working => TaskStatus.running,
    };
  }

  TaskStatus _quietingTaskStatus(WorkState workState) {
    final headline = workState.headline.toLowerCase();
    if (headline.contains('runtime') ||
        workState.headline.contains('连接') ||
        workState.headline.contains('会话')) {
      return TaskStatus.runtimeLost;
    }
    if (headline.contains('paused') || workState.headline.contains('暂停')) {
      return TaskStatus.paused;
    }
    return TaskStatus.observerDetached;
  }

  String _taskBlockingLabel(TaskSession task) {
    final title = task.displayTitle;
    return title.length > 20 ? '${title.substring(0, 20)}...' : title;
  }

  final Map<String, StreamSubscription<AgentExecutionUpdate>>
      _runningExecutions = {};
  final Map<String, Timer> _autoDetachTimers = {};
  final Map<String, Timer> _scheduledTaskTimers = {};
  final Map<String, String> _lastSpokenHashes = {};
  final Set<String> _seenDeliverableSpeechKeys = {};
  final Set<String> _seenTaskNotificationKeys = {};
  Future<void> _speechQueue = Future<void>.value();
  Future<void> _notificationQueue = Future<void>.value();
  String? _activeDetailTaskId;
  final bool _enableRemoteReconcile;
  final Duration _remoteReconcileInterval;
  final Duration _remoteSnapshotPollInterval;
  // ---- reconcile backoff: track consecutive sessionMissing per task ----
  final Map<String, int> _reconcileMissStreak = {};
  static const int _kReconcileMaxMissStreak = 6; // ~1 min at 10s interval
  static const int _kSnapshotPollMaxTasks = 3;
  Timer? _remoteSnapshotPollTimer;
  bool _remoteSnapshotPollRunning = false;
  StreamSubscription<RuntimeEvent>? _speechEventSubscription;
  StreamSubscription<RuntimeEvent>? _notificationEventSubscription;

  Future<void> load() async {
    await bridgeRuntime.restoreDurableState();
    // [DEV-ONLY] Import seed passwords before loading hosts.
    // This is a no-op in production. Only the Android emulator workflow
    // (seed-config.sh) places a temporary password file on the device.
    await _store.importSeedPasswords();
    hosts = await _store.loadHosts();
    tasks = await _loadDedupedTasks();
    for (final task in tasks) {
      await _bridgeEnsureTaskCreated(task);
    }
    _markExistingDeliverablesSeen(tasks);
    _markExistingDeliverableNotificationsSeen(tasks);
    projectPaths = await _store.loadProjectPaths();
    ready = true;
    for (final task in tasks) {
      await _bridgeEnsureTaskCreated(task);
      final workState = bridgeRuntime.workState(task.id);
      final taskStatus = _taskStatus(task);
      if (workState != null &&
          !isRuntimeStateConsistent(
            taskStatus: taskStatus,
            workState: workState,
          )) {
        final resolved = resolveRuntimeState(
          task,
          taskStatus: taskStatus,
          workState: workState,
        );
        await bridgeRuntime.projectTaskState(
          taskId: task.id,
          status: RuntimeTaskSnapshot.fromTaskStatus(
            taskId: task.id,
            status: taskStatus,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
          ).status,
          workState: resolved.toWorkState(task.id),
          summary: _runtimeSummaryForTask(task),
        );
      } else if (workState == null) {
        await _enqueueRuntimeSync(task);
      }
    }
    _syncTaskSnapshots();
    _updateHomeSnapshot(force: true);
    _startRemoteReconcileLoop();
    _startRemoteSnapshotPollLoop();
    _syncScheduledTaskTimers();
    _speechEventSubscription = runtimeEvents.listen(_onSpeechEvent);
    _notificationEventSubscription = runtimeEvents.listen(_onNotificationEvent);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    homeSnapshot.dispose();
    for (final snapshot in _taskSnapshots.values) {
      snapshot.dispose();
    }
    bridgeRuntime.stopReconcileLoop();
    _remoteSnapshotPollTimer?.cancel();
    _speechEventSubscription?.cancel();
    _notificationEventSubscription?.cancel();
    for (final timer in _autoDetachTimers.values) {
      timer.cancel();
    }
    for (final timer in _scheduledTaskTimers.values) {
      timer.cancel();
    }
    for (final subscription in _runningExecutions.values) {
      unawaited(subscription.cancel());
    }
    unawaited(runtimeEventBus.dispose());
    super.dispose();
  }

  /// Wait for in-flight observer subscriptions and Runtime sync chains to
  /// settle so that no async callback can fire after dispose.
  ///
  /// Only intended for integration test teardown; not part of the
  /// production lifecycle.
  Future<void> drainForTest() async {
    // 1. Cancel and wait for all observer subscriptions.
    final subscriptions =
        Map<String, StreamSubscription<AgentExecutionUpdate>>.of(
            _runningExecutions);
    for (final entry in subscriptions.entries) {
      await entry.value.cancel();
      _runningExecutions.remove(entry.key);
    }
    _autoDetachTimers.values.toList(growable: false).forEach((t) => t.cancel());
    _autoDetachTimers.clear();
    _scheduledTaskTimers.values
        .toList(growable: false)
        .forEach((timer) => timer.cancel());
    _scheduledTaskTimers.clear();
    _remoteSnapshotPollTimer?.cancel();
    _remoteSnapshotPollTimer = null;

    // 2. Wait for per-task Runtime sync chains to drain.
    if (_runtimeSyncChains.isNotEmpty) {
      await Future.wait(_runtimeSyncChains.values.toList(growable: false));
    }

    // 3. Wait for queued autopilot callbacks triggered by fresh deliverables.
    await _autopilotQueue;

    // 4. Wait for queued speech callbacks that may have been triggered by
    // fresh deliverables.
    await _speechQueue;

    // 5. Wait for queued notification callbacks.
    await _notificationQueue;

    // 6. Allow a microtask tick for any remaining callbacks to flush.
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> saveHost(HostConfig host) async {
    final blockingIds = activeTasks
        .where((t) => t.host.id == host.id)
        .map((t) => _taskBlockingLabel(t))
        .toList();
    if (blockingIds.isNotEmpty) {
      throw HostEditBlockedException(blockingIds);
    }
    await _store.saveHost(host);
    hosts = await _store.loadHosts();
    notifyListeners();
  }

  Future<void> deleteHost(String hostId) async {
    final blockingIds = activeTasks
        .where((t) => t.host.id == hostId)
        .map((t) => _taskBlockingLabel(t))
        .toList();
    if (blockingIds.isNotEmpty) {
      throw HostEditBlockedException(blockingIds);
    }
    await _store.deleteHost(hostId);
    hosts = await _store.loadHosts();
    notifyListeners();
  }

  Future<void> setDefaultHost(String hostId) async {
    final currentHosts = await _store.loadHosts();
    final updatedHosts = currentHosts.map((host) {
      return host.copyWith(isDefault: host.id == hostId);
    }).toList();

    // Save all hosts with updated isDefault flag
    for (final host in updatedHosts) {
      await _store.saveHost(host);
    }

    hosts = await _store.loadHosts();
    notifyListeners();
  }

  Future<void> saveTask(
    TaskSession task, {
    bool publishDeliverable = true,
  }) async {
    final previous = _latestTask(task.id);
    final taskToSave =
        previous == null ? task : _mergeRuntimeArtifacts(previous, task);
    await _store.saveTask(taskToSave);
    final updatedTasks = [...tasks];
    // Dedup: remove ALL existing entries with this id before inserting.
    updatedTasks.removeWhere((item) => item.id == taskToSave.id);
    updatedTasks.insert(0, taskToSave);
    tasks = updatedTasks;
    _syncScheduledTaskTimer(taskToSave);
    _reconcileMissStreak.remove(task.id);
    final statusChanged = previous == null ||
        _projectedStatusSignature(previous) !=
            _projectedStatusSignature(taskToSave);
    if (statusChanged) {
      unawaited(
        _enqueueRuntimeSync(taskToSave).then((_) {
          _updateTaskSnapshot(taskToSave);
          _updateHomeSnapshot(force: true);
          _queueAggressiveAutoApproveIfNeeded(taskToSave);
        }),
      );
      if (publishDeliverable) {
        unawaited(_publishDeliverableIfAvailable(taskToSave));
      }
      return;
    }
    _updateTaskSnapshot(taskToSave);
    _updateHomeSnapshot();
    _queueAggressiveAutoApproveIfNeeded(taskToSave);
    if (publishDeliverable) {
      unawaited(_publishDeliverableIfAvailable(taskToSave));
    }
  }

  void _queueAggressiveAutoApproveIfNeeded(TaskSession task) {
    final latest = _latestTask(task.id) ?? task;
    if (_taskStatus(latest) != TaskStatus.needApproval &&
        _projectedTaskStatus(latest) != TaskStatus.needApproval) {
      return;
    }
    unawaited(_maybeAutoApproveAggressive(latest));
  }

  TaskSession _mergeRuntimeArtifacts(TaskSession previous, TaskSession next) {
    final previousTurnsById = {
      for (final turn in previous.turns) turn.id: turn,
    };
    final mergedTurns = [
      for (final turn in next.turns)
        if (turn.deliverable == null &&
            previousTurnsById[turn.id]?.deliverable != null)
          turn.copyWith(deliverable: previousTurnsById[turn.id]!.deliverable)
        else
          turn,
    ];
    final mergedEvents = _mergeMetricEvents(
      previous.metricEvents,
      next.metricEvents,
    );
    return next.copyWith(turns: mergedTurns, metricEvents: mergedEvents);
  }

  List<MetricEvent> _mergeMetricEvents(
    List<MetricEvent> previous,
    List<MetricEvent> next,
  ) {
    final byKey = <String, MetricEvent>{};
    for (final event in [...previous, ...next]) {
      byKey[event.mergeKey] = event;
    }
    final events = byKey.values.toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (events.length <= MetricEvent.maxStoredEvents) {
      return events;
    }
    return events.sublist(events.length - MetricEvent.maxStoredEvents);
  }

  Future<void> refreshTasks() async {
    tasks = await _loadDedupedTasks();
    for (final task in tasks) {
      await _bridgeEnsureTaskCreated(task);
    }
    _syncTaskSnapshots();
    _updateHomeSnapshot(force: true);
    notifyListeners();
    unawaited(_refreshRemoteSnapshotsAfterManualRefresh());
  }

  Future<void> refreshTaskFromRemote(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    await _bridgeEnsureTaskCreated(latest);
    if (!_canRefreshRemoteState(latest)) {
      return;
    }
    final hadActiveObserver = _runningExecutions.containsKey(latest.id);
    await _captureAndApplyRemoteSnapshot(latest);
    final synced = _latestTask(task.id) ?? latest;
    if (hadActiveObserver) {
      startTaskExecution(synced, _attachRequest(synced));
    }
  }

  Future<void> _refreshRemoteSnapshotsAfterManualRefresh() async {
    final candidates =
        tasks.where(_canManualRefreshRemoteSnapshot).toList(growable: false);
    for (final task in candidates) {
      _reconcileMissStreak.remove(task.id);
      try {
        await _captureAndApplyRemoteSnapshot(task);
      } catch (error) {
        debugPrint('Manual remote refresh skipped for ${task.id}: $error');
      }
    }
  }

  bool _canManualRefreshRemoteSnapshot(TaskSession task) {
    if (_runningExecutions.containsKey(task.id)) {
      return false;
    }
    return switch (_taskStatus(task)) {
      TaskStatus.running ||
      TaskStatus.observerDetached ||
      TaskStatus.turnIdle ||
      TaskStatus.needApproval ||
      TaskStatus.needAttention =>
        true,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.paused ||
      TaskStatus.stopped ||
      TaskStatus.completed ||
      TaskStatus.userCompleted ||
      TaskStatus.failed ||
      TaskStatus.userFailed ||
      TaskStatus.runtimeLost =>
        false,
    };
  }

  Future<bool> _captureAndApplyRemoteSnapshot(
    TaskSession task, {
    bool allowSettled = false,
  }) async {
    if (_disposed) {
      return false;
    }
    final latest = _latestTask(task.id) ?? task;
    if (!_canRefreshRemoteState(latest)) {
      return false;
    }
    final snapshot = await _captureLogBestEffort(await _controlRequest(latest));
    final trimmed = snapshot.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (_disposed) {
      return false;
    }
    await _applyCapturedRemoteSnapshot(
      latest,
      snapshot,
      allowSettled: allowSettled,
    );
    _syncTaskSnapshots(taskId: latest.id);
    _updateHomeSnapshot();
    return true;
  }

  Future<void> updateTaskTitle(TaskSession task, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed == task.title.trim()) {
      return;
    }
    await saveTask(
      task.copyWith(
        title: trimmed,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> updateTaskHost(TaskSession task, HostConfig host) async {
    if (host.id == task.host.id && host.projectPath == task.host.projectPath) {
      return;
    }
    await saveTask(
      task.copyWith(
        host: host,
        updatedAt: DateTime.now(),
      ),
    );
  }

  void updateSpeechSettings(TaskSpeechSettings settings) {
    speechSettings = settings;
    _configureOutputSummaryProvider();
    if (voiceService is DeviceVoiceService) {
      (voiceService as DeviceVoiceService)
          .updateVoiceStyle(settings.voiceStyle);
    }
    notifyListeners();
  }

  Future<LocalSummaryCapability> localSummaryCapability() {
    final provider = outputSummaryProvider;
    if (provider is SelectableOutputSummaryProvider) {
      return provider.localModelCapability();
    }
    return Future.value(
      const LocalSummaryCapability(
        available: false,
        message: '当前摘要提供方不支持端侧增强。',
      ),
    );
  }

  void _configureOutputSummaryProvider() {
    final provider = outputSummaryProvider;
    if (provider is SelectableOutputSummaryProvider) {
      provider.setPreferLocalModel(speechSettings.preferLocalSummaryModel);
    }
  }

  Future<bool> speakTaskSummary(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    final text = await _taskSpeechPolicy.buildSpeechText(
      latest,
      status: _taskStatus(latest),
      approval: bridgeRuntime.workState(latest.id)?.approval,
    );
    if (text.trim().isEmpty) {
      return false;
    }
    await voiceService.speakSummary(text);
    return true;
  }

  ValueListenable<TaskSession?> taskListenable(String taskId) {
    return _taskSnapshots.putIfAbsent(
      taskId,
      () => ValueNotifier<TaskSession?>(_latestTask(taskId)),
    );
  }

  Future<void> deleteTask(String taskId) async {
    final task = _latestTask(taskId);
    if (task != null && !_canDeleteTask(_taskStatus(task))) {
      throw StateError('Only terminal tasks can be deleted.');
    }
    await _store.deleteTask(taskId);
    tasks = await _loadDedupedTasks();
    _updateTaskSnapshotById(taskId);
    _updateHomeSnapshot(force: true);
    notifyListeners();
  }

  Future<void> updateTaskStatus(TaskSession task, TaskStatus status) async {
    final now = DateTime.now();
    final updated = _projectTaskStatus(
      task,
      status: status,
      now: now,
    );
    await _bridgeEnsureTaskCreated(updated);
    await _applyRuntimeTaskStatus(
      updated,
      status: status,
      now: now,
    );
    await saveTask(updated);
  }

  Future<void> scheduleTask(TaskSession task, DateTime scheduledFor) async {
    final latest = _latestTask(task.id) ?? task;
    if (_isTerminalTask(latest) || _taskStatus(latest) == TaskStatus.running) {
      throw StateError('Only inactive tasks can be scheduled.');
    }
    final now = DateTime.now();
    final scheduled = _projectTaskStatus(
      latest,
      status: TaskStatus.pending,
      now: now,
    ).copyWith(
      scheduledFor: scheduledFor,
      metricEvents: _metricEventsWithCreated(
        latest.metricEvents,
        taskId: latest.id,
        eventType: 'task_scheduled',
        payloadJson: jsonEncode({
          'scheduledFor': scheduledFor.toIso8601String(),
        }),
        now: now,
      ),
    );
    await saveTask(scheduled, publishDeliverable: false);
  }

  Future<void> rescheduleTask(
    TaskSession task,
    DateTime scheduledFor,
  ) async {
    final latest = _latestTask(task.id) ?? task;
    if (_taskStatus(latest) != TaskStatus.pending ||
        latest.scheduledFor == null) {
      throw StateError('Only scheduled pending tasks can be rescheduled.');
    }
    final now = DateTime.now();
    final rescheduled = latest.copyWith(
      scheduledFor: scheduledFor,
      updatedAt: now,
      metricEvents: _metricEventsWithCreated(
        latest.metricEvents,
        taskId: latest.id,
        eventType: 'task_rescheduled',
        payloadJson: jsonEncode({
          'scheduledFor': scheduledFor.toIso8601String(),
        }),
        now: now,
      ),
    );
    await saveTask(rescheduled, publishDeliverable: false);
  }

  Future<void> cancelScheduledTask(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    if (_taskStatus(latest) != TaskStatus.pending ||
        latest.scheduledFor == null) {
      throw StateError('Only scheduled pending tasks can be canceled.');
    }
    final now = DateTime.now();
    final canceled = _projectTaskStatus(
      latest,
      status: TaskStatus.draft,
      now: now,
      clearScheduledFor: true,
    ).copyWith(
      metricEvents: _metricEventsWithCreated(
        latest.metricEvents,
        taskId: latest.id,
        eventType: 'task_schedule_canceled',
        payloadJson: '{"status":"draft"}',
        now: now,
      ),
    );
    await saveTask(canceled, publishDeliverable: false);
  }

  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    final existingPaths = projectPaths
        .where((p) => p.id == projectPath.id)
        .map((p) => normalizeRemoteProjectPath(p.path))
        .toSet()
      ..add(normalizeRemoteProjectPath(projectPath.path));
    final blockingIds = activeTasks
        .where((t) => existingPaths
            .contains(normalizeRemoteProjectPath(t.host.projectPath)))
        .map((t) => _taskBlockingLabel(t))
        .toList();
    if (blockingIds.isNotEmpty) {
      throw ProjectPathEditBlockedException(blockingIds);
    }
    await _store.saveProjectPath(projectPath);
    projectPaths = await _store.loadProjectPaths();
    notifyListeners();
  }

  Future<void> deleteProjectPath(String projectPathId) async {
    final pathToDelete = projectPaths
        .where((p) => p.id == projectPathId)
        .map((p) => normalizeRemoteProjectPath(p.path))
        .firstOrNull;
    if (pathToDelete != null) {
      final blockingIds = activeTasks
          .where((t) =>
              normalizeRemoteProjectPath(t.host.projectPath) == pathToDelete)
          .map((t) => _taskBlockingLabel(t))
          .toList();
      if (blockingIds.isNotEmpty) {
        throw ProjectPathEditBlockedException(blockingIds);
      }
    }
    await _store.deleteProjectPath(projectPathId);
    projectPaths = await _store.loadProjectPaths();
    notifyListeners();
  }

  Future<void> sendFollowUp(
    TaskSession task,
    String instruction, {
    Set<TaskConstraint> addedConstraints = const {},
    String rawVoiceText = '',
  }) async {
    if (instruction.trimLeft().startsWith('APPROVAL_DECISION:')) {
      await agentSessionService.sendFollowUp(
        await _controlRequest(task, instruction: instruction),
      );
      return;
    }
    final latest = _latestTask(task.id) ?? task;
    final previousStatus = _taskStatus(latest);
    final inputAt = DateTime.now();
    final taskWithVoiceInput = _withVoiceInput(latest, rawVoiceText, inputAt);
    final updatedConstraints = {
      ...taskWithVoiceInput.constraints,
      ...addedConstraints,
    };
    final taskWithNewTurn = _taskWithNewTurn(
      taskWithVoiceInput.copyWith(
        constraints: Set.unmodifiable(updatedConstraints),
      ),
      userInput: instruction.trim(),
      now: inputAt,
    );
    final taskWithLoopAction = _taskWithLoopUserAction(
      taskWithNewTurn,
      kind: LoopUserActionKind.continueTask,
      targetTurn: taskWithVoiceInput.turns.lastOrNull ??
          _turnBeforeLast(taskWithNewTurn),
      nextTurn: taskWithNewTurn.turns.lastOrNull,
      instructionLength: instruction.trim().length,
      source: rawVoiceText.trim().isEmpty ? 'text' : 'voice',
      status: TaskStatus.running,
      now: inputAt,
    );
    await _saveControlledTask(
      taskWithLoopAction,
      status: TaskStatus.running,
      logMessage: 'User sent follow-up instruction.',
      eventType:
          rawVoiceText.trim().isEmpty ? 'runtime_control' : 'voice_follow_up',
    );
    final saved = _latestTask(task.id) ?? taskWithNewTurn;
    startTaskExecution(saved, _attachRequest(saved));
    try {
      await agentSessionService.sendFollowUp(
        await _controlRequest(saved, instruction: instruction),
      );
      _runtimeDiag(
        'FOLLOW_UP_SENT task=${saved.id} chars=${instruction.trim().length}',
      );
    } catch (error) {
      _cancelRunningObserver(saved.id);
      final latestAfterFailure = _latestTask(saved.id) ?? saved;
      final rolledBack = _taskAfterFailedFollowUpSend(
        latestAfterFailure,
        previous: latest,
        previousStatus: previousStatus,
        unsentTurnId: saved.turns.lastOrNull?.id,
        error: error,
      );
      await _bridgeEnsureTaskCreated(rolledBack);
      await _applyRuntimeTaskStatus(
        rolledBack,
        status: _projectedTaskStatus(rolledBack),
        now: DateTime.now(),
      );
      await saveTask(rolledBack);
      rethrow;
    }
  }

  Future<bool> runAutopilotNextAction(
    TaskSession task,
    LoopNextAction action,
  ) async {
    final latest = _latestTask(task.id) ?? task;
    if (!action.canAutoExecute) {
      _runtimeDiag(
        'AUTOPILOT_REJECT task=${latest.id} reason=policy '
        'policy=${action.policy.name}',
      );
      await _recordLoopAutoAction(
        latest,
        action,
        state: LoopAutoActionState.rejected,
      );
      return false;
    }
    if (!_canAutopilotContinue(latest)) {
      _runtimeDiag(
        'AUTOPILOT_SKIP task=${latest.id} reason=not_continuable '
        'status=${_projectedTaskStatus(latest).name} '
        'turn=${latest.turns.lastOrNull?.status.name ?? 'none'} '
        'hasDeliverable=${latest.turns.lastOrNull?.deliverable != null}',
      );
      await _recordLoopAutoAction(
        latest,
        action,
        state: LoopAutoActionState.skipped,
      );
      return false;
    }
    if (_hasAutoAction(latest, action)) {
      _runtimeDiag(
        'AUTOPILOT_SKIP task=${latest.id} reason=duplicate '
        'action=${action.id}',
      );
      return false;
    }
    if (_sentAutoActionCount(latest) >= _maxAutopilotActionsPerTask) {
      _runtimeDiag(
        'AUTOPILOT_SKIP task=${latest.id} reason=max_actions '
        'count=${_sentAutoActionCount(latest)}',
      );
      await _recordLoopAutoAction(
        latest,
        action,
        state: LoopAutoActionState.skipped,
      );
      return false;
    }
    await _recordLoopAutoAction(
      latest,
      action,
      state: LoopAutoActionState.sent,
    );
    final saved = _latestTask(latest.id) ?? latest;
    final instruction = _autopilotInstruction(saved, action);
    _runtimeDiag(
      'AUTOPILOT_SEND task=${saved.id} action=${action.id} '
      'chars=${instruction.trim().length}',
    );
    _keepObserverAttachedTaskIds.add(saved.id);
    try {
      await sendFollowUp(saved, instruction);
    } catch (_) {
      _keepObserverAttachedTaskIds.remove(saved.id);
      rethrow;
    }
    return true;
  }

  String _autopilotInstruction(TaskSession task, LoopNextAction action) {
    final nextTurnIndex = (task.turns.lastOrNull?.turnIndex ?? 0) + 1;
    final markerAction = action.id
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .toUpperCase();
    final marker = 'ARMIN_AUTOPILOT_${markerAction}_T$nextTurnIndex';
    return '''
${action.draft.trim()}

Armin autopilot verification:
- Stop after this follow-up result.
- Final answer must include:
$marker status=PASS next=WAIT
''';
  }

  Future<bool> _maybeRunAggressiveAutopilot(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    if (latest.approvalMode != AgentApprovalMode.aggressive) {
      _runtimeDiag('AUTOPILOT_SKIP task=${latest.id} reason=mode');
      return false;
    }
    final projectedStatus = _projectedTaskStatus(latest);
    final action = _loopEvaluationAssistant.nextActionFor(
      latest,
      runtimeStatus: projectedStatus.name,
    );
    if (action == null) {
      _runtimeDiag(
        'AUTOPILOT_SKIP task=${latest.id} reason=no_action '
        'status=${projectedStatus.name}',
      );
      return false;
    }
    _runtimeDiag(
      'AUTOPILOT_RUN task=${latest.id} action=${action.id} '
      'policy=${action.policy.name} status=${projectedStatus.name}',
    );
    return runAutopilotNextAction(latest, action);
  }

  void _queueAggressiveAutopilot(TaskSession task) {
    _autopilotQueue = _autopilotQueue.then((_) async {
      try {
        await _maybeRunAggressiveAutopilot(task);
      } catch (error) {
        debugPrint('Aggressive autopilot skipped: $error');
      }
    });
    unawaited(_autopilotQueue);
  }

  Future<bool> _maybeAutoApproveAggressive(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    if (latest.approvalMode != AgentApprovalMode.aggressive) {
      _runtimeDiag('AUTO_APPROVE_SKIP task=${latest.id} reason=mode');
      return false;
    }
    final status = _taskStatus(latest);
    if (status != TaskStatus.needApproval &&
        _projectedTaskStatus(latest) != TaskStatus.needApproval) {
      _runtimeDiag(
        'AUTO_APPROVE_SKIP task=${latest.id} reason=status '
        'status=${status.name} projected=${_projectedTaskStatus(latest).name}',
      );
      return false;
    }
    final approval = _nativeApprovalForTask(latest);
    if (approval == null || approval.state != ApprovalState.pending) {
      _runtimeDiag('AUTO_APPROVE_SKIP task=${latest.id} reason=no_approval');
      return false;
    }
    final inFlightKey = '${latest.id}|${approval.id}';
    if (_autoApprovalsInFlight.contains(inFlightKey)) {
      _runtimeDiag(
        'AUTO_APPROVE_SKIP task=${latest.id} reason=in_flight '
        'approval=${approval.id}',
      );
      return false;
    }
    _runtimeDiag(
      'AUTO_APPROVE_RUN task=${latest.id} approval=${approval.id} '
      'options=${approval.options.length}',
    );
    _autoApprovalsInFlight.add(inFlightKey);
    try {
      if (approval.options.isNotEmpty) {
        final optionKey = _nativeApprovalOptionKeyForDecision(approval, true);
        final option = approval.options.firstWhere(
          (item) => item.key == optionKey,
          orElse: () => approval.options.first,
        );
        await _selectNativeApprovalOption(
          latest,
          approval,
          option,
          approved: true,
        );
        await _recordAutoApproval(_latestTask(latest.id) ?? latest, approval);
        return true;
      }
      await resolveApproval(latest, approved: true);
      await _recordAutoApproval(_latestTask(latest.id) ?? latest, approval);
      return true;
    } finally {
      _autoApprovalsInFlight.remove(inFlightKey);
    }
  }

  Future<void> _recordAutoApproval(
    TaskSession task,
    NativeTerminalApproval approval,
  ) async {
    final latest = _latestTask(task.id) ?? task;
    final now = DateTime.now();
    await saveTask(
      latest.copyWith(
        metricEvents: _metricEventsWithCreated(
          latest.metricEvents,
          taskId: latest.id,
          eventType: 'approval_auto_approved',
          payloadJson: jsonEncode({
            'approvalId': approval.id,
            'mode': latest.approvalMode.name,
            'optionCount': approval.options.length,
          }),
          now: now,
        ),
      ),
      publishDeliverable: false,
    );
  }

  bool _canAutopilotContinue(TaskSession task) {
    final status = _projectedTaskStatus(task);
    if (status != TaskStatus.turnIdle && status != TaskStatus.needAttention) {
      return false;
    }
    final latestTurn = task.turns.lastOrNull;
    return latestTurn?.deliverable != null &&
        _isAutopilotSafeTurnStatus(latestTurn!.status);
  }

  bool _isAutopilotSafeTurnStatus(NativeOutputTurnStatus status) {
    return status == NativeOutputTurnStatus.turnIdle ||
        status == NativeOutputTurnStatus.needAttention;
  }

  bool _hasAutoAction(TaskSession task, LoopNextAction action) {
    final latestTurn = task.turns.lastOrNull;
    final deliverable = latestTurn?.deliverable;
    if (latestTurn == null || deliverable == null) {
      return false;
    }
    final key = _autoActionDedupeKey(
      turnId: latestTurn.id,
      evidenceFingerprint: deliverable.evidenceFingerprint,
      actionId: action.id,
    );
    return task.metricEvents.any((event) {
      if (event.eventType != LoopAutoAction.metricEventType) {
        return false;
      }
      try {
        final autoAction = LoopAutoAction.fromJson(
          jsonDecode(event.payloadJson) as Map<String, Object?>,
        );
        return autoAction.state == LoopAutoActionState.sent &&
            autoAction.dedupeKey == key;
      } catch (_) {
        return false;
      }
    });
  }

  int _sentAutoActionCount(TaskSession task) {
    var count = 0;
    for (final event in task.metricEvents) {
      if (event.eventType != LoopAutoAction.metricEventType) {
        continue;
      }
      try {
        final autoAction = LoopAutoAction.fromJson(
          jsonDecode(event.payloadJson) as Map<String, Object?>,
        );
        if (autoAction.state == LoopAutoActionState.sent) {
          count++;
        }
      } catch (_) {}
    }
    return count;
  }

  Future<void> _recordLoopAutoAction(
    TaskSession task,
    LoopNextAction action, {
    required LoopAutoActionState state,
  }) async {
    final latest = _latestTask(task.id) ?? task;
    final latestTurn = latest.turns.lastOrNull;
    final deliverable = latestTurn?.deliverable;
    if (latestTurn == null || deliverable == null) {
      return;
    }
    final now = DateTime.now();
    final autoAction = LoopAutoAction(
      id: 'loop-auto-${latest.id}-${now.microsecondsSinceEpoch}',
      taskId: latest.id,
      actionId: action.id,
      createdAt: now,
      turnId: latestTurn.id,
      turnIndex: latestTurn.turnIndex,
      evidenceFingerprint: deliverable.evidenceFingerprint,
      policy: action.policy.name,
      state: state,
      instructionLength: action.draft.trim().length,
    );
    final updated = latest.copyWith(
      metricEvents: MetricEvent.appendControlled(
        latest.metricEvents,
        MetricEvent.create(
          taskId: latest.id,
          eventType: LoopAutoAction.metricEventType,
          payloadJson: jsonEncode(autoAction.toJson()),
          now: now,
        ),
      ),
    );
    await saveTask(updated, publishDeliverable: false);
  }

  String _autoActionDedupeKey({
    required String turnId,
    required String evidenceFingerprint,
    required String actionId,
  }) =>
      '$turnId|$evidenceFingerprint|$actionId';

  Future<void> selectTerminalOption(
      TaskSession task, NativeApprovalOption option,
      {String customResponse = '',
      bool? approvalDecision,
      NativeTerminalApproval? approval}) async {
    final latest = _latestTask(task.id) ?? task;
    final nativeApproval =
        approval ?? _nativeApprovalForOption(task.id, option);
    if (nativeApproval == null) {
      throw StateError('Terminal prompt option is no longer available.');
    }
    await agentSessionService.selectTerminalOption(
      await _controlRequest(latest),
      option.key,
    );
    final trimmedResponse = customResponse.trim();
    if (trimmedResponse.isNotEmpty) {
      await agentSessionService.sendFollowUp(
        await _controlRequest(latest, instruction: trimmedResponse),
      );
    }
    final taskForSave = approvalDecision == null
        ? _taskWithTerminalOptionSelection(latest, nativeApproval, option)
        : _taskWithApprovalDecision(
            latest,
            approved: approvalDecision,
            nativeApproval: nativeApproval,
            selectedOptionKey: option.key,
          );
    final approvalEventKind = approvalDecision == null
        ? LoopApprovalEventKind.optionSelected
        : approvalDecision
            ? LoopApprovalEventKind.approved
            : LoopApprovalEventKind.rejected;
    final taskWithApprovalFact = _taskWithApprovalEvent(
      taskForSave,
      approval: nativeApproval,
      kind: approvalEventKind,
      status: TaskStatus.running,
      selectedOptionKey: option.key,
      customResponseLength: trimmedResponse.length,
      now: DateTime.now(),
    );
    await _saveControlledTask(
      trimmedResponse.isEmpty
          ? taskWithApprovalFact
          : _taskWithApprovalEvent(
              taskWithApprovalFact,
              approval: nativeApproval,
              kind: LoopApprovalEventKind.customResponse,
              status: TaskStatus.running,
              selectedOptionKey: option.key,
              customResponseLength: trimmedResponse.length,
              now: DateTime.now(),
            ),
      status: TaskStatus.running,
      logMessage: 'Terminal option selected by user: ${option.key}.',
      eventType: 'terminal_prompt_resolved',
      turnStatus: NativeOutputTurnStatus.running,
    );
    final updatedTask = _latestTask(task.id) ?? latest;
    startTaskExecution(updatedTask, _attachRequest(updatedTask));
  }

  NativeTerminalApproval? _nativeApprovalForOption(
    String taskId,
    NativeApprovalOption option,
  ) {
    final approval = bridgeRuntime.workState(taskId)?.approval;
    if (approval == null || approval.state != ApprovalState.pending) {
      return null;
    }
    return approval.options.any((candidate) => candidate.key == option.key)
        ? approval
        : null;
  }

  Future<void> reconnectTask(
    TaskSession task, {
    String rawVoiceText = '',
  }) async {
    final latest = _withVoiceInput(
      _latestTask(task.id) ?? task,
      rawVoiceText,
      DateTime.now(),
    );
    await _saveControlledTask(
      latest,
      status: TaskStatus.running,
      logMessage: 'Observer reconnected by user.',
      eventType: 'observer_reconnected',
      turnStatus: NativeOutputTurnStatus.running,
    );
    final attached = _latestTask(task.id) ?? latest;
    bridgeRuntime.notifyObserverAttached(task.id);
    bridgeRuntime.notifyConnectionRestored(task.id);
    startTaskExecution(attached, _attachRequest(attached));
  }

  Future<void> pauseTask(TaskSession task) async {
    await agentSessionService.pause(await _controlRequest(task));
    await disconnectTask(task, markFailed: false, recordDetached: false);
    final latest = _latestTask(task.id) ?? task;
    await _saveControlledTask(
      latest,
      status: TaskStatus.paused,
      logMessage: 'Task paused by user.',
    );
  }

  Future<void> resumeTask(
    TaskSession task, {
    String rawVoiceText = '',
  }) async {
    await agentSessionService.resume(await _controlRequest(task));
    final latest = _withVoiceInput(
      _latestTask(task.id) ?? task,
      rawVoiceText,
      DateTime.now(),
    );
    await _saveControlledTask(
      latest,
      status: TaskStatus.running,
      logMessage: 'Task resumed by user.',
      turnStatus: NativeOutputTurnStatus.running,
    );
    final resumed = _latestTask(task.id) ?? latest;
    bridgeRuntime.notifyObserverAttached(task.id);
    bridgeRuntime.notifyConnectionRestored(task.id);
    startTaskExecution(resumed, _attachRequest(resumed));
  }

  Future<void> interruptTask(TaskSession task) async {
    await agentSessionService.interrupt(await _controlRequest(task));
    final latest = _latestTask(task.id) ?? task;
    await _saveControlledTask(
      latest,
      status: _taskStatus(latest),
      logMessage: 'User sent interrupt signal (Ctrl+C) to remote agent.',
      eventType: 'user_interrupt',
    );
  }

  Future<void> stopTask(
    TaskSession task, {
    String rawVoiceText = '',
  }) async {
    final latest = _withVoiceInput(
      _latestTask(task.id) ?? task,
      rawVoiceText,
      DateTime.now(),
    );
    await _saveControlledTask(
      latest,
      status: TaskStatus.stopped,
      logMessage: 'Task stopped by user.',
      completed: true,
      turnStatus: NativeOutputTurnStatus.stopped,
      userDecision: 'stopped',
    );
    try {
      await agentSessionService.stop(await _controlRequest(latest));
    } catch (error) {
      await _recordCleanupFailure(_latestTask(task.id) ?? latest, error);
      rethrow;
    }
  }

  Future<String> _captureLogBestEffort(AgentControlRequest request) async {
    try {
      return await agentSessionService.captureLog(request);
    } catch (_) {
      return '';
    }
  }

  bool _canRefreshRemoteState(TaskSession task) {
    return switch (_taskStatus(task)) {
      TaskStatus.running ||
      TaskStatus.needApproval ||
      TaskStatus.needAttention ||
      TaskStatus.turnIdle ||
      TaskStatus.observerDetached =>
        true,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.runtimeLost ||
      TaskStatus.paused ||
      TaskStatus.stopped ||
      TaskStatus.completed ||
      TaskStatus.userCompleted ||
      TaskStatus.failed ||
      TaskStatus.userFailed =>
        false,
    };
  }

  void _startRemoteReconcileLoop() {
    if (!_enableRemoteReconcile ||
        agentSessionService is! RemoteTaskProbeService) {
      return;
    }
    bridgeRuntime.startReconcileLoop(
      loadTargets: _loadRuntimeReconcileTargets,
      probe: _probeRuntimeTarget,
      onDecision: _applyRuntimeReconcileDecision,
      interval: _remoteReconcileInterval,
    );
  }

  void _startRemoteSnapshotPollLoop() {
    if (!_enableRemoteReconcile ||
        _remoteSnapshotPollInterval <= Duration.zero) {
      return;
    }
    _remoteSnapshotPollTimer ??= Timer.periodic(
      _remoteSnapshotPollInterval,
      (_) => unawaited(_runRemoteSnapshotPoll()),
    );
  }

  Future<void> _runRemoteSnapshotPoll() async {
    if (_remoteSnapshotPollRunning || !ready || _disposed) {
      return;
    }
    _remoteSnapshotPollRunning = true;
    try {
      final candidates = activeTasks
          .where(_canAutoPollRemoteSnapshot)
          .take(_kSnapshotPollMaxTasks)
          .toList(growable: false);
      for (final task in candidates) {
        if (_disposed) {
          return;
        }
        try {
          await _captureAndApplyRemoteSnapshot(
            task,
            allowSettled: true,
          );
        } catch (error) {
          debugPrint('Remote snapshot poll skipped for ${task.id}: $error');
        }
      }
    } finally {
      _remoteSnapshotPollRunning = false;
    }
  }

  bool _canAutoPollRemoteSnapshot(TaskSession task) {
    return _canRefreshRemoteState(task);
  }

  Future<List<RuntimeReconcileTarget>> _loadRuntimeReconcileTargets() async {
    if (!ready) {
      return const [];
    }
    final candidates = activeTasks;
    final result = candidates
        .where((t) =>
            _canAutoReconcileRemoteState(t) &&
            (_reconcileMissStreak[t.id] ?? 0) < _kReconcileMaxMissStreak)
        .map(
          (task) => RuntimeReconcileTarget(
            taskId: task.id,
            status: RuntimeTaskSnapshot.fromTaskStatus(
              taskId: task.id,
              status: _taskStatus(task),
              createdAt: task.createdAt,
              updatedAt: task.updatedAt,
            ).status,
          ),
        )
        .toList(growable: false);
    return result;
  }

  Future<RuntimeRemoteProbe> _probeRuntimeTarget(
    RuntimeReconcileTarget target,
  ) async {
    final probeService = agentSessionService;
    if (probeService is! RemoteTaskProbeService) {
      return const RuntimeRemoteProbe(sessionExists: false);
    }
    final remoteProbeService = probeService as RemoteTaskProbeService;
    final task = _latestTask(target.taskId);
    if (task == null || !_canAutoReconcileRemoteState(task)) {
      return const RuntimeRemoteProbe(sessionExists: false);
    }
    final probe = await remoteProbeService.probeRemoteState(
      await _controlRequest(task),
    );
    final hasNewExitMarker = _hasNewRemoteExitMarker(
      task.id,
      probe.exitMarkerCount,
    );
    return RuntimeRemoteProbe(
      sessionExists: probe.sessionExists,
      snapshot: probe.snapshot,
      needsAttention: probe.needsAttention,
      hasExitedMarker: hasNewExitMarker,
      exitMarkerCount: probe.exitMarkerCount,
    );
  }

  bool _hasNewRemoteExitMarker(String taskId, int exitMarkerCount) {
    final previous = _remoteExitMarkerCounts[taskId];
    _remoteExitMarkerCounts[taskId] = exitMarkerCount;
    if (previous == null) {
      return false;
    }
    return exitMarkerCount > previous;
  }

  Future<void> _applyRuntimeReconcileDecision(
    RuntimeReconcileDecision decision,
  ) async {
    if (decision.action == RuntimeReconcileAction.none) {
      return;
    }
    final task = _latestTask(decision.taskId);
    if (task == null || !_canRefreshRemoteState(task)) {
      _reconcileMissStreak.remove(decision.taskId);
      return;
    }
    // When session is confirmed missing, directly mark as runtimeLost.
    // Do NOT call refreshTaskFromRemote — capture will fail anyway.
    if (decision.reason == RuntimeReconcileReason.sessionMissing) {
      await _saveControlledTask(
        task,
        status: TaskStatus.runtimeLost,
        logMessage: 'Remote session not found by reconcile probe.',
        completed: true,
        eventType: 'runtime_lost_reconcile',
      );
      return;
    }
    _reconcileMissStreak.remove(decision.taskId);
    await refreshTaskFromRemote(task);
  }

  bool _canAutoReconcileRemoteState(TaskSession task) {
    return switch (_taskStatus(task)) {
      TaskStatus.running ||
      TaskStatus.observerDetached ||
      TaskStatus.turnIdle ||
      TaskStatus.needAttention ||
      TaskStatus.needApproval =>
        true,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.runtimeLost ||
      TaskStatus.paused ||
      TaskStatus.stopped ||
      TaskStatus.completed ||
      TaskStatus.userCompleted ||
      TaskStatus.failed ||
      TaskStatus.userFailed =>
        false,
    };
  }

  Future<void> _applyCapturedRemoteSnapshot(
    TaskSession task,
    String snapshot, {
    bool allowSettled = false,
  }) async {
    final observer = NativeOutputObserver(
      runtimeAdapter: AgentRuntimeAdapter.forCommand(task.host.agentCommand),
      idleThreshold: const RuntimePolicy()
          .forApprovalMode(task.approvalMode)
          .idleThreshold,
    );
    final observed = allowSettled
        ? observer.observeSettled(snapshot)
        : observer.observe(snapshot);
    final terminalPrompt = const TerminalPromptParser().parse(snapshot);
    final hasAttention = terminalPrompt != null &&
        !(allowSettled && observed.turnIdle) &&
        !_hasNewerWorkOutputAfterAttention(snapshot, terminalPrompt);
    final nativeApproval = hasAttention
        ? _nativeApprovalFromTerminalPrompt(
            terminalPrompt,
            task.id,
            DateTime.now(),
          )
        : null;
    final cleanedOutput = observed.cleanedOutput.trim().isNotEmpty
        ? observed.cleanedOutput
        : snapshot;
    final update = AgentExecutionUpdate(
      rawOutput: '',
      cleanedOutput: cleanedOutput,
      observerState: observed.state,
      turnIdle: allowSettled && observed.turnIdle,
      runtimeLost: observed.runtimeLost,
      needsAttention: hasAttention || observed.needsAttention,
      nativeApproval: nativeApproval,
      done: !hasAttention &&
          (observed.runtimeLost ||
              observed.needsAttention ||
              (allowSettled && observed.turnIdle)),
    );
    final hasStrongState = hasAttention ||
        observed.runtimeLost ||
        observed.needsAttention ||
        (allowSettled && observed.turnIdle);
    if (!hasStrongState) {
      _notifyRuntimeOutput(task.id, snapshot);
      return;
    }
    final updated = _taskWithExecutionUpdate(
      task,
      update,
      reopenResolvedApproval: true,
    );
    if (_taskSnapshotSignature(task) == _taskSnapshotSignature(updated) &&
        _latestTurnOutputSignature(task) ==
            _latestTurnOutputSignature(updated)) {
      return;
    }
    await saveTask(updated);
    if (_taskStatus(updated) == TaskStatus.turnIdle) {
      _cancelRunningObserver(updated.id);
    }
  }

  void _cancelRunningObserver(String taskId) {
    final subscription = _runningExecutions.remove(taskId);
    _cancelAutoDetachTimer(taskId);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  bool _hasNewerWorkOutputAfterAttention(
    String snapshot,
    TerminalPrompt? terminalPrompt,
  ) {
    final anchor = terminalPrompt?.question.trim() ?? '';
    if (anchor.isEmpty) {
      return false;
    }
    final index = snapshot.toLowerCase().lastIndexOf(anchor.toLowerCase());
    if (index < 0) {
      return false;
    }
    final tail = snapshot.substring(index + anchor.length);
    return tail.split('\n').any(_isNewerWorkOutputLine);
  }

  bool _isNewerWorkOutputLine(String line) {
    final text = line.trim();
    if (text.isEmpty) {
      return false;
    }
    if (RegExp(r'^(?:[❯>]\s*)?\d+\.\s+').hasMatch(text)) {
      return false;
    }
    if (text == 'Permission Required' || text == 'Apply this change?') {
      return false;
    }
    return text == 'Thinking' ||
        text.startsWith('▪') ||
        text.startsWith('▫') ||
        text.startsWith('> ') ||
        text.contains('Armin Codex exited with status') ||
        text.contains('Armin Qoder exited with status');
  }

  String _taskSnapshotSignature(TaskSession task) =>
      '${_taskStatus(task).name}|${_projectedStatusSignature(task)}';

  String _latestTurnOutputSignature(TaskSession task) {
    final turn = task.turns.lastOrNull;
    if (turn == null) {
      return '';
    }
    return [
      turn.id,
      turn.rawOutput.hashCode,
      turn.cleanedOutput.hashCode,
      turn.lastOutputAt.microsecondsSinceEpoch,
    ].join('|');
  }

  String _projectedStatusSignature(TaskSession task) {
    final latestTurn = task.turns.lastOrNull;
    return [
      _projectedTaskStatus(task).name,
      task.nativeApproval?.question ?? '',
      task.completedAt?.microsecondsSinceEpoch.toString() ?? '',
      task.scheduledFor?.microsecondsSinceEpoch.toString() ?? '',
      task.turns.length.toString(),
      if (latestTurn != null) ...[
        latestTurn.id,
        latestTurn.status.name,
        latestTurn.userDecision ?? '',
        latestTurn.deliverable?.evidenceFingerprint ?? '',
      ],
    ].join('|');
  }

  Future<void> markTaskCompleted(
    TaskSession task, {
    String rawVoiceText = '',
  }) async {
    final latest = _withVoiceInput(
      _latestTask(task.id) ?? task,
      rawVoiceText,
      DateTime.now(),
    );
    await _saveControlledTask(
      latest,
      status: TaskStatus.userCompleted,
      logMessage: 'Task marked completed by user.',
      completed: true,
      eventType: 'user_mark_completed',
      turnStatus: NativeOutputTurnStatus.completedByUser,
      userDecision: 'completed',
      loopActionKind: LoopUserActionKind.markCompleted,
      loopActionSource: rawVoiceText.trim().isEmpty ? 'text' : 'voice',
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? latest);
  }

  Future<void> markTaskFailed(
    TaskSession task, {
    String rawVoiceText = '',
  }) async {
    final latest = _withVoiceInput(
      _latestTask(task.id) ?? task,
      rawVoiceText,
      DateTime.now(),
    );
    await _saveControlledTask(
      latest,
      status: TaskStatus.userFailed,
      logMessage: 'Task marked failed by user.',
      completed: true,
      eventType: 'user_mark_failed',
      turnStatus: NativeOutputTurnStatus.failedByUser,
      userDecision: 'failed',
      loopActionKind: LoopUserActionKind.markFailed,
      loopActionSource: rawVoiceText.trim().isEmpty ? 'text' : 'voice',
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? latest);
  }

  Future<void> acceptLatestResult(TaskSession task) async {
    await _recordLoopUserAction(
      task,
      kind: LoopUserActionKind.acceptResult,
      eventType: 'loop_result_accepted',
    );
  }

  Future<void> rejectOrRedoLatestResult(TaskSession task) async {
    await _recordLoopUserAction(
      task,
      kind: LoopUserActionKind.rejectOrRedo,
      eventType: 'loop_result_rejected',
    );
  }

  Future<void> cleanupRemoteSession(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    await agentSessionService.cleanup(await _controlRequest(latest));
    await _saveControlledTask(
      latest,
      status: _taskStatus(latest),
      logMessage: 'Remote tmux session cleanup requested by user.',
      eventType: 'runtime_cleanup',
    );
  }

  void startTaskExecution(
    TaskSession initialTask,
    AgentExecutionRequest request,
  ) {
    final previous = _runningExecutions.remove(initialTask.id);
    if (previous != null) {
      unawaited(previous.cancel());
    }

    var task = initialTask;
    var bufferedTurnOutput = '';
    var pendingUpdates = Future<void>.value();
    late final StreamSubscription<AgentExecutionUpdate> subscription;
    subscription = agentSessionService.execute(request).listen(
      (update) {
        pendingUpdates = pendingUpdates.then((_) async {
          if (_runningExecutions[task.id] != subscription) {
            return;
          }
          final latest = _latestTask(task.id) ?? task;
          if (_isTerminal(_taskStatus(latest))) {
            await disconnectTask(latest,
                markFailed: false, recordDetached: false);
            return;
          }
          final previousTask = latest;
          final hasStatusChange =
              _updateWouldChangeStatus(previousTask, update);
          if (hasStatusChange) {
            final effectiveUpdate = _executionUpdateWithBufferedOutput(
              update,
              bufferedTurnOutput,
            );
            _runtimeDiag(
              'APP_UPDATE task=${previousTask.id} '
              'status=${_taskStatus(previousTask).name} '
              'turnIdle=${effectiveUpdate.turnIdle} '
              'done=${effectiveUpdate.done} '
              'runtimeLost=${effectiveUpdate.runtimeLost} '
              'needsAttention=${effectiveUpdate.needsAttention} '
              'observer=${effectiveUpdate.observerState.name}',
            );
            task = _taskWithExecutionUpdate(previousTask, effectiveUpdate);
            await saveTask(task);
            final savedStatus = _projectedTaskStatus(task);
            final runtimeStatus = _taskStatus(task);
            if (savedStatus == TaskStatus.needApproval ||
                runtimeStatus == TaskStatus.needApproval) {
              try {
                await _maybeAutoApproveAggressive(task);
              } catch (error) {
                debugPrint('Aggressive auto approval skipped: $error');
              }
            }
            if (savedStatus == TaskStatus.turnIdle ||
                _isTerminal(savedStatus)) {
              _stopObserverForSettledTurn(task.id, subscription);
              bufferedTurnOutput = '';
              if (_isTerminal(savedStatus)) {
                await _cleanupTaskSession(task);
              }
            }
            _runtimeDiag(
              'APP_SAVED task=${task.id} '
              'status=${_taskStatus(task).name} '
              'turn=${task.turns.lastOrNull?.status.name ?? 'none'}',
            );
          } else {
            bufferedTurnOutput = _mergeBufferedTurnOutput(
              bufferedTurnOutput,
              update.cleanedOutput?.trim().isNotEmpty == true
                  ? update.cleanedOutput!
                  : update.rawOutput,
            );
            task = previousTask;
          }
          _notifyRuntimeOutput(task.id, update.rawOutput);
        });
      },
      onError: (Object error) async {
        await pendingUpdates;
        if (_runningExecutions[task.id] != subscription) {
          return;
        }
        _runningExecutions.remove(task.id);
        _cancelAutoDetachTimer(task.id);
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(_taskStatus(latest))) {
          return;
        }
        if (_isRecoverableObserverError(error)) {
          await _saveObserverDisconnected(latest, error);
          return;
        }
        final failedTask = await _saveFailedExecution(latest, error);
        await _cleanupTaskSession(failedTask);
      },
      onDone: () async {
        await pendingUpdates;
        if (_runningExecutions[task.id] != subscription) {
          return;
        }
        _runningExecutions.remove(task.id);
        _cancelAutoDetachTimer(task.id);
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(_taskStatus(latest))) {
          await _cleanupTaskSession(latest);
          return;
        }
        await _captureAndApplyRemoteSnapshot(latest, allowSettled: true);
      },
    );
    _runningExecutions[initialTask.id] = subscription;
    _scheduleAutoDetach(initialTask.id);
  }

  AgentExecutionUpdate _executionUpdateWithBufferedOutput(
    AgentExecutionUpdate update,
    String bufferedOutput,
  ) {
    final mergedOutput = _mergeBufferedTurnOutput(
      bufferedOutput,
      update.cleanedOutput?.trim().isNotEmpty == true
          ? update.cleanedOutput!
          : update.rawOutput,
    );
    if (mergedOutput.trim().isEmpty) {
      return update;
    }
    return AgentExecutionUpdate(
      rawOutput: update.rawOutput,
      cleanedOutput: mergedOutput,
      observerState: update.observerState,
      turnIdle: update.turnIdle,
      runtimeLost: update.runtimeLost,
      needsAttention: update.needsAttention,
      nativeApproval: update.nativeApproval,
      done: update.done,
    );
  }

  String _mergeBufferedTurnOutput(String current, String next) {
    final cleaned = const AgentOutputCleaner().clean(next).trim();
    if (cleaned.isEmpty) {
      return current;
    }
    final existing = current.trim();
    if (existing.isEmpty) {
      return cleaned;
    }
    if (existing.contains(cleaned)) {
      return existing;
    }
    return '$existing\n$cleaned';
  }

  void _scheduleAutoDetach(String taskId) {
    _cancelAutoDetachTimer(taskId);
    if (_keepObserverAttachedTaskIds.contains(taskId)) {
      _runtimeDiag('AUTO_DETACH_SKIP task=$taskId reason=autopilot');
      return;
    }
    if (AgentRuntimeConfig.autoDetachDuration <= Duration.zero) {
      return;
    }
    _autoDetachTimers[taskId] = Timer(
      AgentRuntimeConfig.autoDetachDuration,
      () {
        final task = _latestTask(taskId);
        if (task == null || _runningExecutions[taskId] == null) {
          return;
        }
        unawaited(_autoDetachTask(task));
      },
    );
  }

  void _cancelAutoDetachTimer(String taskId) {
    _autoDetachTimers.remove(taskId)?.cancel();
  }

  void _stopObserverForSettledTurn(
    String taskId,
    StreamSubscription<AgentExecutionUpdate> subscription,
  ) {
    if (_runningExecutions[taskId] != subscription) {
      return;
    }
    _runningExecutions.remove(taskId);
    _keepObserverAttachedTaskIds.remove(taskId);
    _cancelAutoDetachTimer(taskId);
    unawaited(subscription.cancel());
  }

  Future<void> _autoDetachTask(TaskSession task) async {
    await disconnectTask(task,
        markFailed: false, recordDetached: true, reason: 'auto_detach');
  }

  Future<void> disconnectTask(
    TaskSession task, {
    bool markFailed = false,
    bool recordDetached = true,
    String reason = 'user',
  }) async {
    final subscription = _runningExecutions.remove(task.id);
    _cancelAutoDetachTimer(task.id);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    if (!markFailed) {
      if (!recordDetached) {
        return;
      }
      final isAutoDetach = reason == 'auto_detach';
      await _saveControlledTask(
        task,
        status: TaskStatus.observerDetached,
        logMessage: isAutoDetach
            ? 'Observer auto-detached to save phone resources. Remote tmux session continues.'
            : 'Observer detached by user. Remote tmux session may still be running.',
        eventType:
            isAutoDetach ? 'observer_auto_detached' : 'observer_detached',
      );
      return;
    }
    await _saveControlledTask(
      task,
      status: TaskStatus.failed,
      logMessage:
          'Observer detached by user. Remote task may still be running.',
      completed: true,
    );
  }

  Future<void> _cleanupTaskSession(TaskSession task) async {
    try {
      await agentSessionService.cleanup(await _controlRequest(task));
    } catch (error) {
      await _recordCleanupFailure(task, error);
    }
  }

  Future<void> _recordCleanupFailure(TaskSession task, Object error) async {
    final latest = _latestTask(task.id) ?? task;
    final safeError = _secretRedactor.redactInlineSecrets('$error');
    await _saveControlledTask(
      latest,
      status: _taskStatus(latest),
      logMessage: 'Remote tmux session cleanup failed: $safeError',
      eventType: 'runtime_cleanup_failed',
    );
  }

  Future<void> resolveApproval(TaskSession task,
      {required bool approved}) async {
    final nativeApproval = bridgeRuntime.workState(task.id)?.approval;
    // Notify bridge that we are resolving approval.
    bridgeRuntime.notifyApprovalResolving(task.id);

    // When the approval card is backed by a native terminal prompt (e.g.
    // Codex CLI "Allow execution of ..."), route to the terminal option
    // selection flow so the agent receives the expected numbered key.
    if (nativeApproval != null && nativeApproval.options.isNotEmpty) {
      final optionKey = _nativeApprovalOptionKeyForDecision(
        nativeApproval,
        approved,
      );
      final option = nativeApproval.options.firstWhere(
        (opt) => opt.key == optionKey,
        orElse: () => nativeApproval.options.first,
      );
      try {
        await _selectNativeApprovalOption(
          task,
          nativeApproval,
          option,
          approved: approved,
        );
      } catch (_) {
        bridgeRuntime.notifyApprovalFailed(task.id);
        rethrow;
      }
      // Native terminal approval resolved.
      bridgeRuntime.notifyApprovalResolved(task.id);
      return;
    }
    final decision = approved ? 'approved' : 'rejected';
    await sendFollowUp(
      task,
      '''
APPROVAL_DECISION:
decision: $decision
Apply this decision to the pending approval request.
''',
    );
    await _saveApprovalDecision(task, approved: approved);
    final updatedTask = _latestTask(task.id) ?? task;
    startTaskExecution(updatedTask, _attachRequest(updatedTask));
    if (approved) {
      bridgeRuntime.notifyApprovalResolved(task.id);
    } else {
      bridgeRuntime.notifyApprovalRejected(task.id);
    }
  }

  String _nativeApprovalOptionKeyForDecision(
    NativeTerminalApproval approval,
    bool approved,
  ) {
    if (approval.options.isEmpty) {
      return approved ? 'approve' : 'reject';
    }
    if (approved) {
      for (final option in approval.options) {
        final lower = option.label.toLowerCase();
        if (lower.contains('allow once') ||
            lower.contains('允许一次') ||
            lower == 'allow' ||
            lower == 'yes' ||
            lower == '是') {
          return option.key;
        }
      }
      return approval.options.first.key;
    }
    for (final option in approval.options.reversed) {
      final lower = option.label.toLowerCase();
      if (lower.contains('reject') ||
          lower.contains('no') ||
          lower.contains('拒绝') ||
          lower == '否') {
        return option.key;
      }
    }
    return approval.options.last.key;
  }

  Future<void> _selectNativeApprovalOption(
    TaskSession task,
    NativeTerminalApproval approval,
    NativeApprovalOption option, {
    required bool approved,
  }) {
    return selectTerminalOption(
      task,
      option,
      approvalDecision: approved,
      approval: approval,
    );
  }

  HostConfig? get defaultHost {
    if (hosts.isEmpty) {
      return null;
    }
    // Return the host marked as default, or fall back to first host
    final defaultHost = hosts.where((h) => h.isDefault).firstOrNull;
    return defaultHost ?? hosts.first;
  }

  ProjectPathConfig? get defaultProjectPath {
    if (projectPaths.isEmpty) {
      return null;
    }
    final defaultPath =
        projectPaths.where((path) => path.isDefault).firstOrNull;
    return defaultPath ?? projectPaths.first;
  }

  Future<AgentControlRequest> _controlRequest(
    TaskSession task, {
    String instruction = '',
  }) async {
    final host = _controlHost(task);
    return AgentControlRequest(
      host: host.host,
      port: host.port,
      username: host.username,
      tmuxSessionName: task.host.tmuxSessionName,
      tmuxCommand: host.tmuxCommand,
      pathPrepend: host.pathPrepend,
      shellWrapper: host.shellWrapper,
      password: host.password,
      instruction: instruction,
    );
  }

  HostConfig _controlHost(TaskSession task) {
    for (final host in hosts) {
      if (host.id == task.host.id) {
        return host;
      }
    }
    return task.host;
  }

  AgentExecutionRequest _attachRequest(TaskSession task) {
    final host = _controlHost(task);
    return AgentExecutionRequest(
      prompt: '',
      hostId: host.id,
      host: host.host,
      port: host.port,
      username: host.username,
      projectPath: task.host.projectPath,
      tmuxSessionName: task.host.tmuxSessionName,
      agentCommand: host.agentCommand,
      tmuxCommand: host.tmuxCommand,
      pathPrepend: host.pathPrepend,
      shellWrapper: host.shellWrapper,
      password: host.password,
      attachOnly: true,
      approvalConfig: AgentApprovalConfig(
        agentType: AgentTypeDetection.detect(host.agentCommand),
        mode: task.approvalMode,
      ),
    );
  }

  AgentExecutionRequest _executionRequest(TaskSession task) {
    final host = _controlHost(task);
    return AgentExecutionRequest(
      prompt: task.finalPrompt,
      hostId: host.id,
      host: host.host,
      port: host.port,
      username: host.username,
      projectPath: task.host.projectPath,
      tmuxSessionName: task.host.tmuxSessionName,
      agentCommand: host.agentCommand,
      tmuxCommand: host.tmuxCommand,
      pathPrepend: host.pathPrepend,
      shellWrapper: host.shellWrapper,
      password: host.password,
      approvalConfig: AgentApprovalConfig(
        agentType: AgentTypeDetection.detect(host.agentCommand),
        mode: task.approvalMode,
      ),
    );
  }

  Future<void> _saveControlledTask(
    TaskSession task, {
    required TaskStatus status,
    required String logMessage,
    bool completed = false,
    String eventType = 'runtime_control',
    NativeOutputTurnStatus? turnStatus,
    String? userDecision,
    LoopUserActionKind? loopActionKind,
    String loopActionSource = 'text',
  }) async {
    final now = DateTime.now();
    final taskWithTurn = turnStatus == null
        ? task
        : _taskWithCurrentTurnDecision(
            task,
            status: turnStatus,
            userDecision: userDecision,
            now: now,
          );
    final taskForSave = loopActionKind == null
        ? taskWithTurn
        : _taskWithLoopUserAction(
            taskWithTurn,
            kind: loopActionKind,
            targetTurn: taskWithTurn.turns.lastOrNull,
            source: loopActionSource,
            status: status,
            now: now,
          );
    final savedTask = _projectTaskStatus(
      taskForSave,
      status: status,
      now: now,
    ).copyWith(
      completedAt: completed
          ? now
          : _completedAtFor(status, taskForSave.completedAt, now),
      metricEvents: _metricEventsWithCreated(
        taskForSave.metricEvents,
        taskId: taskForSave.id,
        eventType: eventType,
        payloadJson: '{"status":"${status.name}"}',
        now: now,
      ),
    );
    await _bridgeEnsureTaskCreated(savedTask);
    await _applyRuntimeTaskStatus(
      savedTask,
      status: status,
      now: now,
    );
    await saveTask(
      savedTask,
      publishDeliverable: false,
    );
  }

  TaskSession _taskWithLoopUserAction(
    TaskSession task, {
    required LoopUserActionKind kind,
    required NativeOutputTurn? targetTurn,
    NativeOutputTurn? nextTurn,
    int instructionLength = 0,
    String source = 'text',
    TaskStatus? status,
    required DateTime now,
  }) {
    if (targetTurn == null) {
      return task;
    }
    final action = LoopUserAction(
      id: 'loop-action-${now.microsecondsSinceEpoch}',
      taskId: task.id,
      kind: kind,
      createdAt: now,
      turnId: targetTurn.id,
      turnIndex: targetTurn.turnIndex,
      status: (status ?? _taskStatus(task)).name,
      nextTurnId: nextTurn?.id,
      nextTurnIndex: nextTurn?.turnIndex,
      instructionLength: instructionLength,
      source: source,
    );
    return task.copyWith(
      metricEvents: _metricEventsWithCreated(
        task.metricEvents,
        taskId: task.id,
        eventType: LoopUserAction.metricEventType,
        payloadJson: jsonEncode(action.toJson()),
        now: now,
      ),
    );
  }

  Future<void> _recordLoopUserAction(
    TaskSession task, {
    required LoopUserActionKind kind,
    required String eventType,
  }) async {
    final latest = _latestTask(task.id) ?? task;
    final now = DateTime.now();
    final updated = _taskWithLoopUserAction(
      latest,
      kind: kind,
      targetTurn: latest.turns.lastOrNull,
      status: _taskStatus(latest),
      now: now,
    );
    await saveTask(
      updated.copyWith(
        updatedAt: now,
        metricEvents: _metricEventsWithCreated(
          updated.metricEvents,
          taskId: updated.id,
          eventType: eventType,
          payloadJson: '{"status":"${_taskStatus(latest).name}"}',
          now: now,
        ),
      ),
      publishDeliverable: false,
    );
  }

  TaskSession _taskWithApprovalEvent(
    TaskSession task, {
    NativeTerminalApproval? approval,
    required LoopApprovalEventKind kind,
    required TaskStatus status,
    required DateTime now,
    String? selectedOptionKey,
    int customResponseLength = 0,
  }) {
    final targetTurn = task.turns.lastOrNull;
    final event = LoopApprovalEvent(
      id: 'loop-approval-${approval?.id ?? 'manual'}-${kind.name}-${now.microsecondsSinceEpoch}',
      taskId: task.id,
      approvalId: approval?.id ?? '',
      kind: kind,
      createdAt: now,
      turnId: targetTurn?.id ?? '',
      turnIndex: targetTurn?.turnIndex ?? 0,
      status: status.name,
      questionLength: approval?.question.trim().length ?? 0,
      optionCount: approval?.options.length ?? 0,
      selectedOptionKey: selectedOptionKey,
      customResponseLength: customResponseLength,
    );
    return task.copyWith(
      metricEvents: _metricEventsWithCreated(
        task.metricEvents,
        taskId: task.id,
        eventType: LoopApprovalEvent.metricEventType,
        payloadJson: jsonEncode(event.toJson()),
        now: now,
      ),
    );
  }

  void _syncScheduledTaskTimers() {
    final activeIds = tasks.map((task) => task.id).toSet();
    for (final id in _scheduledTaskTimers.keys.toList(growable: false)) {
      if (!activeIds.contains(id)) {
        _scheduledTaskTimers.remove(id)?.cancel();
      }
    }
    for (final task in tasks) {
      _syncScheduledTaskTimer(task);
    }
  }

  void _syncScheduledTaskTimer(TaskSession task) {
    _scheduledTaskTimers.remove(task.id)?.cancel();
    if (_disposed ||
        _taskStatus(task) != TaskStatus.pending ||
        task.scheduledFor == null) {
      return;
    }
    final delay = task.scheduledFor!.difference(DateTime.now());
    if (delay <= Duration.zero) {
      scheduleMicrotask(() => unawaited(_startScheduledTask(task.id)));
      return;
    }
    _scheduledTaskTimers[task.id] = Timer(
      delay,
      () => unawaited(_startScheduledTask(task.id)),
    );
  }

  Future<void> _startScheduledTask(String taskId) async {
    if (_disposed) {
      return;
    }
    final latest = _latestTask(taskId);
    if (latest == null ||
        _taskStatus(latest) != TaskStatus.pending ||
        latest.scheduledFor == null) {
      return;
    }
    _scheduledTaskTimers.remove(taskId)?.cancel();
    final now = DateTime.now();
    final running = _projectTaskStatus(
      latest,
      status: TaskStatus.running,
      now: now,
    ).copyWith(
      startedAt: latest.startedAt ?? now,
      metricEvents: _metricEventsWithCreated(
        latest.metricEvents,
        taskId: latest.id,
        eventType: 'task_scheduled_started',
        payloadJson: jsonEncode({
          'scheduledFor': latest.scheduledFor!.toIso8601String(),
        }),
        now: now,
      ),
    );
    await saveTask(running, publishDeliverable: false);
    if (_disposed) {
      return;
    }
    startTaskExecution(
      _latestTask(taskId) ?? running,
      _executionRequest(running),
    );
  }

  // ─── Bridge Runtime integration ───

  Future<void> _enqueueRuntimeSync(TaskSession task) {
    final previous = _runtimeSyncChains[task.id] ?? Future<void>.value();
    final next = previous.then((_) async {
      await _bridgeEnsureTaskCreated(task);
      await _commitRuntimeState(task);
    });
    _runtimeSyncChains[task.id] = next;
    return next.whenComplete(() {
      if (identical(_runtimeSyncChains[task.id], next)) {
        _runtimeSyncChains.remove(task.id);
      }
    });
  }

  /// Single ordered commit into the Runtime state source.
  Future<void> _commitRuntimeState(TaskSession task) async {
    await _applyRuntimeTaskStatus(
      task,
      status: _projectedTaskStatus(task),
      now: DateTime.now(),
    );
  }

  Future<void> _applyRuntimeTaskStatus(
    TaskSession task, {
    required TaskStatus status,
    required DateTime now,
  }) async {
    final summary = _runtimeSummaryForTask(task);
    switch (status) {
      case TaskStatus.draft:
      case TaskStatus.pending:
        await _projectRuntimeStatus(task, status: status, now: now);
      case TaskStatus.needAttention:
        await _projectRuntimeStatus(task, status: status, now: now);
        runtimeEventBus.publish(RuntimeEvent(
          type: RuntimeEventType.waitingForInstruction,
          taskId: task.id,
          createdAt: now,
        ));
      case TaskStatus.turnIdle:
        await bridgeRuntime.markWaitingUser(
          task.id,
          summary: summary,
          now: now,
        );
        final approval = _nativeApprovalForTask(task);
        if (approval != null) {
          bridgeRuntime.notifyApprovalRequested(
            task.id,
            approval: approval,
            now: now,
          );
        }
      case TaskStatus.needApproval:
        await _projectRuntimeStatus(task, status: status, now: now);
        bridgeRuntime.notifyApprovalRequested(
          task.id,
          approval: _nativeApprovalForTask(task),
          now: now,
        );
      case TaskStatus.userCompleted:
      case TaskStatus.completed:
        await bridgeRuntime.completeTask(
          task.id,
          summary: summary,
          now: now,
        );
      case TaskStatus.failed:
      case TaskStatus.userFailed:
        await bridgeRuntime.failTask(
          task.id,
          summary: summary,
          now: now,
        );
      case TaskStatus.runtimeLost:
        await _projectRuntimeStatus(task, status: status, now: now);
        bridgeRuntime.notifyConnectionLost(task.id, now: now);
      case TaskStatus.stopped:
        await bridgeRuntime.cancelTask(
          task.id,
          summary: summary,
          now: now,
        );
      case TaskStatus.paused:
        await bridgeRuntime.pauseTask(
          task.id,
          summary: summary,
          now: now,
        );
      case TaskStatus.observerDetached:
        bridgeRuntime.notifyObserverDetached(task.id, now: now);
      case TaskStatus.running:
        await bridgeRuntime.startTask(
          taskId: task.id,
          sessionName: task.host.projectPath,
          projectPath: task.host.projectPath,
          tmuxSessionName: task.host.tmuxSessionName,
          now: now,
        );
    }
  }

  Future<void> _projectRuntimeStatus(
    TaskSession task, {
    required TaskStatus status,
    required DateTime now,
  }) async {
    final currentWorkState = bridgeRuntime.workState(task.id);
    final reusableWorkState = currentWorkState != null &&
            _taskStatusFromWorkState(currentWorkState, task) == status
        ? currentWorkState
        : null;
    final resolved = resolveRuntimeState(
      task,
      taskStatus: status,
      workState: reusableWorkState,
    );
    await bridgeRuntime.projectTaskState(
      taskId: task.id,
      status: RuntimeTaskSnapshot.fromTaskStatus(
        taskId: task.id,
        status: status,
        createdAt: task.createdAt,
        updatedAt: now,
      ).status,
      workState: resolved.toWorkState(task.id),
      summary: _runtimeSummaryForTask(task),
      now: now,
    );
  }

  Future<void> _bridgeEnsureTaskCreated(TaskSession task) async {
    if (_bridgedTaskIds.contains(task.id)) {
      return;
    }
    final inFlight = _bridgeCreateFutures[task.id];
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _bridgeCreateTaskIfMissing(task);
    _bridgeCreateFutures[task.id] = future;
    try {
      await future;
    } finally {
      _bridgeCreateFutures.remove(task.id);
    }
  }

  Future<void> _bridgeCreateTaskIfMissing(TaskSession task) async {
    final existing = await bridgeRuntime.taskSnapshot(task.id);
    if (existing != null) {
      _bridgedTaskIds.add(task.id);
      return;
    }
    final existingWorkState = bridgeRuntime.workState(task.id);
    final projectedStatus = existingWorkState == null
        ? _projectedTaskStatus(task)
        : _taskStatusFromWorkState(existingWorkState, task);
    final resolved = resolveRuntimeState(
      task,
      taskStatus: projectedStatus,
      workState: existingWorkState,
    );
    await bridgeRuntime.createTask(
      RuntimeTaskSnapshot(
        taskId: task.id,
        status: RuntimeTaskSnapshot.fromTaskStatus(
          taskId: task.id,
          status: projectedStatus,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
        ).status,
        createdAt: task.createdAt,
        updatedAt: task.updatedAt,
        summary: _runtimeSummaryForTask(task),
        workState: resolved.toWorkState(task.id),
      ),
    );
    _bridgedTaskIds.add(task.id);
  }

  String _runtimeSummaryForTask(TaskSession task) {
    final approvalQuestion = _nativeApprovalForTask(task)?.question.trim();
    if (approvalQuestion != null && approvalQuestion.isNotEmpty) {
      return approvalQuestion;
    }
    for (final turn in task.turns.reversed) {
      final summary = turn.deliverable?.displaySummary.trim();
      if (summary != null && summary.isNotEmpty) {
        return summary;
      }
    }
    return '';
  }

  void _notifyRuntimeOutput(String taskId, String rawOutput) {
    final trimmed = rawOutput.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    final hash = trimmed.hashCode;
    final lastAt = _lastRuntimeOutputNotifiedAt[taskId];
    if (_lastRuntimeOutputHashes[taskId] == hash ||
        (lastAt != null &&
            now.difference(lastAt) < _runtimeOutputNotifyInterval)) {
      return;
    }
    _lastRuntimeOutputHashes[taskId] = hash;
    _lastRuntimeOutputNotifiedAt[taskId] = now;
    bridgeRuntime.notifyOutputUpdated(taskId, now: now);
  }

  void _runtimeDiag(String message) {
    if (!_appDiagnosticsEnabled) {
      return;
    }
    debugPrint('ARMIN_DIAG: $message');
  }

  Future<void> _publishDeliverableIfAvailable(TaskSession task) async {
    final candidate = _deliverableSource.latestCandidate(task.turns);
    if (candidate == null) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} reason=no_candidate '
        'status=${_taskStatus(task).name} turns=${task.turns.length} '
        'lastTurn=${task.turns.lastOrNull?.status.name ?? 'none'}',
      );
      return;
    }
    final evidence = _deliverableSource.evidenceFor(task.turns, candidate);
    if (evidence == null) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} '
        'reason=no_evidence turn=${candidate.turn.id}',
      );
      return;
    }
    final publishKey = '${task.id}:${candidate.turn.id}';
    if (candidate.turn.deliverable?.evidenceFingerprint ==
            evidence.fingerprint ||
        _publishedDeliverableFingerprints[publishKey] == evidence.fingerprint) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} '
        'reason=duplicate fingerprint=${evidence.fingerprint}',
      );
      return;
    }
    _runtimeDiag(
      'DELIVERABLE_RESOLVE task=${task.id} '
      'turn=${candidate.turn.id} evidence=${evidence.text.length} '
      'fingerprint=${evidence.fingerprint}',
    );
    final resolved = await _deliverableSource.resolve(
      task.turns,
      candidate,
      provider: outputSummaryProvider,
      context: DeliverableResolveContext(
        status: _taskStatus(task),
        taskTitle: task.title,
        agentCommand: task.host.agentCommand,
      ),
    );
    if (resolved == null) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} reason=resolve_null',
      );
      return;
    }
    final latest = _latestTask(task.id);
    final latestCandidate = latest == null
        ? null
        : _deliverableSource.latestCandidate(latest.turns);
    final latestEvidence = latestCandidate == null
        ? null
        : _deliverableSource.evidenceFor(latest!.turns, latestCandidate);
    if (latestCandidate?.turn.id != candidate.turn.id) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} '
        'reason=candidate_changed latest=${latestCandidate?.turn.id ?? 'none'} '
        'expected=${candidate.turn.id}',
      );
      return;
    }
    if (latestEvidence?.fingerprint != evidence.fingerprint) {
      _runtimeDiag(
        'DELIVERABLE_SKIP task=${task.id} '
        'reason=fingerprint_changed latest=${latestEvidence?.fingerprint ?? 'none'} '
        'expected=${evidence.fingerprint}',
      );
      return;
    }
    await _saveResolvedTurnDeliverable(
      latest!,
      turnId: resolved.provenance.turnId,
      deliverable: TurnDeliverable(
        displaySummary: resolved.displaySummary,
        speechSummary: resolved.speechSummary,
        evidenceFingerprint: resolved.provenance.evidenceFingerprint,
      ),
    );
    final syncedLatest = _latestTask(task.id) ?? latest;
    await _enqueueRuntimeSync(syncedLatest);
    _queueFreshDeliverableSpeech(
      syncedLatest,
      turnId: resolved.provenance.turnId,
      evidenceFingerprint: resolved.provenance.evidenceFingerprint,
    );
    _publishedDeliverableFingerprints[publishKey] = evidence.fingerprint;
    _runtimeDiag(
      'DELIVERABLE_SAVED task=${task.id} '
      'turn=${resolved.provenance.turnId} '
      'summary=${resolved.displaySummary.length}',
    );
    _queueAggressiveAutopilot(syncedLatest);
    await bridgeRuntime.notifyDeliverableUpdated(
      task.id,
      deliverableSummary: resolved.displaySummary,
      turnId: resolved.provenance.turnId,
      evidenceFingerprint: resolved.provenance.evidenceFingerprint,
    );
  }

  Future<void> _saveResolvedTurnDeliverable(
    TaskSession task, {
    required String turnId,
    required TurnDeliverable deliverable,
  }) async {
    final latest = _latestTask(task.id) ?? task;
    final turns = List<NativeOutputTurn>.of(latest.turns);
    final index = turns.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return;
    final now = DateTime.now();
    turns[index] = turns[index].copyWith(deliverable: deliverable);
    final evaluated = latest.copyWith(turns: turns, updatedAt: now);
    final withEvaluation = evaluated.copyWith(
      metricEvents: _metricEventsWithCreated(
        evaluated.metricEvents,
        taskId: evaluated.id,
        eventType: LoopEvaluation.metricEventType,
        payloadJson: jsonEncode(
          _loopEvaluationForTurn(
            evaluated,
            turns[index],
            now: now,
          ).toJson(),
        ),
        now: now,
      ),
    );
    final updated = withEvaluation.copyWith(
      metricEvents: _metricEventsWithCreated(
        withEvaluation.metricEvents,
        taskId: withEvaluation.id,
        eventType: LoopResultSummary.metricEventType,
        payloadJson: jsonEncode(
          _loopResultSummaryForTask(
            withEvaluation,
            now: now,
          ).toJson(),
        ),
        now: now,
      ),
    );
    await _store.saveTask(updated);
    final updatedTasks = [...tasks]
      ..removeWhere((item) => item.id == latest.id);
    tasks = [updated, ...updatedTasks];
    _updateTaskSnapshot(updated);
    _updateHomeSnapshot();
  }

  LoopEvaluation _loopEvaluationForTurn(
    TaskSession task,
    NativeOutputTurn turn, {
    required DateTime now,
  }) {
    final deliverable = turn.deliverable;
    final duration = turn.lastOutputAt.difference(turn.startedAt);
    return LoopEvaluation(
      id: 'loop-${turn.id}-${now.microsecondsSinceEpoch}',
      taskId: task.id,
      turnId: turn.id,
      turnIndex: turn.turnIndex,
      status: _projectedTaskStatus(task).name,
      createdAt: now,
      metrics: LoopTurnMetrics(
        inputLength: turn.userInput.trim().length,
        outputSummaryLength: deliverable?.displaySummary.trim().length ?? 0,
        approvalCount: _approvalCountForTurn(task, turn),
        retryCount: _retryCountForTurn(task, turn),
        waitMs: duration.isNegative ? 0 : duration.inMilliseconds,
        hasDeliverable: deliverable != null,
      ),
    );
  }

  LoopResultSummary _loopResultSummaryForTask(
    TaskSession task, {
    required DateTime now,
  }) {
    final resultTurns = task.turns
        .where((turn) => turn.deliverable != null)
        .toList(growable: false);
    final latestTurn = resultTurns.lastOrNull;
    final latestDeliverable = latestTurn?.deliverable;
    final userActions = _loopUserActionsFor(task);
    return LoopResultSummary(
      id: 'loop-result-${task.id}-${now.microsecondsSinceEpoch}',
      taskId: task.id,
      createdAt: now,
      latestTurnId: latestTurn?.id ?? '',
      latestTurnIndex: latestTurn?.turnIndex ?? 0,
      latestEvidenceFingerprint: latestDeliverable?.evidenceFingerprint ?? '',
      resultCount: resultTurns.length,
      acceptedCount: userActions
          .where((action) => action.kind == LoopUserActionKind.acceptResult)
          .length,
      redoCount: userActions
          .where((action) => action.kind == LoopUserActionKind.rejectOrRedo)
          .length,
      completedCount: userActions
          .where((action) => action.kind == LoopUserActionKind.markCompleted)
          .length,
      failedCount: userActions
          .where((action) => action.kind == LoopUserActionKind.markFailed)
          .length,
      summaryText: _loopResultSummaryText(resultTurns),
      results: [
        for (final turn in resultTurns)
          LoopResultReference(
            turnId: turn.id,
            turnIndex: turn.turnIndex,
            summaryLength: turn.deliverable!.displaySummary.trim().length,
            evidenceFingerprint: turn.deliverable!.evidenceFingerprint,
          ),
      ],
    );
  }

  List<LoopUserAction> _loopUserActionsFor(TaskSession task) {
    final actions = <LoopUserAction>[];
    for (final event in task.metricEvents) {
      if (event.eventType != LoopUserAction.metricEventType) {
        continue;
      }
      try {
        final decoded = jsonDecode(event.payloadJson);
        if (decoded is Map<String, Object?>) {
          actions.add(LoopUserAction.fromJson(decoded));
        }
      } catch (_) {}
    }
    return actions;
  }

  String _loopResultSummaryText(List<NativeOutputTurn> resultTurns) {
    if (resultTurns.isEmpty) {
      return '';
    }
    final latestTurn = resultTurns.last;
    final latestSummary = _summaryExcerpt(
      latestTurn.deliverable!.displaySummary,
      maxChars: 180,
    );
    if (resultTurns.length == 1) {
      return 'Turn ${latestTurn.turnIndex}: $latestSummary';
    }
    return '共 ${resultTurns.length} 轮正式结果，最新 Turn ${latestTurn.turnIndex}: $latestSummary';
  }

  String _summaryExcerpt(String value, {required int maxChars}) {
    final singleLine = value
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    if (singleLine.length <= maxChars) {
      return singleLine;
    }
    return '${singleLine.substring(0, maxChars)}...';
  }

  NativeOutputTurn? _turnBeforeLast(TaskSession task) {
    if (task.turns.length < 2) {
      return task.turns.lastOrNull;
    }
    return task.turns[task.turns.length - 2];
  }

  int _approvalCountForTurn(TaskSession task, NativeOutputTurn turn) {
    final startedAt = turn.startedAt;
    final endedAt = turn.idleDetectedAt ?? turn.lastOutputAt;
    return task.nativeApprovalRequests.where((approval) {
      return !approval.createdAt.isBefore(startedAt) &&
          !approval.createdAt.isAfter(endedAt);
    }).length;
  }

  int _retryCountForTurn(TaskSession task, NativeOutputTurn turn) {
    final retryEvents = task.metricEvents.where((event) {
      return event.eventType.toLowerCase().contains('retry') &&
          event.createdAt.isAfter(turn.startedAt);
    });
    return retryEvents.length;
  }

  TaskSession? _latestTask(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  Future<List<TaskSession>> _loadDedupedTasks() async {
    final loaded = await _store.loadTasks();
    return _dedupeTasks(loaded);
  }

  List<TaskSession> _dedupeTasks(Iterable<TaskSession> source) {
    final seen = <String>{};
    return [
      for (final task in source)
        if (seen.add(task.id)) task,
    ];
  }

  /// Returns true if processing [update] would change the task's status.
  bool _updateWouldChangeStatus(TaskSession task, AgentExecutionUpdate update) {
    if (update.nativeApproval != null) return true;
    if (update.needsAttention) return true;
    if (update.turnIdle || update.done) return true;
    if (update.runtimeLost) return true;
    return false;
  }

  void _syncTaskSnapshots({String? taskId}) {
    if (taskId != null) {
      final snapshot = _taskSnapshots[taskId];
      if (snapshot != null) {
        final latest = _latestTask(taskId);
        if (snapshot.value != latest) {
          snapshot.value = latest;
        }
      }
    } else {
      for (final snapshot in _taskSnapshots.entries) {
        final latest = _latestTask(snapshot.key);
        if (snapshot.value.value != latest) {
          snapshot.value.value = latest;
        }
      }
    }
  }

  void _updateTaskSnapshot(TaskSession task) {
    final snapshot = _taskSnapshots[task.id];
    if (snapshot != null && snapshot.value != task) {
      snapshot.value = task;
    }
  }

  void _updateTaskSnapshotById(String taskId) {
    final snapshot = _taskSnapshots[taskId];
    if (snapshot != null) {
      snapshot.value = _latestTask(taskId);
    }
  }

  void _updateHomeSnapshot({bool force = false}) {
    final signature = _homeSignatureFor(tasks, ready: ready);
    if (!force && signature == _homeSnapshotSignature) {
      return;
    }
    _homeSnapshotSignature = signature;
    homeSnapshot.value = HomeTaskSnapshot(
      ready: ready,
      tasks: List<TaskSession>.unmodifiable(tasks),
    );
  }

  String _homeSignatureFor(List<TaskSession> tasks, {required bool ready}) {
    final parts = <String>['ready:$ready', 'count:${tasks.length}'];
    for (final task in tasks) {
      parts.add(_homeTaskSignature(task));
    }
    return parts.join('|');
  }

  String _homeTaskSignature(TaskSession task) {
    final status = _taskStatus(task);
    final includeUpdatedAt = status != TaskStatus.running &&
        status != TaskStatus.pending &&
        status != TaskStatus.draft;
    return [
      task.id,
      task.title,
      task.userText,
      status.name,
      task.nativeApproval?.question ?? '',
      _runtimeSummaryForTask(task).hashCode.toString(),
      task.completedAt?.microsecondsSinceEpoch.toString() ?? '',
      if (includeUpdatedAt) task.updatedAt.microsecondsSinceEpoch.toString(),
    ].join('~');
  }

  TaskSession _taskWithExecutionUpdate(
    TaskSession task,
    AgentExecutionUpdate update, {
    bool reopenResolvedApproval = false,
  }) {
    final updateAt = DateTime.now();
    final outputForSummary = update.cleanedOutput?.trim().isNotEmpty == true
        ? update.cleanedOutput!
        : update.rawOutput;
    final summary = const AgentOutputCleaner().clean(outputForSummary).trim();
    final suppressEmptyAutoIdle = (update.turnIdle || update.done) &&
        !update.needsAttention &&
        !update.runtimeLost &&
        update.nativeApproval == null &&
        summary.isEmpty;
    final taskWithTurn = _taskWithTurnOutput(
      task,
      rawOutput: '',
      cleanedOutput: outputForSummary,
      now: updateAt,
      status: _turnStatusForUpdate(
        update,
        allowAutomaticTurnIdle: !suppressEmptyAutoIdle,
      ),
      idleDetectedAt: (update.turnIdle || update.done) && !suppressEmptyAutoIdle
          ? updateAt
          : null,
    );

    final nativeApproval = update.nativeApproval;

    if (nativeApproval != null) {
      final approval = nativeApproval.taskId.trim().isEmpty
          ? nativeApproval.copyWith(taskId: task.id)
          : nativeApproval;
      final alreadyResolved = taskWithTurn.nativeApprovalRequests.any(
        (entry) =>
            entry.question == approval.question &&
            entry.state != ApprovalState.pending,
      );
      if (alreadyResolved && !reopenResolvedApproval) {
        return taskWithTurn.copyWith(
          updatedAt: updateAt,
          clearNativeApproval: true,
        );
      }
      final approvalEvents = _metricEventsWithCreated(
        taskWithTurn.metricEvents,
        taskId: task.id,
        eventType: 'approval_requested',
        payloadJson: '{"options":${approval.options.length}}',
        now: updateAt,
      );
      return _taskWithApprovalEvent(
        _projectTaskStatus(
          taskWithTurn,
          status: TaskStatus.needApproval,
          now: updateAt,
        ).copyWith(
          nativeApproval: approval,
          nativeApprovalRequests: reopenResolvedApproval
              ? _nativeApprovalRequestsWithReopenedApproval(
                  taskWithTurn.nativeApprovalRequests,
                  approval,
                )
              : [
                  ...taskWithTurn.nativeApprovalRequests,
                  approval,
                ],
          metricEvents: approvalEvents,
        ),
        approval: approval,
        kind: LoopApprovalEventKind.requested,
        status: TaskStatus.needApproval,
        now: updateAt,
      );
    }

    if (update.runtimeLost) {
      final failedAt = DateTime.now();
      return _projectTaskStatus(
        taskWithTurn,
        status: TaskStatus.runtimeLost,
        now: failedAt,
        clearNativeApproval: true,
      ).copyWith(
        metricEvents: _metricEventsWithCreated(
          taskWithTurn.metricEvents,
          taskId: task.id,
          eventType: 'runtime_lost',
          payloadJson: '{"observer_state":"${update.observerState.name}"}',
          now: failedAt,
        ),
      );
    }

    if (update.turnIdle || update.done) {
      if (suppressEmptyAutoIdle) {
        return taskWithTurn.copyWith(
          updatedAt: updateAt,
          metricEvents: _metricEventsWithCreated(
            taskWithTurn.metricEvents,
            taskId: task.id,
            eventType: 'empty_turn_idle_suppressed',
            payloadJson: '{"observer_state":"${update.observerState.name}"}',
            now: updateAt,
          ),
        );
      }
      final idleAt = DateTime.now();
      return _projectTaskStatus(
        taskWithTurn,
        status: update.needsAttention
            ? TaskStatus.needAttention
            : TaskStatus.turnIdle,
        now: idleAt,
        clearNativeApproval: !update.needsAttention,
      ).copyWith(
        metricEvents: _metricEventsWithCreated(
          taskWithTurn.metricEvents,
          taskId: task.id,
          eventType: update.needsAttention ? 'need_attention' : 'turn_idle',
          payloadJson: '{"observer_state":"${update.observerState.name}"}',
          now: idleAt,
        ),
      );
    }

    if (update.needsAttention) {
      final attentionAt = DateTime.now();
      return _projectTaskStatus(
        taskWithTurn,
        status: TaskStatus.needAttention,
        now: attentionAt,
      ).copyWith(
        metricEvents: _metricEventsWithCreated(
          taskWithTurn.metricEvents,
          taskId: task.id,
          eventType: 'need_attention',
          payloadJson: '{"source":"observer"}',
          now: attentionAt,
        ),
      );
    }

    final hasLogOutput = update.rawOutput.trim().isNotEmpty;
    return taskWithTurn.copyWith(
      updatedAt: updateAt,
      metricEvents: hasLogOutput
          ? _metricEventsWithCreated(
              taskWithTurn.metricEvents,
              taskId: task.id,
              eventType: 'log_update',
              payloadJson: '{"bytes":${update.rawOutput.length}}',
              now: updateAt,
            )
          : taskWithTurn.metricEvents,
    );
  }

  List<MetricEvent> _metricEventsWithCreated(
    List<MetricEvent> events, {
    required String taskId,
    required String eventType,
    required String payloadJson,
    required DateTime now,
  }) {
    final event = MetricEvent.createIfUseful(
      taskId: taskId,
      eventType: eventType,
      payloadJson: payloadJson,
      now: now,
    );
    if (event == null) {
      return events;
    }
    return MetricEvent.appendControlled(events, event);
  }

  TaskSession _taskWithNewTurn(
    TaskSession task, {
    required String userInput,
    required DateTime now,
  }) {
    final baseTask = task.turns.isEmpty
        ? _taskWithInitialTurn(
            task,
            userInput: task.userText.isEmpty ? task.title : task.userText,
            now: task.startedAt ?? task.createdAt,
          )
        : task;
    final turnIndex = baseTask.turns.last.turnIndex + 1;
    final redactedInput = _secretRedactor.redactInlineSecrets(userInput);
    final nextTurn = NativeOutputTurn(
      id: 'turn-${baseTask.id}-$turnIndex',
      taskId: baseTask.id,
      turnIndex: turnIndex,
      userInput: redactedInput,
      rawOutput: '',
      cleanedOutput: '',
      startedAt: now,
      lastOutputAt: now,
      status: NativeOutputTurnStatus.running,
    );
    return baseTask.copyWith(turns: [...baseTask.turns, nextTurn]);
  }

  TaskSession _taskAfterFailedFollowUpSend(
    TaskSession task, {
    required TaskSession previous,
    required TaskStatus previousStatus,
    required String? unsentTurnId,
    required Object error,
  }) {
    final turns = List<NativeOutputTurn>.of(task.turns);
    final latestTurn = turns.lastOrNull;
    final canRemoveUnsentTurn = latestTurn != null &&
        latestTurn.id == unsentTurnId &&
        latestTurn.rawOutput.trim().isEmpty &&
        latestTurn.cleanedOutput.trim().isEmpty &&
        latestTurn.deliverable == null;
    if (canRemoveUnsentTurn) {
      turns.removeLast();
    }
    return _projectTaskStatus(
      task.copyWith(turns: canRemoveUnsentTurn ? turns : task.turns),
      status:
          canRemoveUnsentTurn ? previousStatus : TaskStatus.observerDetached,
      now: DateTime.now(),
      clearNativeApproval: canRemoveUnsentTurn,
    );
  }

  TaskSession _withVoiceInput(
    TaskSession task,
    String rawVoiceText,
    DateTime createdAt,
  ) {
    final redactedText =
        _secretRedactor.redactInlineSecrets(rawVoiceText.trim());
    if (redactedText.isEmpty) {
      return task;
    }
    return task.copyWith(
      voiceInputs: [
        ...task.voiceInputs,
        VoiceInput(
          id: 'voice-${task.id}-${createdAt.microsecondsSinceEpoch}',
          taskId: task.id,
          rawSttText: redactedText,
          language: 'zh-CN',
          createdAt: createdAt,
        ),
      ],
    );
  }

  TaskSession _taskWithInitialTurn(
    TaskSession task, {
    required String userInput,
    required DateTime now,
  }) {
    if (task.turns.isNotEmpty) {
      return task;
    }
    final redactedInput = _secretRedactor.redactInlineSecrets(userInput);
    return task.copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-${task.id}-1',
          taskId: task.id,
          turnIndex: 1,
          userInput: redactedInput,
          rawOutput: '',
          cleanedOutput: '',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
  }

  TaskSession _taskWithTurnOutput(
    TaskSession task, {
    required String rawOutput,
    required String cleanedOutput,
    required DateTime now,
    NativeOutputTurnStatus? status,
    DateTime? idleDetectedAt,
  }) {
    final turns = task.turns.isEmpty
        ? _taskWithInitialTurn(
            task,
            userInput: task.userText.isEmpty ? task.title : task.userText,
            now: task.startedAt ?? task.createdAt,
          ).turns
        : task.turns;
    final updatedTurns = [...turns];
    final current = updatedTurns.last;
    updatedTurns[updatedTurns.length - 1] = current.copyWith(
      rawOutput: '${current.rawOutput}$rawOutput',
      cleanedOutput:
          cleanedOutput.trim().isEmpty ? current.cleanedOutput : cleanedOutput,
      lastOutputAt: now,
      idleDetectedAt: idleDetectedAt,
      status: status ?? current.status,
    );
    return task.copyWith(turns: updatedTurns);
  }

  TaskSession _taskWithCurrentTurnDecision(
    TaskSession task, {
    required NativeOutputTurnStatus status,
    required DateTime now,
    String? userDecision,
  }) {
    final taskWithTurn = task.turns.isEmpty
        ? _taskWithInitialTurn(
            task,
            userInput: task.userText.isEmpty ? task.title : task.userText,
            now: task.startedAt ?? task.createdAt,
          )
        : task;
    final turns = [...taskWithTurn.turns];
    final current = turns.last;
    turns[turns.length - 1] = current.copyWith(
      status: status,
      lastOutputAt: now,
      userDecision: userDecision,
    );
    return taskWithTurn.copyWith(turns: turns);
  }

  NativeOutputTurnStatus? _turnStatusForUpdate(
    AgentExecutionUpdate update, {
    bool allowAutomaticTurnIdle = true,
  }) {
    if (update.runtimeLost) {
      return NativeOutputTurnStatus.runtimeLost;
    }
    if (update.nativeApproval != null || update.needsAttention) {
      return NativeOutputTurnStatus.needAttention;
    }
    if ((update.turnIdle || update.done) && allowAutomaticTurnIdle) {
      return NativeOutputTurnStatus.turnIdle;
    }
    return null;
  }

  NativeTerminalApproval? _nativeApprovalForTask(TaskSession task) {
    if (task.nativeApproval?.state == ApprovalState.pending) {
      return task.nativeApproval;
    }
    final runtimeApproval = bridgeRuntime.workState(task.id)?.approval;
    if (runtimeApproval?.state == ApprovalState.pending) {
      return runtimeApproval;
    }
    for (final approval in task.nativeApprovalRequests.reversed) {
      if (approval.state == ApprovalState.pending) {
        return approval;
      }
    }
    return null;
  }

  NativeTerminalApproval? _nativeApprovalFromTerminalPrompt(
    TerminalPrompt? terminalPrompt,
    String taskId,
    DateTime now,
  ) {
    final question = terminalPrompt?.question.trim() ?? '';
    if (question.isEmpty) {
      return null;
    }
    return NativeTerminalApproval(
      id: 'approval-${question.hashCode}',
      taskId: taskId,
      question: question,
      options: terminalPrompt!.options
          .map(
            (option) => NativeApprovalOption(
              key: option.key,
              label: option.label,
            ),
          )
          .toList(growable: false),
      state: ApprovalState.pending,
      createdAt: now,
    );
  }

  List<NativeTerminalApproval> _nativeApprovalRequestsWithReopenedApproval(
    List<NativeTerminalApproval> existing,
    NativeTerminalApproval approval,
  ) {
    var reopened = false;
    final updated = existing.map((entry) {
      if (entry.question == approval.question) {
        reopened = true;
        return approval.copyWith(state: ApprovalState.pending);
      }
      return entry;
    }).toList();
    if (!reopened) {
      updated.add(approval);
    }
    return updated;
  }

  Future<TaskSession> _saveFailedExecution(
      TaskSession task, Object error) async {
    final failedAt = DateTime.now();
    final taskWithFailedTurn = _taskWithCurrentTurnDecision(
      task,
      status: NativeOutputTurnStatus.failed,
      userDecision: 'failed',
      now: failedAt,
    );
    final failedTask = _projectTaskStatus(
      taskWithFailedTurn,
      status: TaskStatus.failed,
      now: failedAt,
      clearNativeApproval: true,
    ).copyWith(
      metricEvents: _metricEventsWithCreated(
        taskWithFailedTurn.metricEvents,
        taskId: task.id,
        eventType: 'task_failed',
        payloadJson: '{"reason":"ssh_execution_error"}',
        now: failedAt,
      ),
    );
    await saveTask(failedTask);
    return failedTask;
  }

  Future<TaskSession> _saveObserverDisconnected(
    TaskSession task,
    Object error,
  ) async {
    final now = DateTime.now();
    final detachedTask = _projectTaskStatus(
      task,
      status: TaskStatus.observerDetached,
      now: now,
      clearNativeApproval: true,
    ).copyWith(
      metricEvents: _metricEventsWithCreated(
        task.metricEvents,
        taskId: task.id,
        eventType: 'observer_connection_lost',
        payloadJson: '{"status":"observerDetached"}',
        now: now,
      ),
    );
    await saveTask(detachedTask);
    bridgeRuntime.notifyObserverDetached(task.id, now: now);
    return detachedTask;
  }

  bool _isRecoverableObserverError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('socket exception') ||
        text.contains('connection abort') ||
        text.contains('connection reset') ||
        text.contains('connection timed out') ||
        text.contains('broken pipe') ||
        text.contains('connection closed');
  }

  /// Sets the task whose detail page is currently visible, so that
  /// auto-speech only plays when the user is viewing that task.
  void setActiveDetailTaskId(String taskId) {
    _activeDetailTaskId = taskId;
  }

  /// Clears the active detail task id, e.g. when the user navigates away.
  void clearActiveDetailTaskId() {
    _activeDetailTaskId = null;
  }

  Future<void> _speakTaskUpdate(
    TaskSession previous,
    TaskSession current,
  ) async {
    final decision = await _taskSpeechPolicy.decide(
      previous: previous,
      current: current,
      currentStatus: _taskStatus(current),
      settings: speechSettings,
      approval: bridgeRuntime.workState(current.id)?.approval,
    );
    if (!decision.shouldSpeak ||
        _lastSpokenHashes[current.id] == decision.hash ||
        _activeDetailTaskId != current.id) {
      return;
    }
    _lastSpokenHashes[current.id] = decision.hash;
    try {
      await voiceService.speakSummary(decision.text);
    } catch (error) {
      debugPrint('Task speech failed: $error');
    }
  }

  void _queueTaskSpeech(TaskSession previous, TaskSession current) {
    _speechQueue = _speechQueue
        .then((_) => _speakTaskUpdate(previous, current))
        .catchError((Object error) {
      debugPrint('Task speech queue failed: $error');
    });
  }

  void _markExistingDeliverablesSeen(Iterable<TaskSession> source) {
    for (final task in source) {
      for (final turn in task.turns) {
        final deliverable = turn.deliverable;
        if (deliverable == null) {
          continue;
        }
        final key = _deliverableSpeechKey(
          taskId: task.id,
          turnId: turn.id,
          evidenceFingerprint: deliverable.evidenceFingerprint,
        );
        if (key.isNotEmpty) {
          _seenDeliverableSpeechKeys.add(key);
        }
      }
    }
  }

  void _markExistingDeliverableNotificationsSeen(Iterable<TaskSession> source) {
    for (final task in source) {
      for (final turn in task.turns) {
        final deliverable = turn.deliverable;
        if (deliverable == null) {
          continue;
        }
        final key = _taskNotificationKey(
          taskId: task.id,
          kind: TaskNotificationKind.resultReady,
          turnId: turn.id,
          evidenceFingerprint: deliverable.evidenceFingerprint,
        );
        _seenTaskNotificationKeys.add(key);
      }
    }
  }

  String _deliverableSpeechKey({
    required String taskId,
    required String? turnId,
    required String? evidenceFingerprint,
  }) {
    final normalizedTurnId = turnId?.trim() ?? '';
    final normalizedFingerprint = evidenceFingerprint?.trim() ?? '';
    if (taskId.trim().isEmpty ||
        normalizedTurnId.isEmpty ||
        normalizedFingerprint.isEmpty) {
      return '';
    }
    return '$taskId:$normalizedTurnId:$normalizedFingerprint';
  }

  void _queueFreshDeliverableSpeech(
    TaskSession task, {
    required String? turnId,
    required String? evidenceFingerprint,
  }) {
    final key = _deliverableSpeechKey(
      taskId: task.id,
      turnId: turnId,
      evidenceFingerprint: evidenceFingerprint,
    );
    if (key.isEmpty || _seenDeliverableSpeechKeys.contains(key)) {
      return;
    }
    _seenDeliverableSpeechKeys.add(key);
    _speechQueue = _speechQueue.then((_) async {
      if (_activeDetailTaskId != task.id) {
        return;
      }
      final decision = await _taskSpeechPolicy.decide(
        previous: task,
        current: task,
        currentStatus: _taskStatus(task),
        settings: speechSettings,
        approval: bridgeRuntime.workState(task.id)?.approval,
      );
      if (!decision.shouldSpeak) {
        return;
      }
      if (_lastSpokenHashes[task.id] == decision.hash) {
        return;
      }
      _lastSpokenHashes[task.id] = decision.hash;
      await voiceService.speakSummary(decision.text);
    }).catchError((Object error) {
      debugPrint('Fresh deliverable speech failed: $error');
    });
  }

  /// Listens to EventBus for fresh deliverable events. Existing/persisted
  /// results are marked as seen during load so opening a task never replays
  /// old output.
  void _onSpeechEvent(RuntimeEvent event) {
    final isSpeechRelevant = switch (event.type) {
      RuntimeEventType.approvalRequested ||
      RuntimeEventType.deliverableUpdated =>
        true,
      _ => false,
    };
    if (!isSpeechRelevant) return;
    final task = _latestTask(event.taskId);
    if (task == null) return;
    if (event.type == RuntimeEventType.deliverableUpdated) {
      _queueFreshDeliverableSpeech(
        task,
        turnId: event.turnId,
        evidenceFingerprint: event.evidenceFingerprint,
      );
      return;
    }
    // Approval events use the task itself; the speech policy reads the current
    // WorkState approval payload for the spoken prompt.
    _queueTaskSpeech(task, task);
  }

  void _onNotificationEvent(RuntimeEvent event) {
    final task = _latestTask(event.taskId);
    if (task == null) return;
    final notification = _notificationForRuntimeEvent(event, task);
    if (notification == null) return;
    final key = _taskNotificationKey(
      taskId: notification.taskId,
      kind: notification.kind,
      turnId: notification.turnId,
      evidenceFingerprint: notification.evidenceFingerprint,
    );
    if (!_seenTaskNotificationKeys.add(key)) {
      return;
    }
    _notificationQueue = _notificationQueue.then((_) {
      return taskNotificationService.show(notification);
    }).catchError((Object error) {
      debugPrint('Task notification failed: $error');
    });
  }

  TaskNotification? _notificationForRuntimeEvent(
    RuntimeEvent event,
    TaskSession task,
  ) {
    final createdAt = event.createdAt;
    return switch (event.type) {
      RuntimeEventType.approvalRequested =>
        _approvalNotification(task, createdAt),
      RuntimeEventType.deliverableUpdated =>
        _resultReadyNotification(event, task, createdAt),
      RuntimeEventType.taskWaitingUser ||
      RuntimeEventType.waitingForInstruction =>
        _needsInstructionNotification(task, createdAt),
      RuntimeEventType.connectionLost => _runtimeLostNotification(
          task,
          createdAt,
        ),
      RuntimeEventType.taskPaused
          when _taskStatus(task) == TaskStatus.runtimeLost =>
        _runtimeLostNotification(task, createdAt),
      RuntimeEventType.taskCompleted => _terminalNotification(
          task,
          kind: TaskNotificationKind.taskCompleted,
          title: '任务已完成',
          createdAt: createdAt,
        ),
      RuntimeEventType.taskFailed => _terminalNotification(
          task,
          kind: TaskNotificationKind.taskFailed,
          title: '任务失败',
          createdAt: createdAt,
        ),
      _ => null,
    };
  }

  TaskNotification? _approvalNotification(
    TaskSession task,
    DateTime createdAt,
  ) {
    final approval = _nativeApprovalForTask(task);
    if (approval == null) return null;
    return TaskNotification(
      id: _taskNotificationId(
        taskId: task.id,
        kind: TaskNotificationKind.approvalRequired,
        turnId: task.turns.lastOrNull?.id,
        evidenceFingerprint: approval.id,
      ),
      taskId: task.id,
      kind: TaskNotificationKind.approvalRequired,
      title: '需要审批',
      body: _notificationBody(approval.question),
      createdAt: createdAt,
      turnId: task.turns.lastOrNull?.id,
      evidenceFingerprint: approval.id,
    );
  }

  TaskNotification? _resultReadyNotification(
    RuntimeEvent event,
    TaskSession task,
    DateTime createdAt,
  ) {
    final turn = task.turns.where((item) => item.id == event.turnId).lastOrNull;
    final deliverable = turn?.deliverable;
    final fingerprint = event.evidenceFingerprint?.trim() ?? '';
    if (turn == null ||
        deliverable == null ||
        fingerprint.isEmpty ||
        deliverable.evidenceFingerprint != fingerprint) {
      return null;
    }
    return TaskNotification(
      id: _taskNotificationId(
        taskId: task.id,
        kind: TaskNotificationKind.resultReady,
        turnId: turn.id,
        evidenceFingerprint: fingerprint,
      ),
      taskId: task.id,
      kind: TaskNotificationKind.resultReady,
      title: '结果已准备好',
      body: _notificationBody(deliverable.displaySummary),
      createdAt: createdAt,
      turnId: turn.id,
      evidenceFingerprint: fingerprint,
    );
  }

  TaskNotification? _needsInstructionNotification(
    TaskSession task,
    DateTime createdAt,
  ) {
    final status = _taskStatus(task);
    if (status == TaskStatus.needApproval) return null;
    if (status != TaskStatus.needAttention && status != TaskStatus.turnIdle) {
      return null;
    }
    final latestTurn = task.turns.lastOrNull;
    if (latestTurn?.deliverable != null) {
      return null;
    }
    return TaskNotification(
      id: _taskNotificationId(
        taskId: task.id,
        kind: TaskNotificationKind.needsInstruction,
        turnId: latestTurn?.id,
        evidenceFingerprint: status.name,
      ),
      taskId: task.id,
      kind: TaskNotificationKind.needsInstruction,
      title: '等待你的指示',
      body: _notificationBody(_runtimeSummaryForTask(task)),
      createdAt: createdAt,
      turnId: latestTurn?.id,
      evidenceFingerprint: status.name,
    );
  }

  TaskNotification? _runtimeLostNotification(
    TaskSession task,
    DateTime createdAt,
  ) {
    if (_taskStatus(task) != TaskStatus.runtimeLost) return null;
    return _terminalNotification(
      task,
      kind: TaskNotificationKind.runtimeLost,
      title: '连接已暂停',
      createdAt: createdAt,
    );
  }

  TaskNotification _terminalNotification(
    TaskSession task, {
    required TaskNotificationKind kind,
    required String title,
    required DateTime createdAt,
  }) {
    final turnId = task.turns.lastOrNull?.id;
    final status = _taskStatus(task);
    return TaskNotification(
      id: _taskNotificationId(
        taskId: task.id,
        kind: kind,
        turnId: turnId,
        evidenceFingerprint: status.name,
      ),
      taskId: task.id,
      kind: kind,
      title: title,
      body: _notificationBody(_runtimeSummaryForTask(task)),
      createdAt: createdAt,
      turnId: turnId,
      evidenceFingerprint: status.name,
    );
  }

  String _taskNotificationKey({
    required String taskId,
    required TaskNotificationKind kind,
    String? turnId,
    String? evidenceFingerprint,
  }) {
    return _taskNotificationId(
      taskId: taskId,
      kind: kind,
      turnId: turnId,
      evidenceFingerprint: evidenceFingerprint,
    );
  }

  String _taskNotificationId({
    required String taskId,
    required TaskNotificationKind kind,
    String? turnId,
    String? evidenceFingerprint,
  }) {
    return [
      taskId.trim(),
      kind.name,
      turnId?.trim() ?? '',
      evidenceFingerprint?.trim() ?? '',
    ].join(':');
  }

  String _notificationBody(String text) {
    final cleaned = const AgentOutputCleaner().clean(text).trim();
    if (cleaned.isEmpty) {
      return '打开任务查看详情';
    }
    if (cleaned.length <= 80) {
      return cleaned;
    }
    return '${cleaned.substring(0, 80)}...';
  }

  bool _isTerminal(TaskStatus status) {
    return status == TaskStatus.stopped ||
        status == TaskStatus.runtimeLost ||
        status == TaskStatus.userCompleted ||
        status == TaskStatus.userFailed ||
        status == TaskStatus.completed ||
        status == TaskStatus.failed;
  }

  /// Public stream of runtime lifecycle events for UI-layer consumption.
  Stream<RuntimeEvent> get runtimeEvents => runtimeEventBus.events;

  /// Returns the current WorkState for a task.
  WorkState? workState(String taskId) => bridgeRuntime.workState(taskId);

  /// Returns runtime diagnostics for a task (debug only).
  RuntimeDiagnostics? runtimeDiagnostics(String taskId) =>
      bridgeRuntime.diagnostics(taskId);

  bool _canDeleteTask(TaskStatus status) {
    return switch (status) {
      TaskStatus.completed ||
      TaskStatus.failed ||
      TaskStatus.userCompleted ||
      TaskStatus.userFailed ||
      TaskStatus.stopped ||
      TaskStatus.runtimeLost =>
        true,
      _ => false,
    };
  }

  Future<void> _saveApprovalDecision(
    TaskSession task, {
    required bool approved,
  }) async {
    final now = DateTime.now();
    final resolvedTask = _taskWithApprovalDecision(task, approved: approved);
    final resolvedTaskWithFact = _taskWithApprovalEvent(
      resolvedTask,
      approval: task.nativeApproval,
      kind: approved
          ? LoopApprovalEventKind.approved
          : LoopApprovalEventKind.rejected,
      status: TaskStatus.running,
      selectedOptionKey: approved ? 'approve' : 'reject',
      now: now,
    );
    await saveTask(
      _projectTaskStatus(
        resolvedTaskWithFact,
        status: TaskStatus.running,
        now: now,
        clearNativeApproval: true,
      ),
    );
  }

  TaskSession _taskWithApprovalDecision(
    TaskSession task, {
    required bool approved,
    NativeTerminalApproval? nativeApproval,
    String? selectedOptionKey,
  }) {
    final now = DateTime.now();
    final pendingNativeApproval = nativeApproval ?? task.nativeApproval;
    final nativeSelectedOptionKey = selectedOptionKey ??
        (pendingNativeApproval == null
            ? (approved ? 'approve' : 'reject')
            : _nativeApprovalOptionKeyForDecision(
                pendingNativeApproval,
                approved,
              ));
    var resolvedExistingNativeApproval = false;
    final nativeApprovalRequests = task.nativeApprovalRequests.map((approval) {
      final matchesCurrentApproval = pendingNativeApproval != null &&
          _sameNativeApproval(approval, pendingNativeApproval);
      if (matchesCurrentApproval) {
        resolvedExistingNativeApproval = true;
        return approval.copyWith(
          state: ApprovalState.resolved,
          selectedOptionKey: nativeSelectedOptionKey,
          stateChangedAt: now,
        );
      }
      return approval;
    }).toList();
    if (pendingNativeApproval != null && !resolvedExistingNativeApproval) {
      nativeApprovalRequests.add(
        pendingNativeApproval.copyWith(
          state: ApprovalState.resolved,
          selectedOptionKey: nativeSelectedOptionKey,
          stateChangedAt: now,
        ),
      );
    }
    return task.copyWith(
      nativeApprovalRequests: nativeApprovalRequests,
      clearNativeApproval: true,
    );
  }

  TaskSession _taskWithTerminalOptionSelection(
    TaskSession task,
    NativeTerminalApproval nativeApproval,
    NativeApprovalOption option,
  ) {
    final now = DateTime.now();
    var resolvedExistingNativeApproval = false;
    final nativeApprovalRequests = task.nativeApprovalRequests.map((approval) {
      if (_sameNativeApproval(approval, nativeApproval)) {
        resolvedExistingNativeApproval = true;
        return approval.copyWith(
          state: ApprovalState.resolved,
          selectedOptionKey: option.key,
          stateChangedAt: now,
        );
      }
      return approval;
    }).toList();
    if (!resolvedExistingNativeApproval) {
      nativeApprovalRequests.add(
        nativeApproval.copyWith(
          state: ApprovalState.resolved,
          selectedOptionKey: option.key,
          stateChangedAt: now,
        ),
      );
    }
    return task.copyWith(
      nativeApprovalRequests: nativeApprovalRequests,
      clearNativeApproval: true,
    );
  }

  bool _sameNativeApproval(
    NativeTerminalApproval a,
    NativeTerminalApproval b,
  ) {
    if (a.id.isNotEmpty && b.id.isNotEmpty && a.id == b.id) {
      return true;
    }
    if (a.question.trim() != b.question.trim()) {
      return false;
    }
    final aOptionKeys = a.options.map((option) => option.key).toSet();
    final bOptionKeys = b.options.map((option) => option.key).toSet();
    return aOptionKeys.intersection(bOptionKeys).isNotEmpty;
  }

  DateTime? _completedAtFor(
    TaskStatus status,
    DateTime? currentCompletedAt,
    DateTime now,
  ) {
    return switch (status) {
      TaskStatus.completed ||
      TaskStatus.failed ||
      TaskStatus.runtimeLost ||
      TaskStatus.userCompleted ||
      TaskStatus.userFailed ||
      TaskStatus.stopped =>
        currentCompletedAt ?? now,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.running ||
      TaskStatus.paused ||
      TaskStatus.needApproval ||
      TaskStatus.turnIdle ||
      TaskStatus.needAttention ||
      TaskStatus.observerDetached =>
        currentCompletedAt,
    };
  }

  TaskSession _projectTaskStatus(
    TaskSession task, {
    required TaskStatus status,
    required DateTime now,
    bool clearNativeApproval = false,
    bool clearScheduledFor = false,
  }) {
    return task.copyWith(
      updatedAt: now,
      completedAt: _completedAtFor(status, task.completedAt, now),
      clearNativeApproval: clearNativeApproval,
      clearScheduledFor: clearScheduledFor,
    );
  }
}

class HomeTaskSnapshot {
  const HomeTaskSnapshot({
    required this.ready,
    required this.tasks,
  });

  factory HomeTaskSnapshot.empty() {
    return const HomeTaskSnapshot(ready: false, tasks: []);
  }

  final bool ready;
  final List<TaskSession> tasks;
}

class HostEditBlockedException implements Exception {
  const HostEditBlockedException(this.blockingTaskLabels);

  final List<String> blockingTaskLabels;

  String get message {
    if (blockingTaskLabels.isEmpty) {
      return '无法编辑主机配置。';
    }
    final names = blockingTaskLabels.join('、');
    return '以下任务正在使用此主机，请先将它们停止或完成：$names';
  }
}

class ProjectPathEditBlockedException implements Exception {
  const ProjectPathEditBlockedException(this.blockingTaskLabels);

  final List<String> blockingTaskLabels;

  String get message {
    if (blockingTaskLabels.isEmpty) {
      return '无法编辑项目目录。';
    }
    final names = blockingTaskLabels.join('、');
    return '以下任务正在使用此项目目录，请先将它们停止或完成：$names';
  }
}
