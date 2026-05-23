import '../../features/hosts/models/host_config.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/tasks/models/task_session.dart';
import 'task_history_store.dart';

class InMemoryTaskHistoryStore implements TaskHistoryStore {
  InMemoryTaskHistoryStore();

  final List<HostConfig> _hosts = [];
  final List<TaskSession> _tasks = [];
  final List<ProjectPathConfig> _projectPaths = [];

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

  @override
  Future<void> deleteTask(String taskId) async {
    _tasks.removeWhere((task) => task.id == taskId);
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async {
    return List.unmodifiable(_projectPaths);
  }

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    final index = _projectPaths.indexWhere((item) => item.id == projectPath.id);
    if (index >= 0) {
      _projectPaths[index] = projectPath;
      return;
    }
    _projectPaths.add(projectPath);
  }

  @override
  Future<void> deleteProjectPath(String projectPathId) async {
    _projectPaths.removeWhere((item) => item.id == projectPathId);
  }
}
