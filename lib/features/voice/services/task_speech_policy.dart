import '../../../core/models/task_status.dart';
import '../../tasks/models/task_session.dart';
import 'device_voice_service.dart';

enum TaskSpeechKind {
  result,
  attention,
}

class TaskSpeechSettings {
  const TaskSpeechSettings({
    this.enabled = true,
    this.speakResults = true,
    this.speakAttention = true,
    this.voiceStyle = SpeechVoiceStyle.clearFemale,
  });

  final bool enabled;
  final bool speakResults;
  final bool speakAttention;
  final SpeechVoiceStyle voiceStyle;

  TaskSpeechSettings copyWith({
    bool? enabled,
    bool? speakResults,
    bool? speakAttention,
    SpeechVoiceStyle? voiceStyle,
  }) {
    return TaskSpeechSettings(
      enabled: enabled ?? this.enabled,
      speakResults: speakResults ?? this.speakResults,
      speakAttention: speakAttention ?? this.speakAttention,
      voiceStyle: voiceStyle ?? this.voiceStyle,
    );
  }
}

class TaskSpeechDecision {
  const TaskSpeechDecision({
    required this.shouldSpeak,
    required this.text,
    required this.hash,
    required this.kind,
  });

  const TaskSpeechDecision.skip()
      : shouldSpeak = false,
        text = '',
        hash = '',
        kind = null;

  final bool shouldSpeak;
  final String text;
  final String hash;
  final TaskSpeechKind? kind;
}

class TaskSpeechPolicy {
  const TaskSpeechPolicy({this.maxSentences = 4});

  final int maxSentences;

  TaskSpeechDecision decide({
    required TaskSession previous,
    required TaskSession current,
    required TaskSpeechSettings settings,
  }) {
    if (!settings.enabled) {
      return const TaskSpeechDecision.skip();
    }
    final kind = _kindFor(current.status);
    if (kind == null || !_isKindEnabled(kind, settings)) {
      return const TaskSpeechDecision.skip();
    }
    final speechText = _speechTextFor(current);
    if (speechText.isEmpty) {
      return const TaskSpeechDecision.skip();
    }
    return TaskSpeechDecision(
      shouldSpeak: true,
      text: speechText,
      hash: '${current.status.name}:${_normalize(speechText)}',
      kind: kind,
    );
  }

  String _speechTextFor(TaskSession task) {
    final source = _summarySource(task);
    final cleaned = DeviceVoiceService.cleanSpeechSummary(source);
    final concise = _limitSentences(cleaned);
    return _decorate(task.status, concise).trim();
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
      TaskStatus.completed => '任务已完成。$text',
      TaskStatus.userCompleted => '任务已标记完成。$text',
      TaskStatus.failed => '任务失败。$text。建议先查看失败原因，再决定是否重试',
      TaskStatus.userFailed => '任务已标记失败。$text',
      TaskStatus.runtimeLost => '运行时可能已断开。$text。建议重新连接后确认远端状态',
      TaskStatus.turnIdle => '$text。本轮输出已暂停，可以继续补充指令',
      TaskStatus.needAttention => '当前需要处理。$text',
      TaskStatus.needApproval => '需要你确认一个操作。$text',
      TaskStatus.observerDetached => '已断开手机监听。远端任务可能仍在运行',
      _ => text,
    };
  }

  String _limitSentences(String text) {
    final parts = text
        .split(RegExp(r'(?<=[。！？.!?])\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .take(maxSentences)
        .toList(growable: false);
    return parts.join('');
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
      TaskStatus.observerDetached ||
      TaskStatus.needApproval =>
        TaskSpeechKind.attention,
      _ => null,
    };
  }

  bool _isKindEnabled(TaskSpeechKind kind, TaskSpeechSettings settings) {
    return switch (kind) {
      TaskSpeechKind.result => settings.speakResults,
      TaskSpeechKind.attention => settings.speakAttention,
    };
  }

  String _normalize(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }
}
