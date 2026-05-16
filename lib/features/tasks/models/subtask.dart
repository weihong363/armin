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

  factory Subtask.fromJson(Map<String, Object?> json) {
    return Subtask(
      id: json['id'] as String? ?? '',
      parentTaskId: json['parentTaskId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      status: TaskStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => TaskStatus.pending,
      ),
      workerLabel: json['workerLabel'] as String? ?? '',
      orderIndex: json['orderIndex'] as int? ?? 0,
      summary: json['summary'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? ''),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'parentTaskId': parentTaskId,
      'title': title,
      'status': status.name,
      'workerLabel': workerLabel,
      'orderIndex': orderIndex,
      'summary': summary,
      'createdAt': createdAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
    };
  }
}
