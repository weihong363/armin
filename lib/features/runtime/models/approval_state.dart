/// Explicit approval lifecycle state for runtime reliability.
///
/// Separates native terminal approvals from workflow review decisions.
enum ApprovalState {
  /// No pending approval.
  none,

  /// Approval requested, awaiting user action.
  pending,

  /// User action sent to terminal, awaiting runtime confirmation.
  resolving,

  /// Approval confirmed resolved by runtime.
  resolved,

  /// Approval action failed (terminal error, timeout, etc.).
  failed,
}

/// A native terminal approval request (CLI interactive prompt).
///
/// Examples: "Allow Once", "Allow Session", "Reject", "Confirm".
/// These interact directly with terminal prompts via tmux send-keys.
class NativeTerminalApproval {
  const NativeTerminalApproval({
    required this.id,
    required this.taskId,
    required this.question,
    required this.options,
    required this.state,
    required this.createdAt,
    this.stateChangedAt,
    this.selectedOptionKey,
    this.failureReason,
  });

  final String id;
  final String taskId;
  final String question;
  final List<NativeApprovalOption> options;
  final ApprovalState state;
  final DateTime createdAt;
  final DateTime? stateChangedAt;
  final String? selectedOptionKey;
  final String? failureReason;

  NativeTerminalApproval copyWith({
    String? id,
    String? taskId,
    String? question,
    List<NativeApprovalOption>? options,
    ApprovalState? state,
    DateTime? createdAt,
    DateTime? stateChangedAt,
    String? selectedOptionKey,
    String? failureReason,
  }) {
    return NativeTerminalApproval(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      question: question ?? this.question,
      options: options ?? this.options,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      stateChangedAt: stateChangedAt ?? this.stateChangedAt,
      selectedOptionKey: selectedOptionKey ?? this.selectedOptionKey,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'task_id': taskId,
      'question': question,
      'options': options.map((o) => o.toJson()).toList(),
      'state': state.name,
      'created_at': createdAt.toIso8601String(),
      'state_changed_at': stateChangedAt?.toIso8601String(),
      'selected_option_key': selectedOptionKey,
      'failure_reason': failureReason,
    };
  }

  factory NativeTerminalApproval.fromJson(Map<String, Object?> json) {
    final optionsList = json['options'];
    return NativeTerminalApproval(
      id: json['id'] as String? ?? '',
      taskId: json['task_id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      options: optionsList is List
          ? optionsList
              .whereType<Map<String, Object?>>()
              .map(NativeApprovalOption.fromJson)
              .toList(growable: false)
          : const [],
      state: ApprovalState.values.firstWhere(
        (s) => s.name == json['state'],
        orElse: () => ApprovalState.pending,
      ),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      stateChangedAt:
          DateTime.tryParse(json['state_changed_at'] as String? ?? ''),
      selectedOptionKey: json['selected_option_key'] as String?,
      failureReason: json['failure_reason'] as String?,
    );
  }
}

class NativeApprovalOption {
  const NativeApprovalOption({
    required this.key,
    required this.label,
  });

  final String key;
  final String label;

  Map<String, Object?> toJson() => {'key': key, 'label': label};

  factory NativeApprovalOption.fromJson(Map<String, Object?> json) {
    return NativeApprovalOption(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
    );
  }
}

/// Workflow review decision types.
enum ReviewDecisionType {
  /// User approves the work output.
  approve,

  /// User requests changes before proceeding.
  requestChanges,

  /// User asks a clarifying question.
  askQuestion,
}

/// A workflow review decision (not a terminal prompt).
///
/// These interact with task workflow — "Approve", "Request Changes", "Ask Question".
class ReviewDecision {
  const ReviewDecision({
    required this.id,
    required this.taskId,
    required this.type,
    required this.message,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final ReviewDecisionType type;
  final String message;
  final DateTime createdAt;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'task_id': taskId,
      'type': type.name,
      'message': message,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory ReviewDecision.fromJson(Map<String, Object?> json) {
    return ReviewDecision(
      id: json['id'] as String? ?? '',
      taskId: json['task_id'] as String? ?? '',
      type: ReviewDecisionType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => ReviewDecisionType.approve,
      ),
      message: json['message'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
