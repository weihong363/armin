import '../../../core/models/task_status.dart';
import '../models/task_constraint.dart';
import 'constraint_extractor.dart';

enum VoiceTaskAction {
  sendInstruction,
  stopTask,
  markCompleted,
  readResult,
  resumeTask,
  reconnectObserver,
  selectTerminalOption,
  resolveApprovalRequest,
}

class VoiceTaskCommandResult {
  const VoiceTaskCommandResult({
    required this.sourceText,
    required this.action,
    required this.instruction,
    required this.constraints,
    required this.label,
    required this.isSemanticMatch,
    this.terminalOptionKey,
    this.approvalApproved,
  });

  final String sourceText;
  final VoiceTaskAction action;
  final String instruction;
  final Set<TaskConstraint> constraints;
  final String label;
  final bool isSemanticMatch;
  final String? terminalOptionKey;
  final bool? approvalApproved;
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
    if (_matches(command, const ['读一下结果', '朗读结果', '读结果', '查看结果并朗读'])) {
      return _localAction(text, VoiceTaskAction.readResult, '朗读当前结果');
    }

    final terminalOption = _terminalOptionChoice(command);
    if (status == TaskStatus.needAttention && terminalOption != null) {
      return _approvalResponse(
        text,
        VoiceTaskAction.selectTerminalOption,
        terminalOption.key,
        terminalOption.label,
      );
    }

    final approvalDecision = _approvalDecision(command);
    if (status == TaskStatus.needApproval && approvalDecision != null) {
      return _approvalResponse(
        text,
        VoiceTaskAction.resolveApprovalRequest,
        approvalDecision.approved ? 'approved' : 'rejected',
        approvalDecision.approved ? '批准当前请求' : '拒绝当前请求',
        approvalApproved: approvalDecision.approved,
      );
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

  VoiceTaskCommandResult _approvalResponse(
    String text,
    VoiceTaskAction action,
    String terminalOptionKey,
    String label, {
    bool? approvalApproved,
  }) {
    return VoiceTaskCommandResult(
      sourceText: text,
      action: action,
      instruction: '',
      constraints: const {},
      label: label,
      isSemanticMatch: true,
      terminalOptionKey: terminalOptionKey,
      approvalApproved: approvalApproved,
    );
  }

  _CommandChoice? _terminalOptionChoice(String command) {
    const choices = [
      _CommandChoice(['1', 'allowonce', '允许一次', '这次允许', '只允许一次'],
          '1', '允许一次'),
      _CommandChoice(['2', 'alwaysallow', '始终允许', '永久允许', '以后都允许'],
          '2', '始终允许'),
      _CommandChoice(['3', 'rejectandtypesomething', '拒绝并输入', '拒绝并输入内容'],
          '3', '拒绝并输入内容'),
      _CommandChoice(['4', 'no', '拒绝', '不', '不允许', '不要', '取消'], '4', '拒绝'),
    ];
    for (final choice in choices) {
      if (choice.matches(command)) {
        return choice;
      }
    }
    return null;
  }

  _ApprovalChoice? _approvalDecision(String command) {
    const yesWords = ['批准', '允许', '同意', 'approve', 'yes', '通过'];
    const noWords = ['拒绝', '不允许', '不批准', 'reject', 'no', '取消'];
    if (yesWords.any((word) => command.contains(word))) {
      return const _ApprovalChoice(true);
    }
    if (noWords.any((word) => command.contains(word))) {
      return const _ApprovalChoice(false);
    }
    return null;
  }

  bool _matches(String input, List<String> candidates) {
    return candidates.any((candidate) => input == candidate);
  }

  String _commandKey(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'[\s，。！？,.!?]'), '').trim();
  }
}

class _CommandChoice {
  const _CommandChoice(this.aliases, this.key, this.label);

  final List<String> aliases;
  final String key;
  final String label;

  bool matches(String command) {
    return aliases.any((alias) => command == alias);
  }
}

class _ApprovalChoice {
  const _ApprovalChoice(this.approved);

  final bool approved;
}
