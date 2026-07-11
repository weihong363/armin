import 'dart:convert';

import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/ai/services/slm_client.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/loop_evaluation_assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses native SLM with structured loop facts', () async {
    final client = _FakeSlmClient(
      response: '本轮已有结果，需要用户验收；没有阻塞；可按结果继续下一轮。',
    );
    final assistant = LoopEvaluationAssistant(client: client);

    final summary = await assistant.evaluate(
      _task(
        deliverableSummary: '已完成 README 更新，测试通过。',
        rawOutput: 'RAW_PROMPT_ECHO_SHOULD_NOT_LEAK',
      ),
      runtimeStatus: 'turnIdle',
    );

    expect(summary.usedAi, isTrue);
    expect(summary.source, 'native_slm');
    expect(summary.text, contains('需要用户验收'));
    expect(client.lastPrompt, contains('结构化事实'));
    expect(client.lastPrompt, contains('已完成 README 更新'));
    expect(
        client.lastPrompt, isNot(contains('RAW_PROMPT_ECHO_SHOULD_NOT_LEAK')));
  });

  test('falls back when native SLM is unavailable', () async {
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(deliverableSummary: '已完成项目简介。'),
      runtimeStatus: 'turnIdle',
    );

    expect(summary.usedAi, isFalse);
    expect(summary.source, 'rules');
    expect(summary.text, contains('本轮已有正式结果'));
  });

  test('does not evaluate completion while task is still running', () async {
    final client = _FakeSlmClient(available: true);
    final assistant = LoopEvaluationAssistant(
      client: client,
    );

    final summary = await assistant.evaluate(
      _task(deliverableSummary: null),
      runtimeStatus: 'running',
    );

    expect(summary.usedAi, isFalse);
    expect(summary.text, contains('任务仍在执行'));
    expect(client.generateCount, 0);
  });

  test('fallback highlights pending approval facts', () async {
    final now = DateTime(2026, 7, 6);
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(
        deliverableSummary: '等待审批后继续。',
        metricEvents: [
          MetricEvent.create(
            taskId: 'task-1',
            eventType: LoopApprovalEvent.metricEventType,
            payloadJson: jsonEncode(
              LoopApprovalEvent(
                id: 'approval-event-1',
                taskId: 'task-1',
                approvalId: 'approval-1',
                kind: LoopApprovalEventKind.requested,
                createdAt: now,
                turnId: 'turn-1',
                turnIndex: 1,
                status: 'needApproval',
              ).toJson(),
            ),
            now: now,
          ),
        ],
      ),
      runtimeStatus: 'needApproval',
    );

    expect(summary.usedAi, isFalse);
    expect(summary.text, contains('待处理审批'));
  });

  test('allows low-risk next action to auto execute in aggressive mode',
      () async {
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(
        deliverableSummary: '已实现倒计时组件交互和状态更新。',
        approvalMode: AgentApprovalMode.aggressive,
      ),
      runtimeStatus: 'turnIdle',
    );

    expect(summary.nextAction?.id, 'request_test_evidence');
    expect(summary.nextAction?.policy, LoopNextActionPolicy.autoAllowed);
    expect(summary.nextAction?.canAutoExecute, isTrue);
  });

  test('keeps low-risk next action assisted in balanced mode', () async {
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(
        deliverableSummary: '已实现倒计时组件交互和状态更新。',
        approvalMode: AgentApprovalMode.balanced,
      ),
      runtimeStatus: 'turnIdle',
    );

    expect(summary.nextAction?.id, 'request_test_evidence');
    expect(summary.nextAction?.policy, LoopNextActionPolicy.assisted);
    expect(summary.nextAction?.canAutoExecute, isFalse);
  });

  test('requires confirmation for blockers even in aggressive mode', () async {
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(
        deliverableSummary: '执行失败，permission denied，当前被权限问题阻塞。',
        approvalMode: AgentApprovalMode.aggressive,
      ),
      runtimeStatus: 'turnIdle',
    );

    expect(summary.nextAction?.id, 'resolve_blocker');
    expect(
      summary.nextAction?.policy,
      LoopNextActionPolicy.confirmationRequired,
    );
  });

  test('does not propose auto action while task is running', () async {
    final assistant = LoopEvaluationAssistant(
      client: _FakeSlmClient(available: false),
    );

    final summary = await assistant.evaluate(
      _task(deliverableSummary: null),
      runtimeStatus: 'running',
    );

    expect(summary.nextAction, isNull);
  });
}

class _FakeSlmClient implements SlmClient {
  _FakeSlmClient({
    this.available = true,
    this.response = 'ok',
  });

  final bool available;
  final String response;
  String lastPrompt = '';
  int generateCount = 0;

  @override
  Future<SlmCapability> capability({String? modelPath}) async {
    return SlmCapability(
      available: available,
      message: available ? 'ready' : 'missing',
      backend: 'fake',
      modelPath: modelPath,
    );
  }

  @override
  Future<SlmGenerationResponse> generate(SlmGenerationRequest request) async {
    generateCount += 1;
    lastPrompt = request.prompt;
    return SlmGenerationResponse(text: response, backend: 'fake');
  }
}

TaskSession _task({
  required String? deliverableSummary,
  String rawOutput = '',
  List<MetricEvent> metricEvents = const [],
  AgentApprovalMode approvalMode = AgentApprovalMode.aggressive,
}) {
  final now = DateTime(2026, 7, 6);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Local',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-test',
      agentCommand: 'qodercli',
      createdAt: now,
      updatedAt: now,
    ),
    title: '测试任务',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: '测试任务',
    userText: '测试任务',
    context: '',
    constraints: const {},
    finalPrompt: '测试任务',
    secretRecords: const [],
    approvalMode: approvalMode,
    metricEvents: metricEvents,
    turns: [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '完成当前任务',
        rawOutput: rawOutput,
        cleanedOutput: rawOutput,
        startedAt: now,
        lastOutputAt: now,
        status: deliverableSummary == null
            ? NativeOutputTurnStatus.running
            : NativeOutputTurnStatus.turnIdle,
        deliverable: deliverableSummary == null
            ? null
            : TurnDeliverable(
                displaySummary: deliverableSummary,
                speechSummary: deliverableSummary,
                evidenceFingerprint: 'fingerprint-turn-1',
              ),
      ),
    ],
  );
}
