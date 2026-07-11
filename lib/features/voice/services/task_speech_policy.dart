import '../../../core/models/task_status.dart';
import '../../runtime/models/approval_state.dart';
import '../../tasks/models/task_session.dart';
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

  Future<TaskSpeechDecision> decide({
    required TaskSession previous,
    required TaskSession current,
    TaskStatus currentStatus = TaskStatus.turnIdle,
    required TaskSpeechSettings settings,
    NativeTerminalApproval? approval,
  }) async {
    if (!settings.enabled) {
      return const TaskSpeechDecision.skip();
    }
    final kind = _kindFor(currentStatus);
    if (kind == null || !_isKindEnabled(kind, settings)) {
      return const TaskSpeechDecision.skip();
    }
    final speechText = _speechTextFor(current, currentStatus, approval);
    if (speechText.isEmpty) {
      return const TaskSpeechDecision.skip();
    }
    return TaskSpeechDecision(
      shouldSpeak: true,
      text: speechText,
      hash: '${currentStatus.name}:'
          '${current.turns.isEmpty ? 'noturn' : current.turns.last.id}:'
          '${speechText.hashCode}',
      kind: kind,
      turnId: current.turns.isEmpty ? null : current.turns.last.id,
      turnIndex: current.turns.isEmpty ? null : _latestTurnIndex(current),
    );
  }

  Future<String> buildSpeechText(
    TaskSession task, {
    TaskStatus status = TaskStatus.turnIdle,
    NativeTerminalApproval? approval,
  }) async =>
      _speechTextFor(task, status, approval);

  String _speechTextFor(
    TaskSession task,
    TaskStatus status,
    NativeTerminalApproval? approval,
  ) {
    if (status == TaskStatus.needApproval) {
      final approvalText = approval?.question.trim() ?? '';
      return _decorate(status, approvalText).trim();
    }

    if (status == TaskStatus.runtimeLost ||
        status == TaskStatus.observerDetached) {
      final latestTurnText = _latestTurnSpeechText(task);
      return _decorate(status, latestTurnText).trim();
    }

    if (status == TaskStatus.needAttention) {
      final promptText = approval?.question.trim() ?? '';
      if (promptText.isNotEmpty) {
        return _decorate(status, promptText).trim();
      }
      final latestTurnText = _latestTurnSpeechText(task);
      return latestTurnText.isEmpty
          ? ''
          : _decorate(status, latestTurnText).trim();
    }

    final latestTurnText = _latestTurnSpeechText(task);
    if (latestTurnText.isNotEmpty) {
      return _decorate(status, latestTurnText).trim();
    }
    return '';
  }

  String _latestTurnSpeechText(TaskSession task) {
    if (task.turns.isEmpty) {
      return '';
    }
    final deliverable = task.turns.last.deliverable;
    if (deliverable == null) return '';
    final speech = deliverable.speechSummary.trim();
    final source = speech.isEmpty ? deliverable.displaySummary : speech;
    return DeviceVoiceService.cleanSpeechText(source);
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
      TaskStatus.completed || TaskStatus.userCompleted => TaskSpeechKind.result,
      TaskStatus.needApproval => TaskSpeechKind.approval,
      TaskStatus.turnIdle ||
      TaskStatus.needAttention ||
      TaskStatus.failed ||
      TaskStatus.userFailed ||
      TaskStatus.runtimeLost ||
      TaskStatus.observerDetached =>
        TaskSpeechKind.attention,
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

  int _latestTurnIndex(TaskSession task) {
    return task.turns.isEmpty ? 0 : task.turns.last.turnIndex;
  }
}
