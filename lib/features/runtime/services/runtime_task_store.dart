import '../models/runtime_task_snapshot.dart';
import '../models/work_state.dart';
import 'runtime_event_bus.dart';

abstract class RuntimeTaskStore {
  Future<RuntimeTaskSnapshot?> loadTask(String taskId);

  Future<List<RuntimeTaskSnapshot>> loadTasks();

  Future<void> saveTask(RuntimeTaskSnapshot task);
}

abstract class RuntimePersistenceStore implements RuntimeTaskStore {
  Future<void> saveEvent(RuntimeEvent event);

  Future<List<RuntimeEvent>> loadEvents({
    String? taskId,
    int? afterArchiveId,
    int? limit,
  });

  Future<void> saveWorkState(WorkState state);

  Future<WorkState?> loadWorkState(String taskId);

  Future<List<WorkState>> loadWorkStates();
}

class InMemoryRuntimeTaskStore implements RuntimePersistenceStore {
  final Map<String, RuntimeTaskSnapshot> _tasks = {};
  final List<RuntimeEvent> _events = [];
  int _nextArchiveId = 1;

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

  @override
  Future<void> saveEvent(RuntimeEvent event) async {
    _events.add(event.copyWith(archiveId: _nextArchiveId++));
  }

  @override
  Future<List<RuntimeEvent>> loadEvents({
    String? taskId,
    int? afterArchiveId,
    int? limit,
  }) async {
    final filtered = _events.where((event) {
      if (taskId != null && event.taskId != taskId) return false;
      if (afterArchiveId != null && (event.archiveId ?? 0) <= afterArchiveId) {
        return false;
      }
      return true;
    });
    final events = filtered.toList(growable: false);
    if (limit == null || events.length <= limit) {
      return events;
    }
    if (afterArchiveId != null) {
      return events.take(limit).toList(growable: false);
    }
    return events.sublist(events.length - limit);
  }

  @override
  Future<void> saveWorkState(WorkState state) async {
    final task = _tasks[state.taskId];
    if (task != null) {
      _tasks[state.taskId] = task.copyWith(workState: state);
    }
  }

  @override
  Future<WorkState?> loadWorkState(String taskId) async {
    return _tasks[taskId]?.workState;
  }

  @override
  Future<List<WorkState>> loadWorkStates() async {
    return _tasks.values
        .map((task) => task.workState)
        .whereType<WorkState>()
        .toList(growable: false)
      ..sort((a, b) {
        final left = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
  }
}
