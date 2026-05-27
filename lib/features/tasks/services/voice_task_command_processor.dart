import '../../../core/models/task_status.dart';
import '../models/task_constraint.dart';
import 'constraint_extractor.dart';

enum VoiceTaskAction {
  sendInstruction,
  stopTask,
  markCompleted,
  resumeTask,
  reconnectObserver,
}

class VoiceTaskCommandResult {
  const VoiceTaskCommandResult({
    required this.sourceText,
    required this.action,
    required this.instruction,
    required this.constraints,
    required this.label,
    required this.isSemanticMatch,
  });

  final String sourceText;
  final VoiceTaskAction action;
  final String instruction;
  final Set<TaskConstraint> constraints;
  final String label;
  final bool isSemanticMatch;
}

class VoiceTaskCommandProcessor {
  const VoiceTaskCommandProcessor({
    ConstraintExtractor extractor = const ConstraintExtractor(),
  }) : _extractor = extractor;

  final ConstraintExtractor _extractor;

  VoiceTaskCommandResult interpret(String rawText, TaskStatus status) {
    final text = rawText.trim();
    if (text.isEmpty) {
      throw ArgumentError.value(rawText, 'rawText', 'Voice text is empty.');
    }

    final command = _commandKey(text);
    if (_matches(command, const ['停止任务', '停止执行', '停一下', '结束当前任务'])) {
      return _localAction(text, VoiceTaskAction.stopTask, '停止当前任务');
    }
    if (_matches(command, const ['标记完成', '任务完成', '完成任务', '这个任务完成了'])) {
      return _localAction(text, VoiceTaskAction.markCompleted, '标记任务完成');
    }
    if (_matches(
        command, const ['继续', '继续执行', '继续任务', '接着做', '恢复', '恢复任务', '恢复执行'])) {
      return _continuation(text, status);
    }

    final constraints = _extractor.extract(text);
    return VoiceTaskCommandResult(
      sourceText: text,
      action: VoiceTaskAction.sendInstruction,
      instruction: text,
      constraints: constraints,
      label: constraints.isEmpty
          ? '发送追加指令'
          : '追加约束：${constraints.map((item) => item.label).join('、')}',
      isSemanticMatch: constraints.isNotEmpty,
    );
  }

  VoiceTaskCommandResult _continuation(String text, TaskStatus status) {
    return switch (status) {
      TaskStatus.paused =>
        _localAction(text, VoiceTaskAction.resumeTask, '恢复当前任务'),
      TaskStatus.observerDetached =>
        _localAction(text, VoiceTaskAction.reconnectObserver, '重新监听当前任务'),
      _ => VoiceTaskCommandResult(
          sourceText: text,
          action: VoiceTaskAction.sendInstruction,
          instruction: '请继续当前任务。',
          constraints: const {},
          label: '继续当前任务',
          isSemanticMatch: true,
        ),
    };
  }

  VoiceTaskCommandResult _localAction(
    String text,
    VoiceTaskAction action,
    String label,
  ) {
    return VoiceTaskCommandResult(
      sourceText: text,
      action: action,
      instruction: '',
      constraints: const {},
      label: label,
      isSemanticMatch: true,
    );
  }

  bool _matches(String input, List<String> candidates) {
    return candidates.any((candidate) => input == candidate);
  }

  String _commandKey(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'[\s，。！？,.!?]'), '').trim();
  }
}
