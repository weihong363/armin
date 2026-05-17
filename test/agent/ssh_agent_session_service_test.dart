import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/ssh_agent_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('password auth plan ignores private key material', () {
    final service = SSHAgentSessionService();
    final plan = service.buildAuthPlan(
      password: 'secret-password',
      privateKeyPem: 'not a valid private key',
    );

    expect(plan.identities, isNull);
    expect(plan.onPasswordRequest!(), 'secret-password');
  });

  test('execute fails fast when password is empty', () async {
    final service = SSHAgentSessionService();

    await expectLater(
      service
          .execute(
            const AgentExecutionRequest(
              prompt: 'prompt',
              host: '127.0.0.1',
              username: 'ironion',
              projectPath: '/tmp/armin',
              tmuxSessionName: 'armin-codex',
              agentCommand: 'codex',
            ),
          )
          .toList(),
      throwsArgumentError,
    );
  });

  test('connection test fails fast when password is empty', () async {
    final service = SSHAgentSessionService();

    expect(
      () => service.testConnection(
        const AgentConnectionTestRequest(
          host: '127.0.0.1',
          port: 22,
          username: 'ironion',
          password: '',
        ),
      ),
      throwsArgumentError,
    );
  });
}
