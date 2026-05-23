import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/parsers/task_result.dart';
import '../../features/agent/services/ssh_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/tasks/models/execution_log.dart';
import '../../features/tasks/models/metric_event.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/voice/services/device_voice_service.dart';
import '../../features/voice/services/voice_service.dart';
import '../models/task_status.dart';
import '../storage/json_task_history_store.dart';
import '../storage/task_history_store.dart';

class ArminAppState extends ChangeNotifier {
  ArminAppState({
    required TaskHistoryStore store,
    required this.agentSessionService,
    required this.voiceService,
  }) : _store = store;

  ArminAppState.phase2({
    TaskHistoryStore? store,
    AgentSessionService? agentSessionService,
    VoiceService? voiceService,
  })  : _store = store ?? JsonTaskHistoryStore(),
        agentSessionService = agentSessionService ?? SSHAgentSessionService(),
        voiceService = voiceService ?? DeviceVoiceService();

  final TaskHistoryStore _store;
  final AgentSessionService agentSessionService;
  final VoiceService voiceService;

  List<HostConfig> hosts = const [];
  List<TaskSession> tasks = const [];
  List<ProjectPathConfig> projectPaths = const [];
  bool ready = false;
  final Map<String, StreamSubscription<AgentExecutionUpdate>>
      _runningExecutions = {};

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

  Future<void> sendFollowUp(TaskSession task, String instruction) async {
    await agentSessionService.sendFollowUp(
      await _controlRequest(task, instruction: instruction),
    );
    if (instruction.trimLeft().startsWith('APPROVAL_DECISION:')) {
      return;
    }
    final latest = _latestTask(task.id) ?? task;
    await _saveControlledTask(
      latest,
      status: TaskStatus.running,
      logMessage: 'User sent follow-up instruction.',
    );
    startTaskExecution(_latestTask(task.id) ?? latest,
        _attachRequest(_latestTask(task.id) ?? latest));
  }

  Future<void> pauseTask(TaskSession task) async {
    await agentSessionService.pause(await _controlRequest(task));
    await _saveControlledTask(
      task,
      status: TaskStatus.paused,
      logMessage: 'Task paused by user.',
    );
  }

  Future<void> resumeTask(TaskSession task) async {
    await agentSessionService.resume(await _controlRequest(task));
    await _saveControlledTask(
      task,
      status: TaskStatus.running,
      logMessage: 'Task resumed by user.',
    );
  }

  Future<void> stopTask(TaskSession task) async {
    await agentSessionService.stop(await _controlRequest(task));
    await _saveControlledTask(
      task,
      status: TaskStatus.stopped,
      logMessage: 'Task stopped by user.',
      completed: true,
    );
  }

  Future<void> markTaskCompleted(TaskSession task) async {
    await _saveControlledTask(
      task,
      status: TaskStatus.userCompleted,
      logMessage: 'Task marked completed by user.',
      completed: true,
      eventType: 'user_mark_completed',
      shortSummary:
          task.shortSummary.trim().isEmpty ? '用户已确认任务完成' : task.shortSummary,
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? task);
  }

  Future<void> markTaskFailed(TaskSession task) async {
    await _saveControlledTask(
      task,
      status: TaskStatus.userFailed,
      logMessage: 'Task marked failed by user.',
      completed: true,
      eventType: 'user_mark_failed',
      shortSummary:
          task.shortSummary.trim().isEmpty ? '用户已标记任务失败' : task.shortSummary,
    );
    await _cleanupTaskSession(_latestTask(task.id) ?? task);
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
    late final StreamSubscription<AgentExecutionUpdate> subscription;
    subscription = agentSessionService.execute(request).listen(
      (update) async {
        if (!_runningExecutions.containsKey(task.id)) {
          return;
        }
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(latest.status)) {
          await disconnectTask(latest, markFailed: false);
          return;
        }
        task = _taskWithExecutionUpdate(latest, update);
        await saveTask(task);
      },
      onError: (Object error) async {
        _runningExecutions.remove(task.id);
        final latest = _latestTask(task.id) ?? task;
        if (_isTerminal(latest.status)) {
          return;
        }
        await _saveFailedExecution(latest, error);
        await _cleanupTaskSession(_latestTask(latest.id) ?? latest);
      },
      onDone: () async {
        _runningExecutions.remove(task.id);
        if (_isTerminal(task.status)) {
          await _cleanupTaskSession(task);
        }
        if (task.status == TaskStatus.completed) {
          await voiceService.speakSummary(task.shortSummary);
        }
      },
    );
    _runningExecutions[initialTask.id] = subscription;
  }

  Future<void> disconnectTask(
    TaskSession task, {
    bool markFailed = true,
  }) async {
    final subscription = _runningExecutions.remove(task.id);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    if (!markFailed) {
      return;
    }
    await _saveControlledTask(
      task,
      status: TaskStatus.failed,
      logMessage:
          'Disconnected from SSH session by user. Remote task may still be running.',
      completed: true,
      shortSummary: '用户已断开连接，远端任务可能仍在运行',
    );
  }

  Future<void> _cleanupTaskSession(TaskSession task) async {
    try {
      await agentSessionService.cleanup(await _controlRequest(task));
    } catch (_) {
      // Cleanup is best-effort; raw log has already been captured.
    }
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
  }) async {
    final now = DateTime.now();
    final logLine = '$logMessage\n';
    await saveTask(
      task.copyWith(
        status: status,
        rawLog: '${task.rawLog}$logLine',
        updatedAt: now,
        completedAt: completed ? now : task.completedAt,
        shortSummary: shortSummary ??
            (status == TaskStatus.stopped ? '用户已停止任务' : task.shortSummary),
        executionLogs: [
          ...task.executionLogs,
          ExecutionLog(
            id: 'log-${now.microsecondsSinceEpoch}',
            taskId: task.id,
            rawOutput: logLine,
            createdAt: now,
          ),
        ],
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: eventType,
            payloadJson: '{"status":"${status.name}"}',
            now: now,
          ),
        ],
      ),
    );
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

    if (update.approval != null) {
      final approval = update.approval!;
      return task.copyWith(
        status: TaskStatus.needApproval,
        rawLog: rawLog,
        approval: approval,
        approvalRequests: [...task.approvalRequests, approval],
        executionLogs: executionLogs,
        updatedAt: updateAt,
        shortSummary: approval.reason,
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'approval_requested',
            payloadJson: '{"risk":"${approval.risk}"}',
            now: updateAt,
          ),
        ],
      );
    }

    if (update.result != null) {
      final completedAt = DateTime.now();
      final resultStatus = update.result!.status;
      return task.copyWith(
        status: resultStatus == 'success'
            ? TaskStatus.completed
            : TaskStatus.failed,
        rawLog: rawLog,
        result: update.result,
        updatedAt: completedAt,
        completedAt: completedAt,
        shortSummary: update.result!.summary,
        summary: update.result!.summary,
        executionLogs: executionLogs,
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'task_completed',
            payloadJson: '{"status":"$resultStatus"}',
            now: completedAt,
          ),
        ],
        clearApproval: true,
      );
    }

    if (update.runtimeLost) {
      final failedAt = DateTime.now();
      return task.copyWith(
        status: TaskStatus.runtimeLost,
        rawLog: rawLog,
        updatedAt: failedAt,
        completedAt: failedAt,
        shortSummary: '远端运行时可能已断开',
        summary: update.cleanedOutput,
        executionLogs: executionLogs,
        metricEvents: [
          ...task.metricEvents,
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
      return task.copyWith(
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
            ? 'Codex 可能需要用户处理'
            : (summary.isEmpty ? 'Codex 暂时停止输出' : summary),
        summary: summary.isEmpty ? task.summary : summary,
        executionLogs: executionLogs,
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: update.needsAttention ? 'need_attention' : 'turn_idle',
            payloadJson: '{"observer_state":"${update.observerState.name}"}',
            now: idleAt,
          ),
        ],
        clearApproval: !update.needsAttention,
      );
    }

    return task.copyWith(
      rawLog: rawLog,
      executionLogs: executionLogs,
      updatedAt: updateAt,
      metricEvents: [
        ...task.metricEvents,
        MetricEvent.create(
          taskId: task.id,
          eventType: 'log_update',
          payloadJson: '{"bytes":${update.rawOutput.length}}',
          now: updateAt,
        ),
      ],
    );
  }

  Future<void> _saveFailedExecution(TaskSession task, Object error) async {
    final failedAt = DateTime.now();
    final message = 'SSH 执行失败：${error.toString()}';
    await saveTask(
      task.copyWith(
        status: TaskStatus.failed,
        rawLog: '${task.rawLog}$message\n',
        updatedAt: failedAt,
        completedAt: failedAt,
        shortSummary: message,
        summary: message,
        executionLogs: [
          ...task.executionLogs,
          ExecutionLog(
            id: 'log-${failedAt.microsecondsSinceEpoch}',
            taskId: task.id,
            rawOutput: '$message\n',
            createdAt: failedAt,
          ),
        ],
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'task_failed',
            payloadJson: '{"reason":"ssh_execution_error"}',
            now: failedAt,
          ),
        ],
        clearApproval: true,
      ),
    );
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
      TaskStatus.needAttention =>
        currentCompletedAt,
    };
  }
}
