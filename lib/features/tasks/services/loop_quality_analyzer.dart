import 'dart:convert';

import '../models/loop_evaluation.dart';
import '../models/task_session.dart';

class LoopQualitySummary {
  const LoopQualitySummary({
    required this.evaluatedTurns,
    required this.deliverableTurns,
    required this.acceptedResults,
    required this.redoCount,
    required this.totalApprovals,
    required this.totalRetries,
    required this.averageWaitMs,
    required this.outputInputRatio,
  });

  final int evaluatedTurns;
  final int deliverableTurns;
  final int acceptedResults;
  final int redoCount;
  final int totalApprovals;
  final int totalRetries;
  final int averageWaitMs;
  final double outputInputRatio;

  bool get hasData => evaluatedTurns > 0;
  double get acceptanceRate =>
      deliverableTurns == 0 ? 0 : acceptedResults / deliverableTurns;
  double get redoRate =>
      deliverableTurns == 0 ? 0 : redoCount / deliverableTurns;
}

class LoopQualityAnalyzer {
  const LoopQualityAnalyzer();

  LoopQualitySummary analyze(TaskSession task) {
    var evaluated = 0;
    var deliverables = 0;
    var accepted = 0;
    var redos = 0;
    var approvals = 0;
    var retries = 0;
    var waitMs = 0;
    var inputChars = 0;
    var outputChars = 0;
    for (final event in task.metricEvents) {
      final payload = _payload(event.payloadJson);
      if (event.eventType == LoopEvaluation.metricEventType) {
        final metrics = LoopEvaluation.fromJson(payload).metrics;
        evaluated += 1;
        if (metrics.hasDeliverable) deliverables += 1;
        approvals += metrics.approvalCount;
        retries += metrics.retryCount;
        waitMs += metrics.waitMs;
        inputChars += metrics.inputLength;
        outputChars += metrics.outputSummaryLength;
      } else if (event.eventType == LoopUserAction.metricEventType) {
        final action = LoopUserAction.fromJson(payload);
        if (action.kind == LoopUserActionKind.acceptResult) accepted += 1;
        if (action.kind == LoopUserActionKind.rejectOrRedo) redos += 1;
      }
    }
    return LoopQualitySummary(
      evaluatedTurns: evaluated,
      deliverableTurns: deliverables,
      acceptedResults: accepted,
      redoCount: redos,
      totalApprovals: approvals,
      totalRetries: retries,
      averageWaitMs: evaluated == 0 ? 0 : waitMs ~/ evaluated,
      outputInputRatio: inputChars == 0 ? 0 : outputChars / inputChars,
    );
  }

  Map<String, Object?> _payload(String source) {
    try {
      return jsonDecode(source) as Map<String, Object?>;
    } catch (_) {
      return const {};
    }
  }
}
