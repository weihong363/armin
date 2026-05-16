import '../../../core/models/task_status.dart';

class Subtask {
  const Subtask({
    required this.id,
    required this.parentTaskId,
    required this.title,
    required this.status,
    required this.workerLabel,
    required this.orderIndex,
    required this.createdAt,
    this.summary,
    this.completedAt,
  });

  final String id;
  final String parentTaskId;
  final String title;
  final TaskStatus status;
  final String workerLabel;
  final int orderIndex;
  final String? summary;
  final DateTime createdAt;
  final DateTime? completedAt;
}
