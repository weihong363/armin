enum RuntimeSessionStatus {
  active,
  detached,
  destroyed,
}

class RuntimeSession {
  const RuntimeSession({
    required this.id,
    required this.name,
    required this.projectPath,
    required this.tmuxSessionName,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.taskIds = const [],
  });

  final String id;
  final String name;
  final String projectPath;
  final String tmuxSessionName;
  final RuntimeSessionStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> taskIds;

  RuntimeSession copyWith({
    RuntimeSessionStatus? status,
    DateTime? updatedAt,
    List<String>? taskIds,
  }) {
    return RuntimeSession(
      id: id,
      name: name,
      projectPath: projectPath,
      tmuxSessionName: tmuxSessionName,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      taskIds: taskIds ?? this.taskIds,
    );
  }
}
