import 'dart:convert';

import '../../ai/services/native_slm_client.dart';
import '../../ai/services/slm_client.dart';
import '../models/loop_evaluation.dart';
import '../models/metric_event.dart';
import '../models/task_session.dart';

class LoopEvaluationSummary {
  const LoopEvaluationSummary({
    required this.text,
    required this.source,
    required this.usedAi,
  });

  final String text;
  final String source;
  final bool usedAi;
}

class LoopEvaluationAssistant {
  const LoopEvaluationAssistant({
    SlmClient client = const NativeSlmClient(),
    this.maxSummaryChars = 1600,
  }) : _client = client;

  final SlmClient _client;
  final int maxSummaryChars;

  Future<LoopEvaluationSummary> evaluate(
    TaskSession task, {
    required String runtimeStatus,
  }) async {
    final facts = _factsFor(task, runtimeStatus: runtimeStatus);
    final fallback = _fallbackFor(facts);
    if (!facts.hasDeliverable) {
      return fallback;
    }
    try {
      final capability = await _client.capability();
      if (!capability.available) {
        return fallback;
      }
      final response = await _client.generate(
        SlmGenerationRequest(
          prompt: _promptFor(facts),
          maxTokens: 256,
          temperature: 0,
        ),
      );
      final text = response.text.trim();
      if (text.isEmpty) {
        return fallback;
      }
      return LoopEvaluationSummary(
        text: _truncate(text, 800),
        source: 'native_slm',
        usedAi: true,
      );
    } catch (_) {
      return fallback;
    }
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
- 不要提出自动执行、自动审批或自动发送 follow-up。
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

  LoopEvaluationSummary _fallbackFor(_LoopEvaluationFacts facts) {
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
    return const LoopEvaluationSummary(
      text: '本轮已有正式结果，建议先验收结果完整性，再决定继续或收尾。',
      source: 'rules',
      usedAi: false,
    );
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return value.substring(value.length - maxChars);
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
