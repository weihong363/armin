class ProjectPathConfig {
  const ProjectPathConfig({
    required this.id,
    required this.name,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
    this.isDefault = false,
  });

  factory ProjectPathConfig.fromJson(Map<String, Object?> json) {
    return ProjectPathConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDefault;

  ProjectPathConfig copyWith({
    String? id,
    String? name,
    String? path,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDefault,
  }) {
    return ProjectPathConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isDefault': isDefault,
    };
  }
}

String normalizeRemoteProjectPath(String value) {
  final trimmed = value.trim();
  if (!trimmed.startsWith('~') || trimmed.startsWith('~/')) {
    return trimmed;
  }
  if (trimmed.length == 1 || trimmed.startsWith('~ ')) {
    return trimmed;
  }
  return '~/${trimmed.substring(1)}';
}
