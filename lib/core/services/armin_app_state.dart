import 'package:flutter/foundation.dart';

import '../../features/agent/services/agent_session_service.dart';
import '../../features/agent/services/mock_agent_session_service.dart';
import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/task_session.dart';
import '../../features/voice/services/mock_voice_service.dart';
import '../../features/voice/services/voice_service.dart';
import '../storage/in_memory_task_history_store.dart';
import '../storage/task_history_store.dart';

class ArminAppState extends ChangeNotifier {
  ArminAppState({
    TaskHistoryStore? store,
    AgentSessionService? agentSessionService,
    VoiceService? voiceService,
  })  : _store = store ?? InMemoryTaskHistoryStore(),
        agentSessionService = agentSessionService ?? MockAgentSessionService(),
        voiceService = voiceService ?? MockVoiceService();

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

  HostConfig get defaultHost {
    if (hosts.isEmpty) {
      return HostConfig.mock();
    }
    return hosts.first;
  }
}
