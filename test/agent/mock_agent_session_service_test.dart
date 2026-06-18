import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agent/services/mock_agent_session_service.dart';

void main() {
  test('MockAgentSessionService executes successfully', () async {
    final updates = await MockAgentSessionService()
        .execute(
          const AgentExecutionRequest(
            prompt: 'prompt',
          ),
        )
        .toList();

    expect(
        updates.any((update) => update.rawOutput.contains('accepted')), true);
    expect(updates.last.cleanedOutput, 'Mock Phase 1 execution completed.');
    expect(updates.last.done, true);
  });
}
