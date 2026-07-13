import 'dart:convert';

import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/loop_quality_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aggregates loop efficiency and acceptance facts', () {
    final task = _task([
      _event(
        LoopEvaluation.metricEventType,
        LoopEvaluation(
          id: 'evaluation-1',
          taskId: 'task-1',
          turnId: 'turn-1',
          turnIndex: 1,
          status: 'turnIdle',
          createdAt: _now,
          metrics: const LoopTurnMetrics(
            inputLength: 100,
            outputSummaryLength: 50,
            approvalCount: 1,
            retryCount: 2,
            waitMs: 4000,
            hasDeliverable: true,
          ),
        ).toJson(),
      ),
      _event(
        LoopUserAction.metricEventType,
        LoopUserAction(
          id: 'action-1',
          taskId: 'task-1',
          kind: LoopUserActionKind.acceptResult,
          createdAt: _now,
          turnId: 'turn-1',
          turnIndex: 1,
          status: 'turnIdle',
        ).toJson(),
      ),
    ]);

    final summary = const LoopQualityAnalyzer().analyze(task);

    expect(summary.evaluatedTurns, 1);
    expect(summary.deliverableTurns, 1);
    expect(summary.acceptanceRate, 1);
    expect(summary.totalApprovals, 1);
    expect(summary.totalRetries, 2);
    expect(summary.averageWaitMs, 4000);
    expect(summary.outputInputRatio, 0.5);
  });
}

final _now = DateTime(2026, 7, 12);

MetricEvent _event(String type, Map<String, Object?> payload) =>
    MetricEvent.create(
      taskId: 'task-1',
      eventType: type,
      payloadJson: jsonEncode(payload),
      now: _now,
    );

TaskSession _task(List<MetricEvent> events) => TaskSession(
      id: 'task-1',
      host: HostConfig(
        id: 'host-1',
        name: 'Local',
        host: '127.0.0.1',
        port: 22,
        username: 'user',
        authType: HostAuthType.password,
        projectPath: '/tmp/project',
        tmuxSessionName: 'armin-1',
        agentCommand: 'qodercli',
        createdAt: _now,
        updatedAt: _now,
      ),
      title: 'Task',
      createdAt: _now,
      updatedAt: _now,
      rawSttText: '',
      cleanedDraft: '',
      userText: '',
      context: '',
      constraints: const {},
      finalPrompt: '',
      secretRecords: const [],
      metricEvents: events,
    );
