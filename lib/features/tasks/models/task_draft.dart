import 'task_constraint.dart';

class TaskDraft {
  const TaskDraft({
    required this.id,
    required this.taskId,
    required this.cleanedText,
    required this.userEditedText,
    required this.contextText,
    required this.constraints,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String taskId;
  final String cleanedText;
  final String userEditedText;
  final String contextText;
  final Set<TaskConstraint> constraints;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory TaskDraft.fromJson(Map<String, Object?> json) {
    return TaskDraft(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      cleanedText: json['cleanedText'] as String? ?? '',
      userEditedText: json['userEditedText'] as String? ?? '',
      contextText: json['contextText'] as String? ?? '',
      constraints: _constraintsFromJson(json['constraints']),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'taskId': taskId,
      'cleanedText': cleanedText,
      'userEditedText': userEditedText,
      'contextText': contextText,
      'constraints': constraints.map((constraint) => constraint.name).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}

Set<TaskConstraint> _constraintsFromJson(Object? value) {
  if (value is! List) {
    return const {};
  }
  return value
      .whereType<String>()
      .map(
        (name) => TaskConstraint.values.firstWhere(
          (constraint) => constraint.name == name,
          orElse: () => TaskConstraint.minimalChange,
        ),
      )
      .toSet();
}
