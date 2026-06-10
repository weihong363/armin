import '../models/runtime_task_snapshot.dart';

abstract class RuntimeTaskStore {
  Future<RuntimeTaskSnapshot?> loadTask(String taskId);

  Future<List<RuntimeTaskSnapshot>> loadTasks();

  Future<void> saveTask(RuntimeTaskSnapshot task);
}

class InMemoryRuntimeTaskStore implements RuntimeTaskStore {
  final Map<String, RuntimeTaskSnapshot> _tasks = {};

  @override
  Future<RuntimeTaskSnapshot?> loadTask(String taskId) async {
    return _tasks[taskId];
  }

  @override
  Future<List<RuntimeTaskSnapshot>> loadTasks() async {
    final tasks = _tasks.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return tasks;
  }

  @override
  Future<void> saveTask(RuntimeTaskSnapshot task) async {
    _tasks[task.taskId] = task;
  }
}
