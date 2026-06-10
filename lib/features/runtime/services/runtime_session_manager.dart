import '../models/runtime_session.dart';

class RuntimeSessionManager {
  final Map<String, RuntimeSession> _sessions = {};

  List<RuntimeSession> get sessions {
    return List.unmodifiable(_sessions.values);
  }

  RuntimeSession createOrRestore({
    required String name,
    required String projectPath,
    required String tmuxSessionName,
    DateTime? now,
  }) {
    RuntimeSession? existing;
    for (final session in _sessions.values) {
      if (session.projectPath == projectPath &&
          session.tmuxSessionName == tmuxSessionName &&
          session.status != RuntimeSessionStatus.destroyed) {
        existing = session;
        break;
      }
    }
    final observedAt = now ?? DateTime.now();
    if (existing != null) {
      final restored = existing.copyWith(
        status: RuntimeSessionStatus.active,
        updatedAt: observedAt,
      );
      _sessions[restored.id] = restored;
      return restored;
    }
    final id = _sessionId(projectPath, tmuxSessionName);
    final session = RuntimeSession(
      id: id,
      name: name.trim().isEmpty ? projectPath : name.trim(),
      projectPath: projectPath,
      tmuxSessionName: tmuxSessionName,
      status: RuntimeSessionStatus.active,
      createdAt: observedAt,
      updatedAt: observedAt,
    );
    _sessions[id] = session;
    return session;
  }

  RuntimeSession? attachTask(String sessionId, String taskId, {DateTime? now}) {
    final session = _sessions[sessionId];
    if (session == null || session.status == RuntimeSessionStatus.destroyed) {
      return null;
    }
    final taskIds = {...session.taskIds, taskId}.toList(growable: false);
    final updated = session.copyWith(
      status: RuntimeSessionStatus.active,
      updatedAt: now ?? DateTime.now(),
      taskIds: taskIds,
    );
    _sessions[sessionId] = updated;
    return updated;
  }

  RuntimeSession? detach(String sessionId, {DateTime? now}) {
    return _setStatus(sessionId, RuntimeSessionStatus.detached, now: now);
  }

  RuntimeSession? destroy(String sessionId, {DateTime? now}) {
    return _setStatus(sessionId, RuntimeSessionStatus.destroyed, now: now);
  }

  RuntimeSession? _setStatus(
    String sessionId,
    RuntimeSessionStatus status, {
    DateTime? now,
  }) {
    final session = _sessions[sessionId];
    if (session == null) {
      return null;
    }
    final updated = session.copyWith(
      status: status,
      updatedAt: now ?? DateTime.now(),
    );
    _sessions[sessionId] = updated;
    return updated;
  }

  String _sessionId(String projectPath, String tmuxSessionName) {
    final source = '$projectPath::$tmuxSessionName';
    return source
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '')
        .toLowerCase();
  }
}
