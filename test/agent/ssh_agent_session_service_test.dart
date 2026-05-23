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
    expect(command, contains('Armin project path does not exist'));
    expect(command, contains('/tmp/armin'));
    expect(command, contains('Armin Codex exited with status'));
    expect(command, contains('Armin timed out waiting for Codex TUI'));
    expect(command, contains('sleep 3600'));
    expect(command, contains('-C'));
    expect(command, contains('OpenAI Codex'));
    expect(command, contains('directory:'));
    expect(command, contains('Update available!'));
    expect(command, contains('send-keys -t'));
    expect(command, contains('2 Enter'));
    expect(command, contains('load-buffer -'));
    expect(command, contains('paste-buffer -t'));
    expect(command, contains('send-keys -t'));
    expect(command, contains('Enter'));
    expect(command, contains('stable_count'));
    expect(command, contains("'\"'\"'/usr/bin/tmux'\"'\"' capture-pane"));
    expect(command, contains('-S -200'));
    expect(command, isNot(contains('-S -2000')));
  });

  test('connection test command checks tmux and codex availability', () {
    final service = SSHAgentSessionService();

    final command = service.buildConnectionTestCommandForTest(
      const AgentConnectionTestRequest(
        host: '127.0.0.1',
        port: 22,
        username: 'ironion',
        password: 'secret-password',
        tmuxCommand: '/opt/homebrew/bin/tmux',
        agentCommand: '/opt/homebrew/bin/codex',
        pathPrepend: '/opt/homebrew/bin:/usr/local/bin',
        shellWrapper: ShellWrapper.zshLogin,
      ),
    );

    expect(command, startsWith("zsh -lc '"));
    expect(command,
        contains('export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH";'));
    expect(command, contains("'\"'\"'/opt/homebrew/bin/tmux'\"'\"' -V"));
    expect(
        command, contains("command -v '\"'\"'/opt/homebrew/bin/codex'\"'\"'"));
    expect(
        command, contains("'\"'\"'/opt/homebrew/bin/codex'\"'\"' --version"));
    expect(command, contains('npm prefix -g'));
    expect(command, contains('npm global bin: %s/bin'));
  });

  test('connection test command expands home based agent command', () {
    final service = SSHAgentSessionService();

    final command = service.buildConnectionTestCommandForTest(
      const AgentConnectionTestRequest(
        host: '127.0.0.1',
        port: 22,
        username: 'ironion',
        password: 'secret-password',
        agentCommand: r'$HOME/.npm-global/bin/codex',
      ),
    );

    expect(command, contains('command -v "\$HOME"/\'.npm-global/bin/codex\''));
    expect(command, contains('"\$HOME"/\'.npm-global/bin/codex\' --version'));
  });

  test('execution command expands home based agent command', () {
    final service = SSHAgentSessionService();

    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: 'prompt',
        host: '127.0.0.1',
        username: 'ironion',
        projectPath: '/tmp/armin',
        tmuxSessionName: 'armin-codex',
        agentCommand: r'$HOME/.npm-global/bin/codex',
        password: 'secret-password',
      ),
    );

    expect(command, contains('Armin Codex exited with status'));
    expect(command, contains('Armin project path does not exist'));
    expect(command, contains('sleep 3600'));
    expect(command, contains(r'"$HOME"/'));
    expect(command, contains('.npm-global/bin/codex'));
    expect(command, contains('-C'));
  });

  test('execution command expands home based project path', () {
    final service = SSHAgentSessionService();

    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: 'prompt',
        host: '127.0.0.1',
        username: 'ironion',
        projectPath: '~/workspace/momo',
        tmuxSessionName: 'armin-codex',
        agentCommand: 'codex',
        password: 'secret-password',
      ),
    );

    expect(command, contains('"\$HOME"/\'workspace/momo\''));
    expect(command, contains('-C "\$HOME"/'));
    expect(command, contains('workspace/momo'));
  });

  test('path prepend keeps home variable expandable on remote host', () {
    final service = SSHAgentSessionService();

    final command = service.buildRemoteTmuxCommand(
      command: "'tmux' -V",
      pathPrepend: r'$HOME/.npm-global/bin',
    );

    expect(command, contains(r'export PATH="$HOME/.npm-global/bin:$PATH";'));
  });

  test('attach-only execution monitors existing tmux session without prompt',
      () {
    final service = SSHAgentSessionService();

    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-codex',
        tmuxCommand: 'tmux',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    expect(command, contains('has-session'));
    expect(command, contains('capture-pane'));
    expect(command, contains('sleep 1'));
    expect(command, contains('stable_count'));
    expect(command, isNot(contains('initial_markers')));
    expect(command, isNot(contains('marker_count')));
    expect(command, contains('Armin could not capture tmux pane'));
    expect(command, isNot(contains('send-keys -t')));
    expect(command, isNot(contains('new-session -d')));
  });

  test('missing readable result log keeps captured pane output', () {
    final service = SSHAgentSessionService();

    final log = service.missingStructuredResultLogForTest('codex failed\nboom');

    expect(log, contains('SSH session ended without readable result'));
    expect(log, contains('Last captured output:'));
    expect(log, contains('codex failed'));
    expect(log, contains('boom'));
  });

  test('approval decision is sent without runtime update wrapper', () async {
    final service = SSHAgentSessionService();

    const request = AgentControlRequest(
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      tmuxSessionName: 'armin-codex',
      password: 'secret-password',
      instruction: '''
APPROVAL_DECISION:
decision: approved
''',
    );

    final update = service.buildFollowUpTextForTest(request);

    expect(update, startsWith('APPROVAL_DECISION:'));
    expect(update, isNot(contains('RUNTIME_UPDATE:')));
  });
}
