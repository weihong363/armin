import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/native_output_observer.dart';
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
    expect(command, contains('__ARMIN_SETTLED_CANDIDATE__'));
    expect(command, contains('monitor_version=phase2.6-settled-v8'));
    expect(command, contains('STABLE_POLLS=4'));
    expect(command, contains(r'next if $line =~ /[\x{2800}-\x{28ff}]/;'));
    expect(command, contains(r'stable_count" -ge "$STABLE_POLLS"'));
    expect(command, contains('last_stable_emitted_hash'));
    expect(command, contains(r'current_hash" != "$last_stable_emitted_hash"'));
    expect(command, contains('SKIP_SETTLED_ALREADY_EMITTED'));
    expect(command, contains('Allow execution of|Allow command execution'));
    expect(command, contains('Permission Required'));
    expect(command, contains('permission|approval|confirm|allow|reject'));
    expect(command, contains('ATTENTION_SNAPSHOT'));
    expect(command, isNot(contains('BREAK_ATTENTION')));
    expect(command, contains("'\"'\"'/usr/bin/tmux'\"'\"' capture-pane"));
    expect(command, contains('-S -80'));
    expect(command, isNot(contains('-S -2000')));
    expect(command, contains('runtime limit reached while session'));
    expect(command, isNot(contains('semantic_tail')));
    expect(command, isNot(contains('Analyzing request|Reading project files')));
    expect(command, isNot(contains('Running tests|Finalizing output')));
  });

  test('runtime diagnostics keep only diagnostic lines', () {
    final service = SSHAgentSessionService();

    final lines = service.runtimeDiagnosticLinesForTest('''
__ARMIN_SNAPSHOT_BEGIN__
large user-visible output
ARMIN_DIAG: i=4 cur=abc changed=1 st=4
more snapshot output
ARMIN_DIAG: SETTLED i=4 hash=abc
__ARMIN_SNAPSHOT_END__
''');

    expect(lines, [
      'ARMIN_DIAG: i=4 cur=abc changed=1 st=4',
      'ARMIN_DIAG: SETTLED i=4 hash=abc',
    ]);
    expect(lines.join('\n'), isNot(contains('large user-visible output')));
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
    expect(command, isNot(contains('Approve|Proceed|Continue')));
    expect(command, isNot(contains('proceed|continue')));
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
    expect(command, contains('STABLE_POLLS=4'));
    expect(command, contains(r'stable_count" -ge "$STABLE_POLLS"'));
    expect(command, contains('last_stable_emitted_hash'));
    expect(command, contains('changed_after_start'));
    expect(command, contains('initial_exit_marker_count'));
    expect(command, contains('exit_marker_count'));
    expect(command,
        contains(r'exit_marker_count" -gt "$initial_exit_marker_count'));
    expect(command, contains('initial_attention_marker_count'));
    expect(command, contains('attention_marker_count'));
    expect(
        command,
        contains(
            r'attention_marker_count" -gt "$initial_attention_marker_count'));
    expect(command, contains('__ARMIN_STALE_EXIT_MARKER__'));
    expect(command, isNot(contains('initial_markers')));
    expect(command, contains('Armin could not capture tmux pane'));
    expect(command, isNot(contains('send-keys -t')));
    expect(command, isNot(contains('new-session -d')));
  });

  test('stale exit marker is recognized as a non-result terminal condition',
      () {
    final service = SSHAgentSessionService();

    expect(
      service.staleExitForTest('__ARMIN_STALE_EXIT_MARKER__'),
      isTrue,
    );
    expect(
      service.staleExitForTest('Armin Codex exited with status 0.'),
      isFalse,
    );
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
    expect(execution, contains('STABLE_POLLS=3'));
    expect(execution, contains(r'stable_count" -ge "$STABLE_POLLS"'));
    expect(execution, contains('last_stable_emitted_hash'));
    expect(execution, contains('while [ "\$i" -lt 7 ]'));
    expect(finalCapture, contains('-S -120'));
  });

  test('execution mode configures quiet threshold in monitor script', () {
    final service = SSHAgentSessionService(
      pollInterval: const Duration(seconds: 1),
    );

    final balanced = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-balanced',
        password: 'secret-password',
        attachOnly: true,
        approvalConfig: AgentApprovalConfig(
          agentType: AgentType.codex,
          mode: AgentApprovalMode.balanced,
        ),
      ),
    );
    final aggressive = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-aggressive',
        password: 'secret-password',
        attachOnly: true,
        approvalConfig: AgentApprovalConfig(
          agentType: AgentType.codex,
          mode: AgentApprovalMode.aggressive,
        ),
      ),
    );

    expect(balanced, contains('STABLE_POLLS=10'));
    expect(balanced, contains(r'stable_count" -ge "$STABLE_POLLS"'));
    expect(aggressive, contains('STABLE_POLLS=60'));
    expect(aggressive, contains(r'stable_count" -ge "$STABLE_POLLS"'));
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

  test('probe parser ignores approval prompt followed by newer output', () {
    final service = SSHAgentSessionService();

    final probe = service.parseRemoteTaskProbeForTest('''
Apply this change?

  ❯ 1. Allow once
    2. Reject and type something

> 写 readme，包含所有使用事例

Thinking
 │ The user wants me to write a README.
▪ README.md 已写入。
Armin Codex exited with status 0.
''');

    expect(probe.sessionExists, isTrue);
    expect(probe.needsAttention, isFalse);
    expect(probe.hasExitedMarker, isTrue);
    expect(probe.exitMarkerCount, 1);
  });

  test('probe parser keeps current approval prompt without newer output', () {
    final service = SSHAgentSessionService();

    final probe = service.parseRemoteTaskProbeForTest('''
Apply this change?

  ❯ 1. Allow once
    2. Allow for this session
    3. Modify with external editor
    4. Reject and type something
    5. No
''');

    expect(probe.needsAttention, isTrue);
    expect(probe.hasApprovalPrompt, isTrue);
    expect(probe.hasTerminalPrompt, isTrue);
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

  test('settled candidate turns stable qoder deliverable into turn idle', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ ARMIN_VERIFY_BEGIN case_id=P26-D1 status=PASS ARMIN_VERIFY_END
Credits exhausted. Use /usage for details or /upgrade for more.
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isTrue);
    expect(updates.last.done, isTrue);
    expect(updates.last.runtimeLost, isFalse);
  });

  test('quiet streaming output does not close before settled candidate', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest(
      [
        '''
__ARMIN_SNAPSHOT_BEGIN__
▪ P26-B01-PLAIN-AUTO
Task completed successfully.
__ARMIN_SNAPSHOT_END__
''',
        'ARMIN_DIAG: EMITTING_SETTLED\n',
      ],
      idleThreshold: Duration.zero,
    );

    expect(updates.first.turnIdle, isFalse);
    expect(updates.first.done, isFalse);
    expect(
        updates.first.observerState, NativeOutputObserverState.outputQuieting);
    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
  });

  test('stream completion without settled candidate does not close turn', () {
    final service = SSHAgentSessionService();
    final update = service.streamCompletionUpdateForTextForTest('''
> Armin context governance (aggressive):
  - You have full authority to create, modify, and delete files without asking.
  - Do not interrupt the user — proceed autonomously unless you encounter a hard blocker.

  ## User task
  Read pubspec.yaml and summarize it.

*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''');

    expect(update.turnIdle, isFalse);
    expect(update.done, isFalse);
    expect(update.needsAttention, isFalse);
    expect(update.nativeApproval, isNull);
    expect(update.observerState, isNot(NativeOutputObserverState.turnIdle));
  });

  test('stream completion with unfinished qoder work needs attention', () {
    final service = SSHAgentSessionService();
    final update = service.streamCompletionUpdateForTextForTest('''
▪ Let me read the pubspec.yaml file first to understand the project configuration.

▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines

▪ Let me check the lib/ directory structure to understand the key widgets.

▪ Glob('**/*' within lib/)
  └ Found 2 matching file(s) (Ctrl+O to expand)

▪ Let me check the src/ directory structure to find the actual widget files.

────────────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode                                  Try /model to switch models
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''');

    expect(update.turnIdle, isFalse);
    expect(update.done, isTrue);
    expect(update.needsAttention, isTrue);
    expect(update.nativeApproval, isNull);
    expect(update.observerState, NativeOutputObserverState.needAttention);
  });

  test('stream completion with qoder prompt echo and thinking does not close',
      () {
    final service = SSHAgentSessionService();
    final update = service.streamCompletionUpdateForTextForTest('''
██████                            ╭─ What's new (v1.0.35) ────────────────╮
 ██      ██                          │ - Added plugin marketplace support    │
 ██  ██  ██  Qoder CLI v1.0.34       │ - Upgraded QoderCLI rules types with… │
 ██    ██                            │ - Fixed Plan and Ask tools not being… │
   ████  ██  Not Login Please Auth   │ /release-notes for more               │
                                     ╰───────────────────────────────────────╯
 ● Initializing... Prompts will be queued.
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 > Phase 2.7 real qodercli long task verification.
   Constraints:
   - Do not modify files.
   - Final answer must be in Chinese and include the exact marker
   ARMIN_P27_REAL_TURN1_123.
   Final answer must include these sections:
   1. 项目定位
   2. 技术栈
   6. 下一步建议
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 Credits exhausted. Use /usage for details or /upgrade for more.
 ⠸ Thinking... (esc to cancel, 4s)
────────────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode                           1 MCP server · 15 skills
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 *   Type your message or @path/to/file
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin-test/countdown_widgets
''');

    expect(update.turnIdle, isFalse);
    expect(update.done, isFalse);
    expect(update.observerState, NativeOutputObserverState.running);
  });

  test('settled prompt echo without agent result does not close turn', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
> Armin context governance (aggressive):
  - You have full authority to create, modify, and delete files without asking.

  ## User task
  Summarize this project after inspecting the files.

*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
    expect(
      updates.last.observerState,
      NativeOutputObserverState.outputQuieting,
    );
  });

  test('empty settled candidate does not close the turn', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
IMPORTANT: After completing your current task, you MUST address the user's message
above. Do not ignore it.
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
    expect(
      updates.last.observerState,
      NativeOutputObserverState.outputQuieting,
    );
  });

  test('settled qoder prompt echo with thinking does not close the turn', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
██████                            ╭─ What's new (v1.0.35) ────────────────╮
 ██      ██                          │ - Added plugin marketplace support    │
 ██  ██  ██  Qoder CLI v1.0.34       │ - Upgraded QoderCLI rules types with… │
 ██    ██                            │ - Fixed Plan and Ask tools not being… │
   ████  ██  Not Login Please Auth   │ /release-notes for more               │
                                     ╰───────────────────────────────────────╯
 ● Initializing... Prompts will be queued.
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 > Phase 2.7 real qodercli long task verification.
   Constraints:
   - Do not modify files.
   - Final answer must be in Chinese and include the exact marker
   ARMIN_P27_REAL_TURN1_123.
   Final answer must include these sections:
   1. 项目定位
   2. 技术栈
   6. 下一步建议
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 Credits exhausted. Use /usage for details or /upgrade for more.
 ⠸ Thinking... (esc to cancel, 4s)
────────────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode                           1 MCP server · 15 skills
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 *   Type your message or @path/to/file
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin-test/countdown_widgets
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
    expect(updates.last.observerState, NativeOutputObserverState.running);
  });

  test('settled candidate embedded between diagnostics turns idle', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ P26-B01-PLAIN-AUTO
Task completed successfully.
__ARMIN_SNAPSHOT_END__
''',
      '''
ARMIN_DIAG: EMITTING_SETTLED
ARMIN_DIAG: REUSE_SETTLED_SNAPSHOT i=4 hash=ab1d8d10ad4c
ARMIN_DIAG: BEFORE_SETTLED_CANDIDATE i=4
__ARMIN_SETTLED_CANDIDATE__
ARMIN_DIAG: AFTER_SETTLED_CANDIDATE i=4
''',
    ]);

    expect(updates.last.turnIdle, isTrue);
    expect(updates.last.done, isTrue);
    expect(updates.last.cleanedOutput, contains('P26-B01-PLAIN-AUTO'));
  });

  test('settled candidate ignores stale thinking chrome after final answer',
      () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
Thinking
 │ File read successfully. No modifications needed.
 ▪ ARMIN_VERIFY_BEGIN case_id=P26-D2 status=PASS next_action=COMPLETE ARMIN_VERIFY_END

──────────────────────────────────────────────────────────────────────────
 Auto Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin
 ⠦ Thinking... (esc to cancel, 0s)
 YOLO Shift+Tab to Auto Mode
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isTrue);
    expect(updates.last.done, isTrue);
    expect(updates.last.observerState, NativeOutputObserverState.turnIdle);
    expect(updates.last.cleanedOutput, contains('ARMIN_VERIFY_BEGIN'));
  });

  test('settled candidate keeps in-progress tool work running', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ 测试文件已创建，运行 pytest。

▫ Bash(cd /Users/ironion/workspace/armin-test/file-renamer && python -m pytest test_renamer.py -v 2>&1)

⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
    expect(updates.last.observerState, NativeOutputObserverState.running);
  });

  test('running qoder tool ignores visible input prompt chrome', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ Let me run the requested command.

▫ Bash(sleep 180 && echo LONGTASKC_DONE)

Credits exhausted. Use /usage for details or /upgrade for more.
⠹ Thinking... (esc to cancel, 48s)
────────────────────────────────────────────────────────────────────────────────
YOLO Shift+Tab to Auto Mode
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
*   Type your message or @path/to/file
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates.last.turnIdle, isFalse);
    expect(updates.last.done, isFalse);
    expect(updates.last.needsAttention, isFalse);
    expect(updates.last.nativeApproval, isNull);
    expect(updates.last.observerState, NativeOutputObserverState.running);
  });

  test('later settled candidate can close after earlier active work', () {
    final service = SSHAgentSessionService();
    final updates = service.streamingUpdatesForChunksForTest([
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ Let me inspect the project.
▪ Glob('**/*.{js,ts,json}')
  └ Found 1 matching file(s)
▪ Read(/Users/.../pubspec.yaml)
  └ Read 20 lines
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
      '''
__ARMIN_SNAPSHOT_BEGIN__
▪ 项目结构检查完成，主要入口在 lib/main.dart。
__ARMIN_SNAPSHOT_END__
''',
      '__ARMIN_SETTLED_CANDIDATE__\n',
    ]);

    expect(updates[1].turnIdle, isFalse);
    expect(updates[1].observerState, NativeOutputObserverState.running);
    expect(updates.last.turnIdle, isTrue);
    expect(updates.last.done, isTrue);
    expect(updates.last.cleanedOutput, contains('项目结构检查完成'));
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

  test('stream buffer keeps full content when under limit', () {
    final service = SSHAgentSessionService();
    final limit = service.streamTextLimitForTest;
    final text = 'hello${List.filled(100, 'x').join()}';
    final output = service.streamTextForChunksForTest([text]);

    expect(output.length, text.length);
    expect(output, contains('hello'));
    expect(output.length, lessThan(limit));
  });

  test('stream buffer retains exactly at the boundary', () {
    final service = SSHAgentSessionService();
    final limit = service.streamTextLimitForTest;
    final exactly = List.filled(limit, 'a').join();
    final output = service.streamTextForChunksForTest([exactly]);

    expect(output.length, limit);
    expect(output, exactly);
  });

  test('stream buffer clips when single chunk exceeds limit', () {
    final service = SSHAgentSessionService();
    final limit = service.streamTextLimitForTest;
    final huge = List.filled(limit * 2, 'z').join();
    final output = service.streamTextForChunksForTest([huge]);

    expect(output.length, limit);
    expect(output, huge.substring(huge.length - limit));
  });

  test('stream buffer clips across multiple cumulative chunks', () {
    final service = SSHAgentSessionService();
    final limit = service.streamTextLimitForTest;
    final first = List.filled(limit ~/ 2, 'a').join();
    final over = List.filled(limit ~/ 2 + 100, 'b').join();
    final output = service.streamTextForChunksForTest([first, over]);

    expect(output.length, limit);
    // Combined _streamText+text was clipped from the head by 100 chars,
    // so some 'a's remain before the 'b' tail.
    expect(output, contains('a'));
    expect(output, contains('b'));
    expect(output, endsWith('b'));
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

  // ── Semantic pane inline filter ─────────────────────────────────

  test('script defines armin_pane_hash and _validate_hash', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    expect(command, contains('armin_pane_hash()'));
    expect(command, contains('_validate_hash()'));
    expect(command, contains('command -v perl'));
    expect(command, contains('perl -CSDA -0ne'));
    expect(command, contains('Auto Model'));
    expect(command, contains('ctx'));
    expect(command, contains('Thinking'));
    expect(command, contains(r'\x{2800}-\x{28ff}'));
    expect(command, contains('shasum'));
    expect(command, contains('awk'));
  });

  test('execution monitor is driven by tmux session and capture-pane only', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    expect(command, contains('BREAK_SESSION_LOST'));
    expect(command, contains('BREAK_AGENT_EXITED'));
    expect(command, contains('ATTENTION_SNAPSHOT'));
    expect(command, isNot(contains('BREAK_ATTENTION')));
    expect(command, contains('BREAK_RUNTIME_LIMIT'));
    expect(command, isNot(contains('mkfifo')));
    expect(command, isNot(contains('pipe_cat_pid')));
    expect(command, isNot(contains('pipe-pane')));
  });

  test('settled candidate is not blocked by snapshot emission', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    expect(command, contains(r'current_hash" != "$last_stable_emitted_hash"'));
    expect(command, contains(r'current_hash" != "$last_emitted_hash"'));
    expect(command, contains('SNAPSHOT_BEFORE_SETTLED'));
    expect(command, contains('REUSE_SETTLED_SNAPSHOT'));
    expect(command, contains('BEFORE_SETTLED_CANDIDATE'));
    expect(command, contains('AFTER_SETTLED_CANDIDATE'));
    expect(
        command,
        isNot(contains(
            r'snapshot_emitted" -eq 0 ] && [ "$current_hash" != "$last_stable_emitted_hash"')));
  });

  test('initial and current hash use armin_pane_hash', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    expect(
        command,
        contains(
            'initial_hash="\$(printf "%s" "\$initial_output" | armin_pane_hash)"'));
    expect(
        command,
        contains(
            'current_hash="\$(printf "%s" "\$pane_output" | armin_pane_hash)"'));
  });

  test('pane output never piped directly to shasum', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    // No raw pane output should be piped directly to shasum.
    // All hash computations must go through armin_pane_hash.
    final hashes = [
      'initial_hash',
      'current_hash',
    ];
    for (final hashVar in hashes) {
      final afterHash = command.substring(
        command.indexOf('$hashVar="'),
      );
      // The hash computation line should contain armin_pane_hash.
      final lineEnd = afterHash.indexOf('\n');
      final line = lineEnd > 0 ? afterHash.substring(0, lineEnd) : afterHash;
      expect(line, contains('armin_pane_hash'));
      // It must NOT contain a direct pane-to-shasum pipe.
      expect(line, isNot(contains('pane_output" | shasum')));
      expect(line, isNot(contains('initial_output" | shasum')));
    }
  });

  test('settled candidate marker appears exactly once', () {
    final service = SSHAgentSessionService();
    final command = service.buildExecutionCommandForTest(
      const AgentExecutionRequest(
        prompt: '',
        host: '127.0.0.1',
        username: 'ironion',
        tmuxSessionName: 'armin-2800',
        password: 'secret-password',
        attachOnly: true,
      ),
    );

    // The settled candidate marker should appear only once (the printf line).
    const candidateMarker = '__ARMIN_SETTLED_CANDIDATE__';
    final occurrences = candidateMarker.allMatches(command).length;
    // The marker appears once as the literal string in the bash script.
    expect(occurrences, 1);
  });
}
