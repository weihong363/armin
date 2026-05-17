import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/task_session.dart';
import 'task_history_store.dart';

class InMemoryTaskHistoryStore implements TaskHistoryStore {
  InMemoryTaskHistoryStore();

  final List<HostConfig> _hosts = [];
  final List<TaskSession> _tasks = [];

  @override
  Future<List<HostConfig>> loadHosts() async => List.unmodifiable(_hosts);

  @override
  Future<List<TaskSession>> loadTasks() async => List.unmodifiable(_tasks);

  @override
  Future<void> saveHost(HostConfig host) async {
    final index = _hosts.indexWhere((item) => item.id == host.id);
    if (index >= 0) {
      _hosts[index] = host;
      return;
    }
    _hosts.add(host);
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    final index = _tasks.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      _tasks[index] = task;
      return;
    }
    _tasks.insert(0, task);
  }
}
