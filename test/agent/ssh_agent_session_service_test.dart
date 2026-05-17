import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/ssh_agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
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

  test('default tmux command keeps raw command unwrapped', () {
    final service = SSHAgentSessionService();

    final command = service.buildRemoteTmuxCommand(
      command: "'tmux' attach -t 'armin-codex' || 'tmux' new -s 'armin-codex'",
    );

    expect(
      command,
      "'tmux' attach -t 'armin-codex' || 'tmux' new -s 'armin-codex'",
    );
  });

  test('path prepend and zsh wrapper are applied to remote tmux command', () {
    final service = SSHAgentSessionService();

    final command = service.buildRemoteTmuxCommand(
      command: "'tmux' attach -t 'armin-codex' || 'tmux' new -s 'armin-codex'",
      pathPrepend: '/opt/homebrew/bin:/usr/local/bin',
      shellWrapper: ShellWrapper.zshLogin,
    );

    expect(command, startsWith("zsh -lc '"));
    expect(
      command,
      contains('export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH";'),
    );
    expect(command, contains("'\"'\"'tmux'\"'\"' attach"));
  });

  test('execution command uses absolute tmux path and sh wrapper', () {
    final service = SSHAgentSessionService();

    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: 'prompt',
        host: '127.0.0.1',
        username: 'ironion',
        projectPath: '/tmp/armin',
        tmuxSessionName: 'armin-codex',
        agentCommand: 'codex',
        password: 'secret-password',
        tmuxCommand: '/usr/bin/tmux',
        shellWrapper: ShellWrapper.shLogin,
      ),
    );

    expect(command, startsWith("sh -lc '"));
    expect(command, contains("'\"'\"'/usr/bin/tmux'\"'\"' has-session"));
    expect(command, contains("'\"'\"'/usr/bin/tmux'\"'\"' capture-pane"));
  });
}
