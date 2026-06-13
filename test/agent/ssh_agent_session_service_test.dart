import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/runtime_policy.dart';
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
    expect(command, contains('stable_count" -ge 4'));
    expect(command, contains('last_stable_emitted_hash'));
    expect(command, contains('Allow execution of|Allow command execution'));
    expect(command, contains('Permission Required'));
    expect(command, contains('permission|approval|confirm|allow|reject'));
    expect(command, contains("'\"'\"'/usr/bin/tmux'\"'\"' capture-pane"));
    expect(command, contains('-S -80'));
    expect(command, isNot(contains('-S -2000')));
    expect(command, contains('runtime limit reached while session'));
  });

  test('connection test command checks tmux and agent availability', () {
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
    expect(command, contains('agent status: ok'));
    expect(command, contains('agent status: missing'));
    expect(command, contains('npm prefix -g'));
    expect(command, contains('npm global bin: %s/bin'));
  });

  test('execution command starts qoder with workspace flag', () {
    final service = SSHAgentSessionService();

    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: 'prompt',
        host: '127.0.0.1',
        username: 'ironion',
        projectPath: '/tmp/armin',
        tmuxSessionName: 'armin-codex',
        agentCommand: 'qodercli',
        password: 'secret-password',
      ),
    );

    expect(command, contains("'\"'\"'qodercli'\"'\"' -w "));
    expect(command, isNot(contains("'\"'\"'qodercli'\"'\"' -C ")));
    expect(command, contains('Armin Qoder exited with status'));
    expect(command, contains('Armin timed out waiting for Qoder TUI'));
    expect(command, isNot(contains('Update available!')));
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
    expect(command, contains('sleep 0.5'));
    expect(command, contains('stable_count'));
    expect(command, contains('stable_count" -ge 4'));
    expect(command, contains('last_stable_emitted_hash'));
    expect(command, isNot(contains('initial_markers')));
    expect(command, isNot(contains('marker_count')));
    expect(command, contains('Armin could not capture tmux pane'));
    expect(command, isNot(contains('send-keys -t')));
    expect(command, isNot(contains('new-session -d')));
  });

  test('runtime policy configures quiet threshold runtime and capture windows',
      () {
    final service = SSHAgentSessionService(
      pollInterval: const Duration(seconds: 1),
      runtimePolicy: const RuntimePolicy(
        idleThreshold: Duration(seconds: 3),
        maxRuntime: Duration(seconds: 7),
        monitorCaptureLines: 40,
        finalCaptureLines: 120,
      ),
    );
    const executionRequest = AgentExecutionRequest(
      prompt: '',
      host: '127.0.0.1',
      username: 'ironion',
      tmuxSessionName: 'armin-2800',
      password: 'secret-password',
      attachOnly: true,
    );
    const controlRequest = AgentControlRequest(
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      tmuxSessionName: 'armin-2800',
      password: 'secret-password',
    );

    final execution = service.buildExecutionCommandForTest(executionRequest);
    final finalCapture = service.buildCaptureLogCommandForTest(controlRequest);

    expect(execution, contains('-S -40'));
    expect(execution, contains('stable_count" -ge 3'));
    expect(execution, contains('last_stable_emitted_hash'));
    expect(execution, contains('while [ "\$i" -lt 7 ]'));
    expect(finalCapture, contains('-S -120'));
  });

  test('probe command checks session and captures recent pane only', () {
    final service = SSHAgentSessionService(
      runtimePolicy: const RuntimePolicy(monitorCaptureLines: 40),
    );

    final command = service.buildProbeRemoteStateCommandForTest(
      const AgentControlRequest(
        host: '127.0.0.1',
        port: 22,
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
      ),
    );

    expect(command, contains("has-session -t 'armin-2800'"));
    expect(command, contains("capture-pane -p -t 'armin-2800' -S -40"));
    expect(command, contains('__ARMIN_PROBE_SESSION_MISSING__'));
    expect(command, isNot(contains('send-keys')));
    expect(command, isNot(contains('new-session')));
  });

  test('missing readable result log keeps captured pane output', () {
    final service = SSHAgentSessionService();

    final log = service.missingStructuredResultLogForTest('codex failed\nboom');

    expect(log, contains('SSH session ended without readable result'));
    expect(log, contains('Last captured output:'));
    expect(log, contains('codex failed'));
    expect(log, contains('boom'));
  });

  test('raw snapshot output skips repeated TUI chrome refreshes', () {
    final service = SSHAgentSessionService();
    final outputs = service.rawOutputsForSnapshotsForTest([
      '''
────────────────────────────────────────────────────────────────────────────────
 Shift+Tab to Auto-accept Edits                    1 AGENTS.md file · 12 skills
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 > Armin context governance:
   - Keep edits minimal and focused.
   ## User task
   帮我执行中断测试
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 Auto Model · ctx ░░░░░░░░░░ 0% · ~/workspace/runbook
  ██      ██   Qoder CLI v1.0.11
    ████  ██
 ⠦ Thinking... (esc to cancel, 0s)
''',
      '''
────────────────────────────────────────────────────────────────────────────────
 Shift+Tab to Auto-accept Edits                    1 AGENTS.md file · 12 skills
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 > Armin context governance:
   - Keep edits minimal and focused.
   ## User task
   帮我执行中断测试
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 Auto Model · ctx ░░░░░░░░░░ 0% · ~/workspace/runbook
  ██      ██   Qoder CLI v1.0.11
    ████  ██
 ⠹ Thinking... (esc to cancel, 1s)
''',
    ]);

    expect(outputs.first, contains('帮我执行中断测试'));
    expect(outputs.last, isEmpty);
  });

  test('raw snapshot output keeps semantic changes', () {
    final service = SSHAgentSessionService();
    final outputs = service.rawOutputsForSnapshotsForTest([
      '''
 > Armin context governance:
   ## User task
   帮我执行中断测试
 ⠦ Thinking... (esc to cancel, 0s)
''',
      '''
 > Armin context governance:
   ## User task
   帮我执行中断测试
执行中断测试完成
''',
    ]);

    expect(outputs.first, contains('帮我执行中断测试'));
    expect(outputs.last, contains('执行中断测试完成'));
  });

  test('raw snapshot output detects markers split across chunks', () {
    final service = SSHAgentSessionService();
    final outputs = service.rawOutputsForSnapshotChunksForTest([
      'noise\n__ARMIN_SNA',
      'PSHOT_BEGIN__\nfirst line',
      '\nsecond line\n__ARMIN_SNAPSHOT_',
      'END__\n',
    ]);

    expect(outputs.take(3).every((output) => output.isEmpty), isTrue);
    expect(outputs.last, contains('first line'));
    expect(outputs.last, contains('second line'));
    expect(outputs.last, isNot(contains('noise')));
  });

  test('stream buffer keeps only a bounded tail window', () {
    final service = SSHAgentSessionService();
    final limit = service.streamTextLimitForTest;
    final prefix = 'head${List.filled(limit + 64, 'a').join()}';
    final output = service.streamTextForChunksForTest([
      prefix,
      'tail',
    ]);

    expect(output.length, limit);
    expect(output, endsWith('tail'));
    expect(output, isNot(contains('head')));
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

  test('regular follow-up is sent as clean prompt', () {
    final service = SSHAgentSessionService();

    const request = AgentControlRequest(
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      tmuxSessionName: 'armin-codex',
      password: 'secret-password',
      instruction: '只输出 pets 名字',
    );

    final update = service.buildFollowUpTextForTest(request);

    expect(update, '只输出 pets 名字');
    expect(update, isNot(contains('RUNTIME_UPDATE:')));
    expect(update, isNot(contains('New instruction:')));
  });

  test('follow-up paste targets the active tmux pane and submits with C-m', () {
    final service = SSHAgentSessionService();

    const request = AgentControlRequest(
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      tmuxSessionName: 'armin-2800',
      password: 'secret-password',
      instruction: '输出 hello world',
    );

    final command = service.buildPasteTextCommandForTest(request);

    expect(command, contains('display-message -p -t'));
    expect(command, contains("'#{pane_id}'"));
    expect(command, contains(r'send-keys -t "$pane" C-u'));
    expect(command, contains(r'paste-buffer -d -t "$pane"'));
    expect(
      command,
      contains('paste-buffer -d -t "\$pane"\nsleep 0.2\n'
          '\'tmux\' send-keys -t "\$pane" C-m'),
    );
    expect(command, contains(r'send-keys -t "$pane" C-m'));
    expect(command, contains('输出 hello world'));
  });

  test('terminal prompt option sends the numbered selection and Enter', () {
    final service = SSHAgentSessionService();
    const request = AgentControlRequest(
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      tmuxSessionName: 'armin-2800',
      password: 'secret-password',
    );

    final command = service.buildTerminalOptionCommandForTest(request, '1');

    expect(command, contains("has-session -t 'armin-2800'"));
    expect(command, contains('display-message -p -t'));
    expect(command, contains("'#{pane_id}'"));
    expect(command, contains(r'send-keys -t "$pane"'));
    expect(command, contains("-- '1' C-m"));
  });
}
