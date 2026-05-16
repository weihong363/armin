import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/services/mock_agent_session_service.dart';
import '../../features/agent/services/ssh_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/voice/services/device_voice_service.dart';
import '../../features/voice/services/mock_voice_service.dart';
import '../../features/voice/services/voice_service.dart';
import '../storage/in_memory_task_history_store.dart';
import '../storage/json_task_history_store.dart';
import '../storage/task_history_store.dart';

class ArminAppState extends ChangeNotifier {
  ArminAppState({
    TaskHistoryStore? store,
    AgentSessionService? agentSessionService,
    VoiceService? voiceService,
  })  : _store = store ?? InMemoryTaskHistoryStore(),
        agentSessionService = agentSessionService ?? MockAgentSessionService(),
        voiceService = voiceService ?? MockVoiceService();

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
  }

  Future<void> resumeTask(TaskSession task) async {
    await agentSessionService.resume(await _controlRequest(task));
  }

  Future<void> stopTask(TaskSession task) async {
    await agentSessionService.stop(await _controlRequest(task));
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

  HostConfig get defaultHost {
    if (hosts.isEmpty) {
      return HostConfig.mock();
    }
    return hosts.first;
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
      privateKeyPem: await _privateKeyPemFor(task.host.privateKeyPath),
      instruction: instruction,
    );
  }

  Future<String?> _privateKeyPemFor(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) {
      return null;
    }
    final expandedPath = path.startsWith('~/')
        ? '${Platform.environment['HOME'] ?? ''}/${path.substring(2)}'
        : path;
    final file = File(expandedPath);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }
}
