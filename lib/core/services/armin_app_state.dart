import 'package:flutter/foundation.dart';

import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/services/ssh_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/execution_log.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/voice/services/device_voice_service.dart';
import '../../features/voice/services/voice_service.dart';
import '../models/task_status.dart';
import '../storage/json_task_history_store.dart';
import '../storage/task_history_store.dart';

class ArminAppState extends ChangeNotifier {
  ArminAppState({
    required TaskHistoryStore store,
    required AgentSessionService agentSessionService,
    required VoiceService voiceService,
  })  : _store = store,
        agentSessionService = agentSessionService,
        voiceService = voiceService;

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
  bool ready = false;

  Future<void> load() async {
    hosts = await _store.loadHosts();
    tasks = await _store.loadTasks();
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

  Future<void> sendFollowUp(TaskSession task, String instruction) async {
    await agentSessionService.sendFollowUp(
      await _controlRequest(task, instruction: instruction),
    );
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

  Future<void> resolveApproval(TaskSession task, {required bool approved}) {
    final decision = approved ? 'approved' : 'rejected';
    return sendFollowUp(
      task,
      '''
APPROVAL_DECISION:
decision: $decision
Apply this decision to the pending approval request.
''',
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

  Future<AgentControlRequest> _controlRequest(
    TaskSession task, {
    String instruction = '',
  }) async {
    return AgentControlRequest(
      host: task.host.host,
      port: task.host.port,
      username: task.host.username,
      tmuxSessionName: task.host.tmuxSessionName,
      tmuxCommand: task.host.tmuxCommand,
      pathPrepend: task.host.pathPrepend,
      shellWrapper: task.host.shellWrapper,
      password: task.host.password,
      instruction: instruction,
    );
  }

  Future<void> _saveControlledTask(
    TaskSession task, {
    required TaskStatus status,
    required String logMessage,
    bool completed = false,
  }) async {
    final now = DateTime.now();
    final logLine = '$logMessage\n';
    await saveTask(
      task.copyWith(
        status: status,
        rawLog: '${task.rawLog}$logLine',
        updatedAt: now,
        completedAt: completed ? now : task.completedAt,
        shortSummary:
            status == TaskStatus.stopped ? '用户已停止任务' : task.shortSummary,
        executionLogs: [
          ...task.executionLogs,
          ExecutionLog(
            id: 'log-${now.microsecondsSinceEpoch}',
            taskId: task.id,
            rawOutput: logLine,
            createdAt: now,
          ),
        ],
      ),
    );
  }
}
