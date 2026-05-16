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
}
