import '../../features/hosts/models/host_config.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/tasks/models/task_session.dart';

abstract class TaskHistoryStore {
  Future<List<HostConfig>> loadHosts();

  Future<void> saveHost(HostConfig host);

  Future<void> deleteHost(String hostId);

  /// [DEV-ONLY] Import host passwords from an emulator seed file.
  ///
  /// This is a development convenience for the Android emulator workflow.
  /// On each cold boot, `seed-config.sh` may push a one-time password file
  /// to `/data/local/tmp/armin_seed_passwords.json`. This method reads that
  /// file and imports passwords into the platform secure storage, then
  /// deletes the file.
  ///
  /// **Not used in production.** The default implementation is a no-op.
  /// Override only in stores that participate in emulator testing.
  Future<void> importSeedPasswords() async {
    // Default no-op: production stores and most test mocks need no action.
  }

  Future<List<TaskSession>> loadTasks();

  Future<void> saveTask(TaskSession task);

  Future<void> deleteTask(String taskId);

  Future<List<ProjectPathConfig>> loadProjectPaths();

  Future<void> saveProjectPath(ProjectPathConfig projectPath);

  Future<void> deleteProjectPath(String projectPathId);
}
