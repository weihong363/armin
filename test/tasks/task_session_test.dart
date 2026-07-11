import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact json keeps turn state and deliverable without large output',
      () {
    final now = DateTime(2026, 7, 7);
    final task = TaskSession(
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
      title: 'Long task',
      createdAt: now,
      updatedAt: now,
      startedAt: now,
      rawSttText: '',
      cleanedDraft: 'Run task',
      userText: 'Run task',
      context: '',
      constraints: const {},
      finalPrompt: 'Run task',
      secretRecords: const [],
      approvalMode: AgentApprovalMode.aggressive,
      turns: [
        NativeOutputTurn(
          id: 'turn-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: 'Run task',
          rawOutput: 'large raw output',
          cleanedOutput: 'large cleaned output',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '最终摘要',
            speechSummary: '最终摘要',
            evidenceFingerprint: 'fingerprint-1',
          ),
        ),
      ],
    );

    final json = task.toCompactJson();
    final turns = json['turns'] as List<Object?>;
    final turn = turns.single as Map<String, Object?>;
    final deliverable = turn['deliverable'] as Map<String, Object?>;

    expect(json.containsKey('rawLog'), isFalse);
    expect(json.containsKey('executionLogs'), isFalse);
    expect(json.containsKey('shortSummary'), isFalse);
    expect(json.containsKey('summary'), isFalse);
    expect(turn['rawOutput'], isEmpty);
    expect(turn['cleanedOutput'], isEmpty);
    expect(turn['status'], NativeOutputTurnStatus.turnIdle.name);
    expect(turn['userInput'], 'Run task');
    expect(deliverable['displaySummary'], '最终摘要');
    expect(deliverable['evidenceFingerprint'], 'fingerprint-1');
  });
}
