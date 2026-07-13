import 'dart:async';
import 'dart:convert';

import '../../ai/services/native_slm_client.dart';
import '../../ai/services/slm_client.dart';
import '../models/loop_evaluation.dart';
import '../models/metric_event.dart';
import '../models/task_session.dart';
import 'loop_follow_up_advisor.dart';
import 'loop_runtime_protocol.dart';

class LoopEvaluationSummary {
  const LoopEvaluationSummary({
    required this.text,
    required this.source,
    required this.usedAi,
    this.nextAction,
    this.fallbackReason,
  });

  final String text;
  final String source;
  final bool usedAi;
  final LoopNextAction? nextAction;
  final String? fallbackReason;
}

enum LoopNextActionPolicy {
  manualOnly,
  assisted,
  autoAllowed,
  confirmationRequired,
}

class LoopNextAction {
  const LoopNextAction({
    required this.id,
    required this.title,
    required this.reason,
    required this.draft,
    required this.policy,
  });

  final String id;
  final String title;
  final String reason;
  final String draft;
  final LoopNextActionPolicy policy;

  bool get canAutoExecute => policy == LoopNextActionPolicy.autoAllowed;
}

class LoopEvaluationAssistant {
  const LoopEvaluationAssistant({
    SlmClient client = const NativeSlmClient(),
    LoopActionPolicyGate policyGate = const LoopActionPolicyGate(),
    this.maxSummaryChars = 1600,
  })  : _client = client,
        _policyGate = policyGate;

  final SlmClient _client;
  final LoopActionPolicyGate _policyGate;
  final int maxSummaryChars;

  Future<LoopEvaluationSummary> evaluate(
    TaskSession task, {
    required String runtimeStatus,
  }) async {
    final facts = _factsFor(task, runtimeStatus: runtimeStatus);
    final nextAction = nextActionFor(task, runtimeStatus: runtimeStatus);
    final fallback = _fallbackFor(facts, nextAction: nextAction);
    if (!facts.hasDeliverable) {
      return fallback;
    }
    try {
      final capability = await _client.capability();
      if (!capability.available) {
        return _withFallbackReason(fallback, capability.message);
      }
      final response = await _client.generate(
        SlmGenerationRequest(
          prompt: _promptFor(facts),
          maxTokens: 256,
          temperature: 0,
          // Native decode is opt-in only for this low-frequency, read-only
          // evaluation path. Result summaries and TTS stay rule-based.
          allowUnsafeDecode: true,
        ),
      );
      final text = response.text.trim();
      if (text.isEmpty) {
        return _withFallbackReason(fallback, '端侧模型未返回有效判断。');
      }
      return LoopEvaluationSummary(
        text: _truncate(text, 800),
        source: 'native_slm',
        usedAi: true,
        nextAction: nextAction,
      );
    } on TimeoutException {
      return _withFallbackReason(fallback, '端侧模型响应超时。');
    } catch (_) {
      return _withFallbackReason(fallback, '端侧模型暂时不可用。');
    }
  }

  LoopNextAction? nextActionFor(
    TaskSession task, {
    required String runtimeStatus,
  }) {
    if (runtimeStatus == 'running' || runtimeStatus == 'needApproval') {
      return null;
    }
    final suggestion = const LoopFollowUpAdvisor().suggest(task).firstOrNull;
    if (suggestion == null) {
      return null;
    }
    return LoopNextAction(
      id: suggestion.id,
      title: suggestion.title,
      reason: suggestion.reason,
      draft: suggestion.draft,
      policy: _policyGate.policyFor(task, suggestion),
    );
  }

  LoopNextAction? autopilotNextActionFor(
    TaskSession task, {
    required String runtimeStatus,
  }) {
    if (runtimeStatus == 'running' || runtimeStatus == 'needApproval') {
      return null;
    }
    final deliverable = task.turns.lastOrNull?.deliverable;
    if (deliverable?.loopState != LoopRuntimeOutcomeState.continueWork.name ||
        LoopRuntimeProtocol.isNoAction(deliverable!.loopNextAction)) {
      return null;
    }
    return LoopNextAction(
      id: LoopRuntimeProtocol.autoActionId,
      title: '继续执行',
      reason: 'Agent 按 Loop 协议声明仍有明确下一步。',
      draft: deliverable.loopNextAction,
      policy: _policyGate.policyForProtocol(task),
    );
  }

  _LoopEvaluationFacts _factsFor(
    TaskSession task, {
    required String runtimeStatus,
  }) {
    final latestTurn = task.turns.lastOrNull;
    final deliverable = latestTurn?.deliverable;
    return _LoopEvaluationFacts(
      title: task.displayTitle,
      runtimeStatus: runtimeStatus,
      latestTurnIndex: latestTurn?.turnIndex ?? 0,
      hasDeliverable: deliverable != null,
      deliverableSummary: _truncate(
        deliverable?.displaySummary.trim() ?? '',
        maxSummaryChars,
      ),
      latestEvaluation: _latestLoopEvaluation(task.metricEvents),
      userActionCounts: _countEvents(
        task.metricEvents,
        LoopUserAction.metricEventType,
        field: 'kind',
      ),
      approvalEventCounts: _countEvents(
        task.metricEvents,
        LoopApprovalEvent.metricEventType,
        field: 'kind',
      ),
    );
  }

  LoopEvaluation? _latestLoopEvaluation(List<MetricEvent> events) {
    for (final event in events.reversed) {
      if (event.eventType != LoopEvaluation.metricEventType) continue;
      try {
        return LoopEvaluation.fromJson(
          jsonDecode(event.payloadJson) as Map<String, Object?>,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Map<String, int> _countEvents(
    List<MetricEvent> events,
    String eventType, {
    required String field,
  }) {
    final counts = <String, int>{};
    for (final event in events) {
      if (event.eventType != eventType) continue;
      try {
        final payload = jsonDecode(event.payloadJson) as Map<String, Object?>;
        final key = payload[field] as String? ?? 'unknown';
        counts[key] = (counts[key] ?? 0) + 1;
      } catch (_) {
        counts['invalid'] = (counts['invalid'] ?? 0) + 1;
      }
    }
    return counts;
  }

  String _promptFor(_LoopEvaluationFacts facts) {
    return '''
你是 Armin 的端侧 Loop Evaluation 助手。只基于下列结构化事实判断本轮任务状态。

边界：
- 可以判断是否存在下一轮动作需求，但不要声称你已经执行。
- 自动执行必须由 Runtime Policy Gate 决定；你不能自动审批或越过高风险确认。
- 不要补充事实之外的信息。
- 不要引用 raw terminal、thinking、prompt echo 或旧 turn。
- 输出中文，最多 4 行。

请回答：
1. 当前任务是否看起来已完成或仍需用户验收。
2. 是否存在阻塞或审批风险。
3. 是否建议用户继续下一轮，以及原因。

结构化事实：
${jsonEncode(facts.toJson())}
''';
  }

  LoopEvaluationSummary _fallbackFor(
    _LoopEvaluationFacts facts, {
    LoopNextAction? nextAction,
  }) {
    if (facts.runtimeStatus == 'running' && !facts.hasDeliverable) {
      return const LoopEvaluationSummary(
        text: '任务仍在执行，暂不做完成判断。',
        source: 'rules',
        usedAi: false,
      );
    }
    if (!facts.hasDeliverable) {
      return const LoopEvaluationSummary(
        text: '暂无正式结果，无法进行本轮验收评估。',
        source: 'rules',
        usedAi: false,
      );
    }
    if (facts.approvalEventCounts['requested'] != null &&
        facts.approvalEventCounts['approved'] == null &&
        facts.approvalEventCounts['rejected'] == null) {
      return const LoopEvaluationSummary(
        text: '本轮存在待处理审批，先完成审批后再判断结果。',
        source: 'rules',
        usedAi: false,
      );
    }
    return LoopEvaluationSummary(
      text: '本轮已有正式结果，建议先验收结果完整性，再决定继续或收尾。',
      source: 'rules',
      usedAi: false,
      nextAction: nextAction,
    );
  }

  LoopEvaluationSummary _withFallbackReason(
    LoopEvaluationSummary summary,
    String reason,
  ) {
    final normalized = reason.trim();
    return LoopEvaluationSummary(
      text: summary.text,
      source: summary.source,
      usedAi: summary.usedAi,
      nextAction: summary.nextAction,
      fallbackReason: normalized.isEmpty ? '端侧模型暂时不可用。' : normalized,
    );
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return value.substring(value.length - maxChars);
  }
}

class LoopActionPolicyGate {
  const LoopActionPolicyGate();

  LoopNextActionPolicy policyFor(
    TaskSession task,
    LoopFollowUpSuggestion suggestion,
  ) {
    if (_isDangerous(suggestion.draft)) {
      return LoopNextActionPolicy.confirmationRequired;
    }
    if (_requiresHumanDecision(suggestion.id)) {
      return LoopNextActionPolicy.confirmationRequired;
    }
    return LoopNextActionPolicy.assisted;
  }

  LoopNextActionPolicy policyForProtocol(TaskSession task) =>
      task.approvalMode.name == 'aggressive'
          ? LoopNextActionPolicy.autoAllowed
          : LoopNextActionPolicy.assisted;

  bool _requiresHumanDecision(String suggestionId) {
    return suggestionId == 'resolve_blocker' ||
        suggestionId == 'check_constraints';
  }

  bool _isDangerous(String draft) {
    final lower = draft.toLowerCase();
    const blocked = [
      'git commit',
      'git push',
      '删除',
      'delete ',
      'rm ',
      '安装依赖',
      'install ',
      'brew ',
      'npm install',
      'flutter pub add',
      '修改配置',
      'change config',
    ];
    return blocked.any(lower.contains);
  }
}

class _LoopEvaluationFacts {
  const _LoopEvaluationFacts({
    required this.title,
    required this.runtimeStatus,
    required this.latestTurnIndex,
    required this.hasDeliverable,
    required this.deliverableSummary,
    required this.latestEvaluation,
    required this.userActionCounts,
    required this.approvalEventCounts,
  });

  final String title;
  final String runtimeStatus;
  final int latestTurnIndex;
  final bool hasDeliverable;
  final String deliverableSummary;
  final LoopEvaluation? latestEvaluation;
  final Map<String, int> userActionCounts;
  final Map<String, int> approvalEventCounts;

  Map<String, Object?> toJson() {
    return {
      'title': title,
      'runtimeStatus': runtimeStatus,
      'latestTurnIndex': latestTurnIndex,
      'hasDeliverable': hasDeliverable,
      'deliverableSummary': deliverableSummary,
      'latestEvaluation': latestEvaluation?.toJson(),
      'userActionCounts': userActionCounts,
      'approvalEventCounts': approvalEventCounts,
    };
  }
}
