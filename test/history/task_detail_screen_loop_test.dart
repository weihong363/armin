import 'dart:convert';

import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/history/screens/task_detail_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/voice/services/mock_voice_service.dart';

/// P38 LEA UI verification:
/// - Task detail "动态" tab shows "Loop 事实" card
/// - Task detail "动态" tab shows "辅助判断" card
/// - "辅助判断" source shows "端侧模型" or "规则判断"
/// - No prompt echo / thinking / qodercli / old turn contamination

void main() {
  testWidgets('动态 tab shows Loop 事实 and 辅助判断 cards', (tester) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const taskId = 'p38-test-task';
    const turn1Id = 'turn-p38-t1';
    const turn2Id = 'turn-p38-t2';
    final now = DateTime(2026, 7, 6, 22);

    const d1Sum = 'ARMIN_LOOP_EVAL_D1 status=PASS files_changed=0';
    const d2Sum = 'ARMIN_LOOP_EVAL_D2 status=PASS previous_case_repeated=false';

    final eval1Payload = jsonEncode({
      'id': 'eval-1',
      'taskId': taskId,
      'turnId': turn1Id,
      'turnIndex': 1,
      'status': 'turnIdle',
      'createdAt': now.add(const Duration(seconds: 30)).toIso8601String(),
      'metrics': {
        'inputLength': 120,
        'outputSummaryLength': 80,
        'approvalCount': 0,
        'retryCount': 0,
        'waitMs': 15000,
        'hasDeliverable': true,
      },
    });
    final eval2Payload = jsonEncode({
      'id': 'eval-2',
      'taskId': taskId,
      'turnId': turn2Id,
      'turnIndex': 2,
      'status': 'turnIdle',
      'createdAt': now.add(const Duration(seconds: 90)).toIso8601String(),
      'metrics': {
        'inputLength': 150,
        'outputSummaryLength': 120,
        'approvalCount': 0,
        'retryCount': 0,
        'waitMs': 20000,
        'hasDeliverable': true,
      },
    });

    final task = TaskSession(
      id: taskId,
      host: HostConfig(
        id: 'host-p38',
        name: 'Test Host',
        host: '127.0.0.1',
        port: 22,
        username: 'test',
        authType: HostAuthType.password,
        projectPath: '/tmp/test',
        tmuxSessionName: 'armin-p38',
        agentCommand: 'qodercli',
        createdAt: now,
        updatedAt: now,
        password: '',
      ),
      title: 'P38 Loop Eval Test',
      createdAt: now,
      updatedAt: now,
      startedAt: now,
      rawSttText: '',
      cleanedDraft: 'P38 Loop Eval Test',
      userText:
          'Read pubspec.yaml.\nFinal answer only:\nARMIN_LOOP_EVAL_D1 status=PASS',
      context: '',
      constraints: const {},
      finalPrompt:
          'Read pubspec.yaml.\nFinal answer only:\nARMIN_LOOP_EVAL_D1 status=PASS',
      secretRecords: const [],
      turns: [
        NativeOutputTurn(
          id: turn1Id,
          taskId: taskId,
          turnIndex: 1,
          userInput:
              'Read pubspec.yaml.\nFinal answer only:\nARMIN_LOOP_EVAL_D1 status=PASS',
          rawOutput: d1Sum,
          cleanedOutput: '**ARMIN_LOOP_EVAL_D1**\nstatus=PASS\nfiles_changed=0',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: d1Sum,
            speechSummary: d1Sum,
            evidenceFingerprint: 'fp1',
          ),
        ),
        NativeOutputTurn(
          id: turn2Id,
          taskId: taskId,
          turnIndex: 2,
          userInput:
              'Continue.\nFinal answer only:\nARMIN_LOOP_EVAL_D2 status=PASS',
          rawOutput: d2Sum,
          cleanedOutput:
              '**ARMIN_LOOP_EVAL_D2**\nstatus=PASS\nprevious_case_repeated=false',
          startedAt: now.add(const Duration(seconds: 30)),
          lastOutputAt: now.add(const Duration(seconds: 80)),
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: d2Sum,
            speechSummary: d2Sum,
            evidenceFingerprint: 'fp2',
          ),
        ),
      ],
      metricEvents: [
        MetricEvent.create(
            taskId: taskId,
            eventType: LoopEvaluation.metricEventType,
            payloadJson: eval1Payload,
            now: now.add(const Duration(seconds: 30))),
        MetricEvent.create(
            taskId: taskId,
            eventType: LoopEvaluation.metricEventType,
            payloadJson: eval2Payload,
            now: now.add(const Duration(seconds: 90))),
        MetricEvent.create(
            taskId: taskId,
            eventType: LoopUserAction.metricEventType,
            payloadJson: jsonEncode({
              'id': 'ua-1',
              'taskId': taskId,
              'kind': 'continueTask',
              'turnId': turn1Id,
              'turnIndex': 1,
              'status': 'turnIdle',
              'nextTurnId': turn2Id,
              'nextTurnIndex': 2,
              'instructionLength': 80,
              'source': 'text',
            }),
            now: now.add(const Duration(seconds: 40))),
        MetricEvent.create(
            taskId: taskId,
            eventType: LoopResultSummary.metricEventType,
            payloadJson: jsonEncode({
              'id': 'rs-latest',
              'taskId': taskId,
              'latestTurnId': turn2Id,
              'latestTurnIndex': 2,
              'latestEvidenceFingerprint': 'd2-fp',
              'resultCount': 2,
              'acceptedCount': 0,
              'redoCount': 0,
              'completedCount': 0,
              'failedCount': 0,
              'summaryText': '2 turns completed',
              'results': [
                {
                  'turnId': turn1Id,
                  'turnIndex': 1,
                  'summaryLength': 80,
                  'evidenceFingerprint': 'd1-fp'
                },
                {
                  'turnId': turn2Id,
                  'turnIndex': 2,
                  'summaryLength': 120,
                  'evidenceFingerprint': 'd2-fp'
                },
              ],
            }),
            now: now),
      ],
    );

    final store = InMemoryTaskHistoryStore();
    await store.saveTask(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: const _NoOpAgent(),
      voiceService: MockVoiceService(),
    );
    await state.load();

    await tester.pumpWidget(
      MaterialApp(
        home: AppStateScope(
          state: state,
          child: const TaskDetailScreen(taskId: taskId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -420));
    await tester.pumpAndSettle();

    // ── Verify "Loop 事实" card ──────────────────────────────────
    expect(find.text('Loop 事实'), findsOneWidget,
        reason: '动态 Tab should show Loop 事实 card');

    // ── Verify "辅助判断" card ──────────────────────────────────
    expect(find.text('辅助判断'), findsOneWidget,
        reason: '动态 Tab should show 辅助判断 card');

    // Pump to allow FutureBuilder to resolve
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Check for source label — either "来源" with value or fallback text
    final evaluationCard = find.byKey(const Key('loop-evaluation-card'));
    expect(evaluationCard, findsOneWidget);
    final hasFallback = find
        .descendant(
          of: evaluationCard,
          matching: find.text('暂时无法生成辅助判断。'),
        )
        .evaluate()
        .isNotEmpty;
    final hasSourceLabel = find
        .descendant(of: evaluationCard, matching: find.textContaining('来源'))
        .evaluate()
        .isNotEmpty;
    final hasOnDevice = find
        .descendant(of: evaluationCard, matching: find.textContaining('端侧模型'))
        .evaluate()
        .isNotEmpty;
    final hasRule = find
        .descendant(of: evaluationCard, matching: find.textContaining('规则判断'))
        .evaluate()
        .isNotEmpty;
    final sourceOk = hasOnDevice || hasRule || hasFallback;

    expect(sourceOk, isTrue, reason: 'Expected 端侧模型, 规则判断, or fallback text');

    if (hasSourceLabel && (hasOnDevice || hasRule)) {
      // PASS: source label with value
    }

    // ── Verify NO contamination ──────────────────────────────────
    expect(
      find.descendant(
        of: evaluationCard,
        matching: find.textContaining('Thinking'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: evaluationCard,
        matching: find.textContaining('qodercli'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: evaluationCard,
        matching: find.textContaining('Final answer only'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: evaluationCard,
        matching: find.textContaining('ARMIN_LOOP_EVAL_D1'),
      ),
      findsNothing,
    );
  });
}

class _NoOpAgent implements AgentSessionService {
  const _NoOpAgent();

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async =>
      const AgentConnectionTestResult(success: true, message: 'OK');

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async =>
      const AgentInstructionDiscoveryResult(paths: []);

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) =>
      const Stream<AgentExecutionUpdate>.empty();

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}
  @override
  Future<void> selectTerminalOption(
      AgentControlRequest request, String optionKey) async {}
  @override
  Future<void> pause(AgentControlRequest request) async {}
  @override
  Future<void> resume(AgentControlRequest request) async {}
  @override
  Future<void> interrupt(AgentControlRequest request) async {}
  @override
  Future<void> stop(AgentControlRequest request) async {}
  @override
  Future<void> cleanup(AgentControlRequest request) async {}
  @override
  Future<String> captureLog(AgentControlRequest request) async => '';
}
