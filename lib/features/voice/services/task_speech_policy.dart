import '../../../core/models/task_status.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/services/output_summary_provider.dart';
import '../../tasks/services/turn_output_slicer.dart';
import 'device_voice_service.dart';

enum TaskSpeechKind {
  result,
  attention,
  approval,
}

class TaskSpeechSettings {
  const TaskSpeechSettings({
    this.enabled = true,
    this.speakResults = true,
    this.speakAttention = true,
    this.speakApprovalRequests = true,
    this.voiceStyle = SpeechVoiceStyle.clearFemale,
    this.preferLocalSummaryModel = false,
  });

  final bool enabled;
  final bool speakResults;
  final bool speakAttention;
  final bool speakApprovalRequests;
  final SpeechVoiceStyle voiceStyle;
  final bool preferLocalSummaryModel;

  TaskSpeechSettings copyWith({
    bool? enabled,
    bool? speakResults,
    bool? speakAttention,
    bool? speakApprovalRequests,
    SpeechVoiceStyle? voiceStyle,
    bool? preferLocalSummaryModel,
  }) {
    return TaskSpeechSettings(
      enabled: enabled ?? this.enabled,
      speakResults: speakResults ?? this.speakResults,
      speakAttention: speakAttention ?? this.speakAttention,
      speakApprovalRequests:
          speakApprovalRequests ?? this.speakApprovalRequests,
      voiceStyle: voiceStyle ?? this.voiceStyle,
      preferLocalSummaryModel:
          preferLocalSummaryModel ?? this.preferLocalSummaryModel,
    );
  }
}

class TaskSpeechDecision {
  const TaskSpeechDecision({
    required this.shouldSpeak,
    required this.text,
    required this.hash,
    required this.kind,
    this.turnId,
    this.turnIndex,
  });

  const TaskSpeechDecision.skip()
      : shouldSpeak = false,
        text = '',
        hash = '',
        kind = null,
        turnId = null,
        turnIndex = null;

  final bool shouldSpeak;
  final String text;
  final String hash;
  final TaskSpeechKind? kind;
  final String? turnId;
  final int? turnIndex;
}

class TaskSpeechPolicy {
  const TaskSpeechPolicy();

  static const TurnOutputSlicer _turnOutputSlicer = TurnOutputSlicer();

  Future<TaskSpeechDecision> decide({
    required TaskSession previous,
    required TaskSession current,
    required TaskSpeechSettings settings,
    OutputSummaryProvider outputSummaryProvider =
        const RuleBasedOutputSummaryProvider(),
  }) async {
    if (!settings.enabled) {
      return const TaskSpeechDecision.skip();
    }
    final kind = _kindFor(current.status);
    if (kind == null || !_isKindEnabled(kind, settings)) {
      return const TaskSpeechDecision.skip();
    }
    final speechText = await _speechTextFor(
      current,
      outputSummaryProvider: outputSummaryProvider,
    );
    if (speechText.isEmpty) {
      return const TaskSpeechDecision.skip();
    }
    return TaskSpeechDecision(
      shouldSpeak: true,
      text: speechText,
      hash:
          '${current.status.name}:${_latestTurnIndex(current)}:${_normalize(speechText)}',
      kind: kind,
      turnId: current.turns.isEmpty ? null : current.turns.last.id,
      turnIndex: current.turns.isEmpty ? null : _latestTurnIndex(current),
    );
  }

  Future<String> buildSpeechText(
    TaskSession task, {
    OutputSummaryProvider outputSummaryProvider =
        const RuleBasedOutputSummaryProvider(),
  }) {
    return _speechTextFor(task, outputSummaryProvider: outputSummaryProvider);
  }

  Future<String> _speechTextFor(
    TaskSession task, {
    required OutputSummaryProvider outputSummaryProvider,
  }) async {
    final latestTurnText = await _latestTurnSpeechText(
      task,
      outputSummaryProvider: outputSummaryProvider,
    );
    if (latestTurnText.isNotEmpty) {
      return _decorate(task.status, latestTurnText).trim();
    }

    final source = _summarySource(task);
    final summary = await outputSummaryProvider.summarize(
      OutputSummaryRequest(
        cleanedOutput: source,
        status: task.status,
        taskTitle: task.title,
        promptInputs: [
          task.userText,
          ...task.turns.map((turn) => turn.userInput),
        ],
        agentCommand: task.host.agentCommand,
      ),
    );
    final cleaned = _speechTextFromDisplaySummary(summary);
    return _decorate(task.status, cleaned).trim();
  }

  Future<String> _latestTurnSpeechText(
    TaskSession task, {
    required OutputSummaryProvider outputSummaryProvider,
  }) async {
    if (task.turns.isEmpty) {
      return '';
    }
    final current = task.turns.last;
    final source = _turnOutputSlicer.outputForTurn(task.turns, task.turns.length - 1);
    if (source.trim().isEmpty) {
      return '';
    }
    final summary = await outputSummaryProvider.summarize(
      OutputSummaryRequest(
        cleanedOutput: source,
        status: task.status,
        taskTitle: task.title,
        promptInputs: [current.userInput],
        agentCommand: task.host.agentCommand,
      ),
    );
    return _speechTextFromDisplaySummary(summary);
  }

  String _speechTextFromDisplaySummary(OutputSummary summary) {
    final display = summary.displaySummary.trim();
    if (display.isNotEmpty) {
      return DeviceVoiceService.cleanSpeechSummary(display);
    }
    return DeviceVoiceService.cleanSpeechSummary(summary.speechSummary);
  }

  String _summarySource(TaskSession task) {
    final resultSummary = task.result?.summary.trim() ?? '';
    if (resultSummary.isNotEmpty) {
      return resultSummary;
    }
    final summary = task.summary?.trim() ?? '';
    if (summary.isNotEmpty) {
      return summary;
    }
    final shortSummary = task.shortSummary.trim();
    if (shortSummary.isNotEmpty) {
      return shortSummary;
    }
    return task.approval?.reason.trim() ?? '';
  }

  String _decorate(TaskStatus status, String text) {
    return switch (status) {
      TaskStatus.completed => _withDetail('任务已完成', text),
      TaskStatus.userCompleted => _withDetail('任务已标记完成', text),
      TaskStatus.failed => text.isEmpty
          ? '任务失败。建议先查看失败原因，再决定是否重试'
          : '任务失败。$text。建议先查看失败原因，再决定是否重试',
      TaskStatus.userFailed => _withDetail('任务已标记失败', text),
      TaskStatus.runtimeLost => text.isEmpty
          ? '运行时可能已断开。建议重新连接后确认远端状态'
          : '运行时可能已断开。$text。建议重新连接后确认远端状态',
      TaskStatus.turnIdle =>
        text.isEmpty ? '本轮输出已暂停，可以继续补充指令' : '$text。本轮输出已暂停，可以继续补充指令',
      TaskStatus.needAttention => _withDetail('当前需要处理', text),
      TaskStatus.needApproval => _withDetail('需要你确认一个操作', text),
      TaskStatus.observerDetached => '已断开手机监听。远端任务可能仍在运行',
      _ => text,
    };
  }

  String _withDetail(String statusText, String detail) {
    return detail.isEmpty ? '$statusText。' : '$statusText。$detail';
  }

  TaskSpeechKind? _kindFor(TaskStatus status) {
    return switch (status) {
      TaskStatus.completed ||
      TaskStatus.userCompleted ||
      TaskStatus.failed ||
      TaskStatus.userFailed ||
      TaskStatus.runtimeLost =>
        TaskSpeechKind.result,
      TaskStatus.turnIdle ||
      TaskStatus.needAttention ||
      TaskStatus.observerDetached =>
        TaskSpeechKind.attention,
      TaskStatus.needApproval => TaskSpeechKind.approval,
      _ => null,
    };
  }

  bool _isKindEnabled(TaskSpeechKind kind, TaskSpeechSettings settings) {
    return switch (kind) {
      TaskSpeechKind.result => settings.speakResults,
      TaskSpeechKind.attention => settings.speakAttention,
      TaskSpeechKind.approval => settings.speakApprovalRequests,
    };
  }

  String _normalize(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }

  int _latestTurnIndex(TaskSession task) {
    return task.turns.isEmpty ? 0 : task.turns.last.turnIndex;
  }
}
