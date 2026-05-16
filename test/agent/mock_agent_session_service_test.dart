import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/mock_agent_session_service.dart';

void main() {
  test('MockAgentSessionService simulates approval flow', () async {
    final updates = await MockAgentSessionService()
        .execute(
          const AgentExecutionRequest(
            prompt: 'prompt',
            scenario: MockAgentScenario.needApproval,
          ),
        )
        .toList();

    expect(
        updates.any((update) => update.rawOutput.contains('accepted')), true);
    expect(updates.last.approval, isNotNull);
    expect(updates.last.done, true);
  });

  test('MockAgentSessionService simulates failed flow', () async {
    final updates = await MockAgentSessionService()
        .execute(
          const AgentExecutionRequest(
            prompt: 'prompt',
            scenario: MockAgentScenario.failed,
          ),
        )
        .toList();

    expect(updates.last.result, isNotNull);
    expect(updates.last.result!.status, 'failed');
  });
}
