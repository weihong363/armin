import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/task_session.dart';

abstract class TaskHistoryStore {
  Future<List<HostConfig>> loadHosts();

  Future<void> saveHost(HostConfig host);

  Future<List<TaskSession>> loadTasks();

  Future<void> saveTask(TaskSession task);
}
