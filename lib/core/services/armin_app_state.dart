import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/parsers/task_result.dart';
import '../../features/agent/parsers/terminal_prompt.dart';
import '../../features/agent/services/ssh_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/tasks/models/execution_log.dart';
import '../../features/tasks/models/metric_event.dart';
import '../../features/tasks/models/native_output_turn.dart';
import '../../features/tasks/models/task_constraint.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/tasks/models/voice_input.dart';
import '../../features/tasks/services/output_summary_provider.dart';
import '../../features/tasks/services/secret_redactor.dart';
import '../../features/tasks/services/turn_output_slicer.dart';
import '../../features/voice/services/device_voice_service.dart';
import '../../features/voice/services/task_speech_policy.dart';
import '../../features/voice/services/voice_service.dart';
import '../models/task_status.dart';
import '../storage/json_task_history_store.dart';
import '../storage/task_history_store.dart';

class ArminAppState extends ChangeNotifier {
  static const _turnOutputSlicer = TurnOutputSlicer();

  ArminAppState({
    required TaskHistoryStore store,
    required this.agentSessionService,
    required this.voiceService,
    TaskSpeechPolicy? taskSpeechPolicy,
    OutputSummaryProvider? outputSummaryProvider,
    this.speechSettings = const TaskSpeechSettings(),
  })  : _store = store,
        _taskSpeechPolicy = taskSpeechPolicy ?? const TaskSpeechPolicy(),
        outputSummaryProvider =
            outputSummaryProvider ?? SelectableOutputSummaryProvider() {
    _configureOutputSummaryProvider();
  }

  ArminAppState.phase2({
    TaskHistoryStore? store,
    AgentSessionService? agentSessionService,
    VoiceService? voiceService,
    OutputSummaryProvider? outputSummaryProvider,
  })  : _store = store ?? JsonTaskHistoryStore(),
        agentSessionService = agentSessionService ?? SSHAgentSessionService(),
        voiceService = voiceService ?? DeviceVoiceService(),
        _taskSpeechPolicy = const TaskSpeechPolicy(),
        outputSummaryProvider =
            outputSummaryProvider ?? SelectableOutputSummaryProvider(),
        speechSettings = const TaskSpeechSettings() {
    _configureOutputSummaryProvider();
  }

  final TaskHistoryStore _store;
  final AgentSessionService agentSessionService;
  final VoiceService voiceService;
  final TaskSpeechPolicy _taskSpeechPolicy;
  final OutputSummaryProvider outputSummaryProvider;
  final SecretRedactor _secretRedactor = const SecretRedactor();
  TaskSpeechSettings speechSettings;

  List<HostConfig> hosts = const [];
  List<TaskSession> tasks = const [];
  List<ProjectPathConfig> projectPaths = const [];
  bool ready = false;
  final Map<String, StreamSubscription<AgentExecutionUpdate>>
      _runningExecutions = {};
  final Map<String, String> _lastSpokenHashes = {};

  Future<void> load() async {
    hosts = await _store.loadHosts();
    tasks = await _store.loadTasks();
    projectPaths = await _store.loadProjectPaths();
    ready = true;
    notifyListeners();
  }

  Future<void> saveHost(HostConfig host) async {
    await _store.saveHost(host);
    hosts = await _store.loadHosts();
    notifyListeners();
  }

  Future<void> deleteHost(String hostId) async {
    // Load current hosts, remove the one to delete, and save the rest
    final currentHosts = await _store.loadHosts();
    final remainingHosts = currentHosts.where((h) => h.id != hostId).toList();

    // Clear and re-save all remaining hosts
    for (final host in remainingHosts) {
      await _store.saveHost(host);
    }

    // Reload to ensure consistency
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

  Future<void> saveTask(TaskSession task) async {
    await _store.saveTask(task);
    tasks = await _store.loadTasks();
    notifyListeners();
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
      outputSummaryProvider: outputSummaryProvider,
    );
    if (text.trim().isEmpty) {
      return false;
    }
    await voiceService.speakSummary(text);
    return true;
  }

  Future<void> deleteTask(String taskId) async {
    final task = _latestTask(taskId);
    if (task != null && !_canDeleteTask(task.status)) {
      throw StateError('Only completed or failed tasks can be deleted.');
    }
    await _store.deleteTask(taskId);
    tasks = await _store.loadTasks();
    notifyListeners();
  }

  Future<void> updateTaskStatus(TaskSession task, TaskStatus status) async {
    final now = DateTime.now();
    await saveTask(
      task.copyWith(
        status: status,
        updatedAt: now,
        completedAt: _completedAtFor(status, task.completedAt, now),
        shortSummary:
            status == TaskStatus.failed && task.shortSummary.trim().isEmpty
                ? '用户手动标记为失败'
                : task.shortSummary,
      ),
    );
  }

  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    await _store.saveProjectPath(projectPath);
    projectPaths = await _store.loadProjectPaths();
    notifyListeners();
  }

  Future<void> deleteProjectPath(String projectPathId) async {
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
    await agentSessionService.sendFollowUp(
      await _controlRequest(task, instruction: instruction),
    );
    if (instruction.trimLeft().startsWith('APPROVAL_DECISION:')) {
      return;
    }
    final latest = _latestTask(task.id) ?? task;
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
    await _saveControlledTask(
      taskWithNewTurn,
      status: TaskStatus.running,
      logMessage: 'User sent follow-up instruction.',
      eventType:
          rawVoiceText.trim().isEmpty ? 'runtime_control' : 'voice_follow_up',
    );
    startTaskExecution(_latestTask(task.id) ?? latest,
        _attachRequest(_latestTask(task.id) ?? latest));
  }

  Future<void> selectTerminalOption(
      TaskSession task, TerminalPromptOption option,
      {String customResponse = ''}) async {
    final latest = _latestTask(task.id) ?? task;
    final prompt = latest.terminalPrompt;
    if (prompt == null ||
        !prompt.options.any((candidate) => candidate.key == option.key)) {
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
    await _saveControlledTask(
      latest.copyWith(clearTerminalPrompt: true),
      status: TaskStatus.running,
      logMessage: 'Terminal option selected by user: ${option.key}.',
      eventType: 'terminal_prompt_resolved',
    );
    final updatedTask = _latestTask(task.id) ?? latest;
    startTaskExecution(updatedTask, _attachRequest(updatedTask));
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
    );
    final synced = await _syncRemoteSnapshot(_latestTask(task.id) ?? latest);
    final attached = _latestTask(task.id) ?? synced;
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
    );
    final resumed = _latestTask(task.id) ?? latest;
    startTaskExecution(resumed, _attachRequest(resumed));
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
    final request = await _controlRequest(latest);
    final taskWithFinalLog = await _captureFinalLog(latest, request);
    await _saveControlledTask(
      taskWithFinalLog,
      status: TaskStatus.stopped,
      logMessage: 'Task stopped by user.',
      completed: true,
      turnStatus: NativeOutputTurnStatus.stopped,
      userDecision: 'stopped',
    );
    try {
      await agentSessionService.stop(request);
    } catch (error) {
      await _recordCleanupFailure(
          _latestTask(task.id) ?? taskWithFinalLog, error);
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

  Future<TaskSession> _syncRemoteSnapshot(TaskSession task) async {
    if (task.turns.isEmpty) {
      return task;
    }
    final snapshot = await _captureLogBestEffort(await _controlRequest(task));
    final captured = snapshot.trim();
    if (captured.isEmpty) {
      return task;
    }
    final synced = _taskWithSyncedTurnSnapshot(task, captured);
    if (_turnsSignature(task) == _turnsSignature(synced)) {
      return task;
    }
    await saveTask(synced);
    return synced;
  }

  String _turnsSignature(TaskSession task) {
    return task.turns
        .map(
          (turn) => [
            turn.turnIndex,
            turn.status.name,
            turn.userInput,
            turn.rawOutput,
            turn.cleanedOutput,
            turn.lastOutputAt.microsecondsSinceEpoch,
          ].join('|'),
        )
        .join('\n---\n');
  }

  Future<TaskSession> _captureFinalLog(
    TaskSession task,
    AgentControlRequest request,
  ) async {
    final finalLog = await _captureLogBestEffort(request);
    if (finalLog.trim().isEmpty) {
      return task;
    }
    return _appendRawLog(task, 'Final captured output:\n$finalLog\n');
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
    final request = await _controlRequest(latest);
    final taskWithFinalLog = await _captureFinalLog(latest, request);
    await _saveControlledTask(
      taskWithFinalLog,
      status: TaskStatus.userCompleted,
      logMessage: 'Task marked completed by user.',
      completed: true,
      eventType: 'user_mark_completed',
      shortSummary: taskWithFinalLog.shortSummary.trim().isEmpty
          ? '用户已确认任务完成'
          : taskWithFinalLog.shortSummary,
      turnStatus: NativeOutputTurnStatus.completedByUser,
      userDecision: 'completed',
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? taskWithFinalLog);
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
    final request = await _controlRequest(latest);
    final taskWithFinalLog = await _captureFinalLog(latest, request);
    await _saveControlledTask(
      taskWithFinalLog,
      status: TaskStatus.userFailed,
      logMessage: 'Task marked failed by user.',
      completed: true,
      eventType: 'user_mark_failed',
      shortSummary: taskWithFinalLog.shortSummary.trim().isEmpty
          ? '用户已标记任务失败'
          : taskWithFinalLog.shortSummary,
      turnStatus: NativeOutputTurnStatus.failedByUser,
      userDecision: 'failed',
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? taskWithFinalLog);
  }

  Future<void> cleanupRemoteSession(TaskSession task) async {
    final latest = _latestTask(task.id) ?? task;
    final request = await _controlRequest(latest);
    final taskWithFinalLog = await _captureFinalLog(latest, request);
    await agentSessionService.cleanup(request);
    await _saveControlledTask(
      taskWithFinalLog,
      status: taskWithFinalLog.status,
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
    var pendingUpdates = Future<void>.value();
    late final StreamSubscription<AgentExecutionUpdate> subscription;
    subscription = agentSessionService.execute(request).listen(
      (update) {
        pendingUpdates = pendingUpdates.then((_) async {
          if (_runningExecutions[task.id] != subscription) {
            return;
          }
          final latest = _latestTask(task.id) ?? task;
          if (_isTerminal(latest.status)) {
            await disconnectTask(latest,
                markFailed: false, recordDetached: false);
            return;
          }
          final previousTask = latest;
          task = _taskWithExecutionUpdate(previousTask, update);
          await saveTask(task);
          await _speakTaskUpdate(previousTask, task);
        });
      },
      onError: (Object error) async {
        await pendingUpdates;
        if (_runningExecutions[task.id] != subscription) {
          return;
        }
        _runningExecutions.remove(task.id);
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(latest.status)) {
          return;
        }
        if (_isRecoverableObserverError(error)) {
          final detachedTask = await _saveObserverDisconnected(latest, error);
          await _speakTaskUpdate(latest, detachedTask);
          return;
        }
        final failedTask = await _saveFailedExecution(latest, error);
        final finalTask = await _captureAndSaveFinalLog(failedTask);
        await _speakTaskUpdate(latest, finalTask);
        await _cleanupTaskSession(finalTask);
      },
      onDone: () async {
        await pendingUpdates;
        if (_runningExecutions[task.id] != subscription) {
          return;
        }
        _runningExecutions.remove(task.id);
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(latest.status)) {
          final finalTask = await _captureAndSaveFinalLog(latest);
          await _cleanupTaskSession(finalTask);
        }
      },
    );
    _runningExecutions[initialTask.id] = subscription;
  }

  Future<void> disconnectTask(
    TaskSession task, {
    bool markFailed = false,
    bool recordDetached = true,
  }) async {
    final subscription = _runningExecutions.remove(task.id);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    if (!markFailed) {
      if (!recordDetached) {
        return;
      }
      await _saveControlledTask(
        task,
        status: TaskStatus.observerDetached,
        logMessage:
            'Observer detached by user. Remote tmux session may still be running.',
        shortSummary: '已断开手机监听，远端 Agent 可能仍在运行',
        eventType: 'observer_detached',
      );
      return;
    }
    await _saveControlledTask(
      task,
      status: TaskStatus.failed,
      logMessage:
          'Observer detached by user. Remote task may still be running.',
      completed: true,
      shortSummary: '用户已断开监听，远端任务可能仍在运行',
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
    const notice = '远端会话清理未确认，tmux 可能仍在运行；请从菜单重试清理。';
    await _saveControlledTask(
      latest,
      status: latest.status,
      logMessage: 'Remote tmux session cleanup failed: $safeError',
      eventType: 'runtime_cleanup_failed',
      shortSummary: latest.shortSummary.contains(notice)
          ? latest.shortSummary
          : '${latest.shortSummary.trim()}\n$notice'.trim(),
    );
  }

  Future<TaskSession> _captureAndSaveFinalLog(TaskSession task) async {
    final taskWithLog =
        await _captureFinalLog(task, await _controlRequest(task));
    if (identical(taskWithLog, task)) {
      return task;
    }
    await saveTask(taskWithLog);
    return taskWithLog;
  }

  Future<void> resolveApproval(TaskSession task,
      {required bool approved}) async {
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
    );
  }

  Future<void> _saveControlledTask(
    TaskSession task, {
    required TaskStatus status,
    required String logMessage,
    bool completed = false,
    String? shortSummary,
    String eventType = 'runtime_control',
    NativeOutputTurnStatus? turnStatus,
    String? userDecision,
  }) async {
    final now = DateTime.now();
    final logLine = '$logMessage\n';
    final taskWithTurn = turnStatus == null
        ? task
        : _taskWithCurrentTurnDecision(
            task,
            status: turnStatus,
            userDecision: userDecision,
            now: now,
          );
    await saveTask(
      taskWithTurn.copyWith(
        status: status,
        rawLog: '${taskWithTurn.rawLog}$logLine',
        updatedAt: now,
        completedAt: completed ? now : taskWithTurn.completedAt,
        shortSummary: shortSummary ??
            (status == TaskStatus.stopped
                ? '用户已停止任务'
                : taskWithTurn.shortSummary),
        executionLogs: [
          ...taskWithTurn.executionLogs,
          ExecutionLog(
            id: 'log-${now.microsecondsSinceEpoch}',
            taskId: taskWithTurn.id,
            rawOutput: logLine,
            createdAt: now,
          ),
        ],
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: taskWithTurn.id,
            eventType: eventType,
            payloadJson: '{"status":"${status.name}"}',
            now: now,
          ),
        ],
      ),
    );
  }

  Future<TaskSession> _appendRawLog(TaskSession task, String rawOutput) async {
    final now = DateTime.now();
    final taskWithTurn = _taskWithTurnOutput(
      task,
      rawOutput: rawOutput,
      cleanedOutput: '',
      now: now,
    );
    final updated = taskWithTurn.copyWith(
      rawLog: '${task.rawLog}$rawOutput',
      updatedAt: now,
      executionLogs: [
        ...taskWithTurn.executionLogs,
        ExecutionLog(
          id: 'log-${now.microsecondsSinceEpoch}',
          taskId: task.id,
          rawOutput: rawOutput,
          createdAt: now,
        ),
      ],
    );
    await saveTask(updated);
    return updated;
  }

  TaskSession? _latestTask(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  TaskSession _taskWithExecutionUpdate(
    TaskSession task,
    AgentExecutionUpdate update,
  ) {
    final updateAt = DateTime.now();
    final rawLog = '${task.rawLog}${update.rawOutput}';
    final executionLogs = [
      ...task.executionLogs,
      ExecutionLog(
        id: 'log-${updateAt.microsecondsSinceEpoch}',
        taskId: task.id,
        rawOutput: update.rawOutput,
        createdAt: updateAt,
      ),
    ];
    final taskWithTurn = _taskWithTurnOutput(
      task,
      rawOutput: update.rawOutput,
      cleanedOutput: update.cleanedOutput ?? '',
      now: updateAt,
      status: _turnStatusForUpdate(update),
      idleDetectedAt: update.turnIdle || update.done ? updateAt : null,
    );

    if (update.approval != null) {
      final approval = update.approval!;
      return taskWithTurn.copyWith(
        status: TaskStatus.needApproval,
        rawLog: rawLog,
        approval: approval,
        approvalRequests: [...taskWithTurn.approvalRequests, approval],
        executionLogs: executionLogs,
        updatedAt: updateAt,
        shortSummary: approval.reason,
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'approval_requested',
            payloadJson: '{"risk":"${approval.risk}"}',
            now: updateAt,
          ),
        ],
      );
    }

    if (update.terminalPrompt != null) {
      return taskWithTurn.copyWith(
        status: TaskStatus.needAttention,
        rawLog: rawLog,
        terminalPrompt: update.terminalPrompt,
        executionLogs: executionLogs,
        updatedAt: updateAt,
        shortSummary: update.terminalPrompt!.question,
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'terminal_prompt_requested',
            payloadJson: '{"options":${update.terminalPrompt!.options.length}}',
            now: updateAt,
          ),
        ],
      );
    }

    if (update.result != null) {
      final observedAt = DateTime.now();
      final resultStatus = update.result!.status;
      final needsAttention = resultStatus != 'success';
      return taskWithTurn.copyWith(
        status: needsAttention ? TaskStatus.needAttention : TaskStatus.turnIdle,
        rawLog: rawLog,
        result: update.result,
        updatedAt: observedAt,
        shortSummary: update.result!.summary,
        summary: update.result!.summary,
        executionLogs: executionLogs,
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: needsAttention ? 'need_attention' : 'turn_idle',
            payloadJson: '{"source":"legacy_result","status":"$resultStatus"}',
            now: observedAt,
          ),
        ],
        clearApproval: true,
        clearTerminalPrompt: true,
      );
    }

    if (update.runtimeLost) {
      final failedAt = DateTime.now();
      final runtimeLostSummary = _runtimeLostSummary(update.cleanedOutput);
      return taskWithTurn.copyWith(
        status: TaskStatus.runtimeLost,
        rawLog: rawLog,
        updatedAt: failedAt,
        completedAt: failedAt,
        shortSummary: runtimeLostSummary,
        summary: update.cleanedOutput,
        executionLogs: executionLogs,
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'runtime_lost',
            payloadJson: '{"observer_state":"${update.observerState.name}"}',
            now: failedAt,
          ),
        ],
        clearApproval: true,
      );
    }

    if (update.turnIdle || update.done) {
      final idleAt = DateTime.now();
      final summary = update.cleanedOutput?.trim() ?? '';
      return taskWithTurn.copyWith(
        status: update.needsAttention
            ? TaskStatus.needAttention
            : TaskStatus.turnIdle,
        rawLog: rawLog,
        result: summary.isEmpty
            ? task.result
            : TaskResult(
                status: 'turn_idle',
                summary: summary,
                changedFiles: const [],
                validation: const [],
                risks: const [],
                nextActions: const [],
              ),
        updatedAt: idleAt,
        shortSummary: update.needsAttention
            ? 'Agent 可能需要用户处理'
            : (summary.isEmpty ? 'Agent 暂时停止输出' : summary),
        summary: summary.isEmpty ? task.summary : summary,
        executionLogs: executionLogs,
        metricEvents: [
          ...taskWithTurn.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: update.needsAttention ? 'need_attention' : 'turn_idle',
            payloadJson: '{"observer_state":"${update.observerState.name}"}',
            now: idleAt,
          ),
        ],
        clearApproval: !update.needsAttention,
        clearTerminalPrompt: !update.needsAttention,
      );
    }

    return taskWithTurn.copyWith(
      rawLog: rawLog,
      executionLogs: executionLogs,
      updatedAt: updateAt,
      metricEvents: [
        ...taskWithTurn.metricEvents,
        MetricEvent.create(
          taskId: task.id,
          eventType: 'log_update',
          payloadJson: '{"bytes":${update.rawOutput.length}}',
          now: updateAt,
        ),
      ],
    );
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

  TaskSession _taskWithSyncedTurnSnapshot(
    TaskSession task,
    String capturedPane,
  ) {
    final turns = task.turns.isEmpty
        ? _taskWithInitialTurn(
            task,
            userInput: task.userText.isEmpty ? task.title : task.userText,
            now: task.startedAt ?? task.createdAt,
          ).turns
        : task.turns;
    final snapshotTurns = [...turns];
    final current = snapshotTurns.last;
    final observedAt = DateTime.now();
    snapshotTurns[snapshotTurns.length - 1] = current.copyWith(
      rawOutput: capturedPane,
      cleanedOutput: capturedPane,
      lastOutputAt: observedAt,
    );
    final scopedRaw = _turnOutputSlicer.rawOutputForTurn(
      snapshotTurns,
      snapshotTurns.length - 1,
    );
    final scopedClean = _turnOutputSlicer.outputForTurn(
      snapshotTurns,
      snapshotTurns.length - 1,
    );
    if (scopedRaw.trim().isEmpty && scopedClean.trim().isEmpty) {
      return task;
    }
    snapshotTurns[snapshotTurns.length - 1] = current.copyWith(
      rawOutput: scopedRaw.isEmpty ? current.rawOutput : scopedRaw,
      cleanedOutput: scopedClean.isEmpty ? current.cleanedOutput : scopedClean,
      lastOutputAt: observedAt,
    );
    final summary = scopedClean.trim();
    return task.copyWith(
      turns: snapshotTurns,
      updatedAt: observedAt,
      summary: summary.isEmpty ? task.summary : summary,
      shortSummary: summary.isEmpty ? task.shortSummary : summary,
      result: summary.isEmpty
          ? task.result
          : TaskResult(
              status: 'turn_idle',
              summary: summary,
              changedFiles: const [],
              validation: const [],
              risks: const [],
              nextActions: const [],
            ),
    );
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

  NativeOutputTurnStatus? _turnStatusForUpdate(AgentExecutionUpdate update) {
    if (update.runtimeLost) {
      return NativeOutputTurnStatus.runtimeLost;
    }
    if (update.approval != null || update.needsAttention) {
      return NativeOutputTurnStatus.needAttention;
    }
    if (update.turnIdle || update.done || update.result != null) {
      return NativeOutputTurnStatus.turnIdle;
    }
    return null;
  }

  String _runtimeLostSummary(String? cleanedOutput) {
    final output = cleanedOutput?.toLowerCase() ?? '';
    if (output.contains('runtime limit reached')) {
      return '任务达到最长运行时限，远端会话已清理';
    }
    if (output.contains('could not find tmux session') ||
        output.contains('could not capture tmux pane')) {
      return '远端会话不存在，可能已结束';
    }
    return '远端运行时可能已断开';
  }

  Future<TaskSession> _saveFailedExecution(
      TaskSession task, Object error) async {
    final failedAt = DateTime.now();
    final message = 'SSH 执行失败：${error.toString()}';
    final taskWithFailedTurn = _taskWithCurrentTurnDecision(
      task,
      status: NativeOutputTurnStatus.failed,
      userDecision: 'failed',
      now: failedAt,
    );
    final failedTask = taskWithFailedTurn.copyWith(
      status: TaskStatus.failed,
      rawLog: '${taskWithFailedTurn.rawLog}$message\n',
      updatedAt: failedAt,
      completedAt: failedAt,
      shortSummary: message,
      summary: message,
      executionLogs: [
        ...taskWithFailedTurn.executionLogs,
        ExecutionLog(
          id: 'log-${failedAt.microsecondsSinceEpoch}',
          taskId: task.id,
          rawOutput: '$message\n',
          createdAt: failedAt,
        ),
      ],
      metricEvents: [
        ...taskWithFailedTurn.metricEvents,
        MetricEvent.create(
          taskId: task.id,
          eventType: 'task_failed',
          payloadJson: '{"reason":"ssh_execution_error"}',
          now: failedAt,
        ),
      ],
      clearApproval: true,
    );
    await saveTask(failedTask);
    return failedTask;
  }

  Future<TaskSession> _saveObserverDisconnected(
    TaskSession task,
    Object error,
  ) async {
    final now = DateTime.now();
    final message = _secretRedactor.redactInlineSecrets(
      'SSH 监听中断：${error.toString()}',
    );
    final detachedTask = task.copyWith(
      status: TaskStatus.observerDetached,
      rawLog: '${task.rawLog}$message\n',
      updatedAt: now,
      shortSummary: 'SSH 监听已断开，远端任务状态未知；可以重新监听或停止任务',
      summary: message,
      executionLogs: [
        ...task.executionLogs,
        ExecutionLog(
          id: 'log-${now.microsecondsSinceEpoch}',
          taskId: task.id,
          rawOutput: '$message\n',
          createdAt: now,
        ),
      ],
      metricEvents: [
        ...task.metricEvents,
        MetricEvent.create(
          taskId: task.id,
          eventType: 'observer_connection_lost',
          payloadJson: '{"status":"observerDetached"}',
          now: now,
        ),
      ],
      clearApproval: true,
    );
    await saveTask(detachedTask);
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

  Future<void> _speakTaskUpdate(
    TaskSession previous,
    TaskSession current,
  ) async {
    final decision = await _taskSpeechPolicy.decide(
      previous: previous,
      current: current,
      settings: speechSettings,
      outputSummaryProvider: outputSummaryProvider,
    );
    if (!decision.shouldSpeak ||
        _lastSpokenHashes[current.id] == decision.hash) {
      return;
    }
    _lastSpokenHashes[current.id] = decision.hash;
    try {
      await voiceService.speakSummary(decision.text);
    } catch (error) {
      debugPrint('Task speech failed: $error');
    }
  }

  bool _isTerminal(TaskStatus status) {
    return status == TaskStatus.stopped ||
        status == TaskStatus.runtimeLost ||
        status == TaskStatus.userCompleted ||
        status == TaskStatus.userFailed ||
        status == TaskStatus.completed ||
        status == TaskStatus.failed;
  }

  bool _canDeleteTask(TaskStatus status) {
    return status == TaskStatus.completed ||
        status == TaskStatus.failed ||
        status == TaskStatus.userCompleted ||
        status == TaskStatus.userFailed;
  }

  Future<void> _saveApprovalDecision(
    TaskSession task, {
    required bool approved,
  }) async {
    final now = DateTime.now();
    final decision = approved ? 'approved' : 'rejected';
    final pendingApproval = task.approval;
    final resolvedApproval = pendingApproval?.copyWith(
      status: decision,
      resolvedAt: now,
    );
    final approvalRequests = task.approvalRequests.map((approval) {
      if (pendingApproval != null &&
          approval.reason == pendingApproval.reason &&
          approval.command == pendingApproval.command) {
        return resolvedApproval!;
      }
      return approval;
    }).toList();
    if (resolvedApproval != null && approvalRequests.isEmpty) {
      approvalRequests.add(resolvedApproval);
    }
    final logLine = 'Approval $decision by user.\n';
    await saveTask(
      task.copyWith(
        status: TaskStatus.running,
        approvalRequests: approvalRequests,
        rawLog: '${task.rawLog}$logLine',
        updatedAt: now,
        executionLogs: [
          ...task.executionLogs,
          ExecutionLog(
            id: 'log-${now.microsecondsSinceEpoch}',
            taskId: task.id,
            rawOutput: logLine,
            createdAt: now,
          ),
        ],
        clearApproval: true,
      ),
    );
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
}
