import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AgentExecutionRequest carries SSH password', () {
    const request = AgentExecutionRequest(
      prompt: 'prompt',
      password: 'secret-password',
    );

    expect(request.password, 'secret-password');
  });
}
