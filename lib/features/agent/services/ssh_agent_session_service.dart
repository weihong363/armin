import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../hosts/models/host_config.dart';
import '../../tasks/services/agent_instruction_discovery.dart';
import '../models/agent_approval_config.dart';
import '../parsers/approval_parser.dart';
import '../parsers/approval_request.dart';
import '../parsers/terminal_prompt.dart';
import '../parsers/terminal_prompt_parser.dart';
import 'agent_session_service.dart';
import 'agent_runtime_config.dart';
import 'codex_output_cleaner.dart';
import 'native_output_observer.dart';
import 'runtime_policy.dart';

class SSHAgentSessionService implements AgentSessionService {
  SSHAgentSessionService({
    ApprovalParser? approvalParser,
    TerminalPromptParser terminalPromptParser = const TerminalPromptParser(),
    Duration pollInterval = AgentRuntimeConfig.pollInterval,
    RuntimePolicy runtimePolicy = const RuntimePolicy(),
    CodexOutputCleaner cleaner = const CodexOutputCleaner(),
  })  : _approvalParser = approvalParser ?? const ApprovalParser(),
        _terminalPromptParser = terminalPromptParser,
        _pollInterval = pollInterval,
        _runtimePolicy = runtimePolicy,
        _cleaner = cleaner;

  final ApprovalParser _approvalParser;
  final TerminalPromptParser _terminalPromptParser;
  final Duration _pollInterval;
  final RuntimePolicy _runtimePolicy;
  final CodexOutputCleaner _cleaner;
  AgentApprovalConfig? _currentApprovalConfig;

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    _validateConnectionTestRequest(request);
    final client = await _connect(
      host: request.host,
      port: request.port,
      username: request.username,
      password: request.password,
    );
    try {
      final output = await client.run(_buildConnectionTestCommand(request));
      final testOutput = utf8.decode(output, allowMalformed: true).trim();
      final success = !testOutput.contains('agent status: missing') &&
          !testOutput.contains('tmux status: missing');

      return AgentConnectionTestResult(
        success: success,
        message: 'SSH connected to ${request.username}@${request.host}.\n'
            '$testOutput',
      );
    } catch (e) {
      final errorMsg = e.toString().toLowerCase();
      if (errorMsg.contains('tmux') || errorMsg.contains('not found')) {
        return const AgentConnectionTestResult(
          success: false,
          message:
              'SSH connected but tmux is not installed on the remote server.\n'
              'Please install tmux: sudo apt install tmux (Ubuntu) or brew install tmux (macOS)',
        );
      }
      if (errorMsg.contains('agent command')) {
        return AgentConnectionTestResult(
          success: false,
          message: 'SSH connected and tmux is available, but agent command '
              'is not available: ${request.agentCommand}.\n'
              'Set Agent command to the absolute CLI path or add its '
              'directory to PATH prepend.',
        );
      }
      rethrow;
    } finally {
      client.close();
      await client.done;
    }
  }

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    _validateInstructionDiscoveryRequest(request);
    const discovery = AgentInstructionDiscovery();
    final script = '''
set -eu
cd ${_pathToken(request.projectPath)}
${discovery.buildFindCommand()} 2>/dev/null || true
''';
    final client = await _connect(
      host: request.host,
      port: request.port,
      username: request.username,
      password: request.password,
    );
    try {
      final output = await client.run(
        _wrapRemoteCommand(
          script,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ),
      );
      return discovery.parse(utf8.decode(output, allowMalformed: true));
    } finally {
      client.close();
      await client.done;
    }
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    _validateExecutionRequest(request);
    _currentApprovalConfig = request.approvalConfig;
    final client = await _connect(
      host: request.host,
      port: request.port,
      username: request.username,
      password: request.password,
      privateKeyPem: request.privateKeyPem,
      privateKeyPassphrase: request.privateKeyPassphrase,
    );

    try {
      final command = _buildExecutionScript(request);
      final session = await client.execute(command);
      final output = _ExecutionOutputState();
      final observer = NativeOutputObserver(
        cleaner: _cleaner,
        idleThreshold: _runtimePolicy.idleThreshold,
        reconnectThreshold: _runtimePolicy.reconnectThreshold,
      );
      late final StreamSubscription<String> stdoutSub;
      late final StreamSubscription<String> stderrSub;
      late final StreamController<AgentExecutionUpdate> controller;

      controller = StreamController<AgentExecutionUpdate>(
        onCancel: () async {
          session.close();
          await stdoutSub.cancel();
          await stderrSub.cancel();
        },
      );

      stdoutSub = session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((text) {
        output.write(text);
        controller.add(_buildStreamingUpdate(text, output, observer));
      });
      stderrSub = session.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((text) {
        output.write(text);
        controller.add(_buildStreamingUpdate(text, output, observer));
      });

      unawaited(
        Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
            .whenComplete(() async {
          if (controller.isClosed) {
            return;
          }
          final streamOutput = output.streamText;
          final observedOutput = output.observedText;
          if (_isMissingTmuxSession(streamOutput)) {
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput: _cleaner.clean(streamOutput),
                observerState: NativeOutputObserverState.runtimeLost,
                runtimeLost: true,
                done: true,
              ),
            );
            await controller.close();
            return;
          }
          if (_isRuntimeLimitReached(streamOutput)) {
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput: _cleaner.clean(streamOutput),
                observerState: NativeOutputObserverState.runtimeLost,
                runtimeLost: true,
                done: true,
              ),
            );
            await controller.close();
            return;
          }
          final approval = _approvalParser.parse(observedOutput);
          final terminalPrompt = _terminalPromptParser.parse(observedOutput);
          final isSafeMode =
              _currentApprovalConfig?.mode == AgentApprovalMode.safe;
          // Bridge native terminal prompts into approval requests so that
          // users see the simplified Approve / Reject card — except in
          // safe mode where the full terminal prompt card is preferred.
          final effectiveApproval = approval ??
              (isSafeMode ? null : _approvalFromTerminalPrompt(terminalPrompt));
          final snapshot = observer.observeSettled(observedOutput);
          controller.add(
            AgentExecutionUpdate(
              rawOutput: '',
              cleanedOutput: snapshot.cleanedOutput,
              observerState: snapshot.state,
              turnIdle: snapshot.turnIdle,
              runtimeLost: snapshot.runtimeLost,
              needsAttention: terminalPrompt != null ||
                  snapshot.needsAttention ||
                  effectiveApproval != null,
              approval: effectiveApproval,
              terminalPrompt: terminalPrompt,
              done: true,
            ),
          );
          await controller.close();
        }),
      );

      yield* controller.stream;
      await session.done;
    } finally {
      client.close();
      await client.done;
    }
  }

  AgentExecutionUpdate _buildStreamingUpdate(
    String chunk,
    _ExecutionOutputState output,
    NativeOutputObserver observer,
  ) {
    final rawOutput = output.rawOutputForLatestUpdate(fallback: chunk);
    final observedOutput = output.observedText;
    final snapshot = observer.observe(observedOutput);
    final terminalPrompt = _terminalPromptParser.parse(observedOutput);
    final approval = _approvalParser.parse(observedOutput);
    final isSafeMode = _currentApprovalConfig?.mode == AgentApprovalMode.safe;
    final effectiveApproval = approval ??
        (isSafeMode ? null : _approvalFromTerminalPrompt(terminalPrompt));
    return AgentExecutionUpdate(
      rawOutput: rawOutput,
      cleanedOutput: snapshot.cleanedOutput,
      observerState: snapshot.state,
      runtimeLost: snapshot.runtimeLost,
      needsAttention: effectiveApproval != null ||
          terminalPrompt != null ||
          snapshot.needsAttention,
      approval: effectiveApproval,
      terminalPrompt: terminalPrompt,
    );
  }

  String _missingResultLog(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) {
      return '\nSSH session ended without readable result.\n';
    }
    return '\nSSH session ended without readable result.\n'
        'Last captured output:\n'
        '$trimmed\n';
  }

  bool _isMissingTmuxSession(String output) {
    return output.contains('Armin could not find tmux session') ||
        output.contains('Armin could not capture tmux pane because session');
  }

  bool _isRuntimeLimitReached(String output) {
    return output.contains('Armin runtime limit reached while session');
  }

  /// Converts a native terminal prompt into an [ApprovalRequest] so the
  /// simplified Approve / Reject card is available even when the legacy
  /// NEED_APPROVAL markers are absent.
  ///
  /// Handles both command-level prompts (where a specific shell command
  /// needs approval) and plan-level prompts (where the agent asks "ready
  /// to proceed?" without a concrete command).
  ApprovalRequest? _approvalFromTerminalPrompt(TerminalPrompt? prompt) {
    if (prompt == null || prompt.question.trim().isEmpty) {
      return null;
    }
    return ApprovalRequest(
      reason: prompt.question,
      command: prompt.command.trim().isEmpty ? 'plan_approval' : prompt.command,
      risk: 'medium',
    );
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _pasteText(request, _buildFollowUpText(request));
  }

  @override
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {
    _validateControlRequest(request);
    if (!RegExp(r'^\d{1,2}$').hasMatch(optionKey)) {
      throw ArgumentError('Terminal prompt option key is invalid.');
    }
    await _sendKeys(request, optionKey);
  }

  String _buildFollowUpText(AgentControlRequest request) {
    final instruction = request.instruction.trimLeft();
    return instruction.startsWith('APPROVAL_DECISION:')
        ? request.instruction
        : request.instruction.trim();
  }

  @override
  Future<void> pause(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _sendRawKeys(request, 'C-z');
  }

  @override
  Future<void> resume(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _sendKeys(request, 'fg');
  }

  @override
  Future<void> interrupt(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _sendRawKeys(request, 'C-c');
  }

  @override
  Future<void> stop(AgentControlRequest request) async {
    _validateControlRequest(request);
    await cleanup(request);
  }

  @override
  Future<void> cleanup(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _killSession(request);
  }

  @override
  Future<String> captureLog(AgentControlRequest request) async {
    _validateControlRequest(request);
    final output = await _runControlCommand(
      request,
      _wrapRemoteCommand(
        _buildCaptureLogCommand(request),
        pathPrepend: request.pathPrepend,
        shellWrapper: request.shellWrapper,
      ),
    );
    return output.trim();
  }

  String _buildCaptureLogCommand(AgentControlRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    return '$tmux capture-pane -p -t '
        '${_shellQuote(request.tmuxSessionName)} '
        '-S -${_runtimePolicy.finalCaptureLines} 2>/dev/null || true';
  }

  Future<SSHClient> _connect({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
  }) async {
    final socket = await SSHSocket.connect(host, port);
    final authPlan = buildAuthPlan(
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
    );
    return SSHClient(
      socket,
      username: username,
      identities: authPlan.identities,
      onPasswordRequest: authPlan.onPasswordRequest,
    );
  }

  @visibleForTesting
  SSHAuthPlan buildAuthPlan({
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
  }) {
    final trimmedPassword = password?.trim() ?? '';
    if (trimmedPassword.isNotEmpty) {
      return SSHAuthPlan(
        onPasswordRequest: () => password!,
      );
    }

    throw ArgumentError('SSH password is required for Phase 2 execution.');
  }

  Future<void> _sendKeys(AgentControlRequest request, String text) async {
    final command = _buildSendKeysCommand(request, text);
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  String _buildSendKeysCommand(AgentControlRequest request, String text) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    return '''
$tmux has-session -t $session
pane="\$($tmux display-message -p -t $session '#{pane_id}')"
$tmux send-keys -t "\$pane" -- ${_shellQuote(text)} C-m
''';
  }

  Future<void> _pasteText(AgentControlRequest request, String text) async {
    final command = _buildPasteTextCommand(request, text);
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  String _buildPasteTextCommand(AgentControlRequest request, String text) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    final clearHistory = text.trimLeft().startsWith('APPROVAL_DECISION:')
        ? '\n$tmux clear-history -t "\$pane"'
        : '';
    return '''
$tmux has-session -t $session
pane="\$($tmux display-message -p -t $session '#{pane_id}')"
$tmux send-keys -t "\$pane" C-u
printf %s ${_shellQuote(text)} | $tmux load-buffer -
$tmux paste-buffer -d -t "\$pane"
sleep 0.2
$tmux send-keys -t "\$pane" C-m$clearHistory
''';
  }

  Future<void> _sendRawKeys(AgentControlRequest request, String key) async {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final command =
        '$tmux send-keys -t ${_shellQuote(request.tmuxSessionName)} '
        '${_shellQuote(key)}';
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  Future<void> _killSession(AgentControlRequest request) async {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final command = '$tmux kill-session -t '
        '${_shellQuote(request.tmuxSessionName)} 2>/dev/null || true';
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  Future<String> _runControlCommand(
    AgentControlRequest request,
    String command,
  ) async {
    final client = await _connect(
      host: request.host,
      port: request.port,
      username: request.username,
      password: request.password,
      privateKeyPem: request.privateKeyPem,
      privateKeyPassphrase: request.privateKeyPassphrase,
    );
    try {
      final output = await client.run(command);
      return utf8.decode(output, allowMalformed: true);
    } finally {
      client.close();
      await client.done;
    }
  }

  String _buildExecutionScript(AgentExecutionRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    final projectPath = _pathToken(request.projectPath);
    final profile = _agentRuntimeProfile(request.agentCommand);
    final agentLaunchCommand = _interactiveAgentLaunchCommand(request);
    final longRunningAgentCommand = _shellQuote(
      '$agentLaunchCommand; code=\$?; echo; '
      'echo "Armin ${profile.label} exited with status \$code."; sleep 3600',
    );
    final prompt = _shellQuote(request.prompt);
    final delayMs = _pollInterval.inMilliseconds;
    final stablePolls = _runtimePolicy.stablePollCount(_pollInterval);
    final maxPolls = _runtimePolicy.maxPollCount(_pollInterval);
    final monitorStart = -_runtimePolicy.monitorCaptureLines;
    final approvalPromptPattern = _approvalPromptPattern(profile);
    final sessionSetup = request.attachOnly
        ? '''
if ! $tmux has-session -t $session 2>/dev/null; then
  echo "Armin could not find tmux session ${_shellQuote(request.tmuxSessionName)}."
  exit 1
fi
'''
        : '''
if [ ! -d $projectPath ]; then
  echo "Armin project path does not exist: ${_shellQuote(request.projectPath)}"
  exit 1
fi
if ! $tmux has-session -t $session 2>/dev/null; then
  $tmux new-session -d -s $session -c $projectPath -- sh -lc $longRunningAgentCommand
fi
i=0
update_prompt_skipped=0
while [ "\$i" -lt 20 ]; do
  ready_output="\$($tmux capture-pane -p -t $session -S $monitorStart 2>/dev/null || true)"
${_buildReadyCheck(profile)}
${_buildUpdatePromptSkip(profile, tmux, session)}
  if printf "%s" "\$ready_output" | grep -q "Armin ${profile.label} exited with status"; then
    printf "%s\\n" "\$ready_output"
    exit 1
  fi
  i=\$((i + 1))
  sleep 1
done
if [ "\$i" -ge 20 ]; then
  printf "%s\\n" "\$ready_output"
  echo "Armin timed out waiting for ${profile.label} TUI to become ready."
  exit 1
fi
''';
    final promptSubmit = request.attachOnly
        ? ''
        : '''
printf %s $prompt | $tmux load-buffer -
$tmux paste-buffer -t $session
sleep 0.2
$tmux send-keys -t $session Enter
''';
    final script = '''
set -eu
$sessionSetup
emit_armin_snapshot() {
  printf "\\n__ARMIN_SNAPSHOT_BEGIN__\\n"
  printf "%s\\n" "\$pane_output"
  printf "__ARMIN_SNAPSHOT_END__\\n"
}
pipe_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/armin-pipe.XXXXXX")"
pipe_file="\$pipe_dir/pane.out"
mkfifo "\$pipe_file"
pane_id="\$($tmux display-message -p -t $session '#{pane_id}')"
cleanup_armin_pipe() {
  $tmux pipe-pane -t "\$pane_id" 2>/dev/null || true
  rm -rf "\$pipe_dir"
}
trap cleanup_armin_pipe EXIT INT TERM
cat "\$pipe_file" &
pipe_cat_pid=\$!
$tmux pipe-pane -t "\$pane_id" 2>/dev/null || true
$tmux pipe-pane -t "\$pane_id" "cat > \\"\$pipe_file\\""
initial_output="\$($tmux capture-pane -p -t $session -S $monitorStart 2>/dev/null || true)"
initial_hash="\$(printf "%s" "\$initial_output" | shasum | awk "{print \\\$1}")"
last_hash="\$initial_hash"
last_emitted_hash="\$initial_hash"
$promptSubmit
stable_count=0
changed_after_start=0
i=0
while [ "\$i" -lt $maxPolls ]; do
  if ! kill -0 "\$pipe_cat_pid" 2>/dev/null; then
    if ! $tmux has-session -t $session 2>/dev/null; then
      echo "Armin could not capture tmux pane because session ${_shellQuote(request.tmuxSessionName)} is not running."
    fi
    break
  fi
  pane_output="\$($tmux capture-pane -p -t $session -S $monitorStart 2>/dev/null || true)"
  if [ -z "\$pane_output" ] && ! $tmux has-session -t $session 2>/dev/null; then
    echo "Armin could not capture tmux pane because session ${_shellQuote(request.tmuxSessionName)} is not running."
    break
  fi
  current_hash="\$(printf "%s" "\$pane_output" | shasum | awk "{print \\\$1}")"
  snapshot_emitted=0
  if [ "\$current_hash" != "\$initial_hash" ]; then
    changed_after_start=1
  fi
  if [ "\$current_hash" = "\$last_hash" ]; then
    stable_count=\$((stable_count + 1))
  else
    stable_count=0
    last_hash="\$current_hash"
  fi
  if [ "\$current_hash" != "\$last_emitted_hash" ]; then
    emit_armin_snapshot
    last_emitted_hash="\$current_hash"
    snapshot_emitted=1
  fi
  agent_exited=0
  if printf "%s" "\$pane_output" | grep -q "Armin ${profile.label} exited with status"; then
    agent_exited=1
  fi
  if [ "\$agent_exited" -eq 1 ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    break
  fi
  if printf "%s" "\$pane_output" | grep -E -i -q ${_shellQuote(approvalPromptPattern)}; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    break
  fi
  if [ "\$changed_after_start" -eq 1 ] && [ "\$stable_count" -ge $stablePolls ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    break
  fi
  if [ "\$i" -eq ${maxPolls - 1} ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    echo "Armin runtime limit reached while session ${_shellQuote(request.tmuxSessionName)} remains active."
    break
  fi
  i=\$((i + 1))
  sleep ${delayMs / 1000}
done
$tmux pipe-pane -t "\$pane_id" 2>/dev/null || true
wait "\$pipe_cat_pid" 2>/dev/null || true
''';
    return _wrapRemoteCommand(
      script,
      pathPrepend: request.pathPrepend,
      shellWrapper: request.shellWrapper,
    );
  }

  String _buildConnectionTestCommand(AgentConnectionTestRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final agentCommand = _commandToken(request.agentCommand);
    final script = '''
set +e
printf "PATH: %s\\n" "\$PATH"
tmux_version="\$($tmux -V 2>&1)"
tmux_status=\$?
if [ "\$tmux_status" -eq 0 ]; then
  printf "tmux status: ok\\n"
  printf "tmux version: %s\\n" "\$tmux_version"
else
  printf "tmux status: missing\\n"
  printf "tmux error: %s\\n" "\$tmux_version"
fi
agent_path="\$(command -v $agentCommand 2>/dev/null)"
agent_status=\$?
if [ "\$agent_status" -eq 0 ]; then
  agent_version="\$($agentCommand --version 2>&1)"
  printf "agent status: ok\\n"
  printf "agent path: %s\\n" "\$agent_path"
  printf "agent version: %s\\n" "\$agent_version"
else
  printf "agent status: missing\\n"
  printf "agent command: %s\\n" ${_shellQuote(request.agentCommand)}
fi
npm_path="\$(command -v npm 2>/dev/null)"
if [ -n "\$npm_path" ]; then
  npm_prefix="\$(npm prefix -g 2>/dev/null)"
  printf "npm path: %s\\n" "\$npm_path"
  printf "npm global prefix: %s\\n" "\$npm_prefix"
  if [ -n "\$npm_prefix" ]; then
    printf "npm global bin: %s/bin\\n" "\$npm_prefix"
  fi
else
  printf "npm status: missing\\n"
fi
''';
    return _wrapRemoteCommand(
      script,
      pathPrepend: request.pathPrepend,
      shellWrapper: request.shellWrapper,
    );
  }

  void _validateExecutionRequest(AgentExecutionRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.tmuxSessionName.trim().isEmpty ||
        request.tmuxCommand.trim().isEmpty ||
        (request.password?.trim().isEmpty ?? true)) {
      throw ArgumentError('SSH execution request is missing required fields.');
    }
    if (!request.attachOnly &&
        (request.projectPath.trim().isEmpty ||
            request.agentCommand.trim().isEmpty ||
            request.prompt.trim().isEmpty)) {
      throw ArgumentError('SSH execution request is missing required fields.');
    }
  }

  void _validateConnectionTestRequest(AgentConnectionTestRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.tmuxCommand.trim().isEmpty ||
        request.agentCommand.trim().isEmpty ||
        request.password.trim().isEmpty) {
      throw ArgumentError('SSH connection test is missing required fields.');
    }
  }

  void _validateInstructionDiscoveryRequest(
    AgentInstructionDiscoveryRequest request,
  ) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.password.trim().isEmpty ||
        request.projectPath.trim().isEmpty) {
      throw ArgumentError(
          'AGENTS.md discovery request is missing required fields.');
    }
  }

  void _validateControlRequest(AgentControlRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.tmuxSessionName.trim().isEmpty ||
        request.tmuxCommand.trim().isEmpty ||
        (request.password?.trim().isEmpty ?? true)) {
      throw ArgumentError('SSH control request is missing required fields.');
    }
  }

  @visibleForTesting
  String buildExecutionCommandForTest(AgentExecutionRequest request) {
    return _buildExecutionScript(request);
  }

  @visibleForTesting
  String buildConnectionTestCommandForTest(AgentConnectionTestRequest request) {
    return _buildConnectionTestCommand(request);
  }

  @visibleForTesting
  String buildFollowUpTextForTest(AgentControlRequest request) {
    return _buildFollowUpText(request);
  }

  @visibleForTesting
  String buildPasteTextCommandForTest(AgentControlRequest request) {
    return _buildPasteTextCommand(request, _buildFollowUpText(request));
  }

  @visibleForTesting
  String buildCaptureLogCommandForTest(AgentControlRequest request) {
    return _buildCaptureLogCommand(request);
  }

  @visibleForTesting
  String buildTerminalOptionCommandForTest(
    AgentControlRequest request,
    String optionKey,
  ) {
    return _buildSendKeysCommand(request, optionKey);
  }

  @visibleForTesting
  String missingStructuredResultLogForTest(String output) {
    return _missingResultLog(output);
  }

  @visibleForTesting
  List<String> rawOutputsForSnapshotsForTest(List<String> snapshots) {
    final output = _ExecutionOutputState();
    return snapshots.map((snapshot) {
      output.write(
        '\n${_ExecutionOutputState.snapshotBeginForTest}\n'
        '$snapshot\n'
        '${_ExecutionOutputState.snapshotEndForTest}\n',
      );
      return output.rawOutputForLatestUpdate(fallback: '');
    }).toList(growable: false);
  }

  @visibleForTesting
  String buildRemoteTmuxCommand({
    required String command,
    String pathPrepend = '',
    ShellWrapper shellWrapper = ShellWrapper.none,
  }) {
    return _wrapRemoteCommand(
      command,
      pathPrepend: pathPrepend,
      shellWrapper: shellWrapper,
    );
  }

  String _wrapRemoteCommand(
    String command, {
    required String pathPrepend,
    required ShellWrapper shellWrapper,
  }) {
    final trimmedPath = pathPrepend.trim();
    final commandWithPath = trimmedPath.isEmpty
        ? command
        : 'export PATH="${_doubleQuoteContent(trimmedPath)}:\$PATH";\n$command';
    return switch (shellWrapper) {
      ShellWrapper.none => commandWithPath,
      ShellWrapper.shLogin => 'sh -lc ${_shellQuote(commandWithPath)}',
      ShellWrapper.zshLogin => 'zsh -lc ${_shellQuote(commandWithPath)}',
    };
  }

  String _tmuxCommand(String value) {
    final command = value.trim().isEmpty ? 'tmux' : value.trim();
    return _shellQuote(command);
  }

  String _agentLaunchCommand(AgentExecutionRequest request) {
    return _commandToken(request.agentCommand);
  }

  String _interactiveAgentLaunchCommand(AgentExecutionRequest request) {
    final profile = _agentRuntimeProfile(request.agentCommand);
    final base = '${_agentLaunchCommand(request)} ${profile.workspaceFlag} '
        '${_pathToken(request.projectPath)}';
    final flags = request.approvalConfig?.launchFlags ?? const [];
    if (flags.isEmpty) return base;
    return '$base ${flags.join(' ')}';
  }

  _AgentRuntimeProfile _agentRuntimeProfile(String agentCommand) {
    final basename = agentCommand.trim().toLowerCase().split('/').last;
    if (basename == 'qoder' || basename == 'qodercli') {
      return const _AgentRuntimeProfile(
        label: 'Qoder',
        workspaceFlag: '-w',
        readyPattern: r'Qoder|qoder|/help|/status|workspace|>',
        approvalPromptPattern:
            r'Permission Required|Apply this change|Allow once|Reject and type something|Approve|Proceed|Continue',
        skipCodexUpdatePrompt: false,
      );
    }
    return const _AgentRuntimeProfile(
      label: 'Codex',
      workspaceFlag: '-C',
      readyPattern: r'OpenAI Codex|directory:',
      approvalPromptPattern:
          r'Permission Required|Apply this change|Allow execution of|Allow command execution|Would you like to run|Asking User|Enter select|Type Something|Allow once|Allow for this session|Reject and type something',
      skipCodexUpdatePrompt: true,
    );
  }

  String _approvalPromptPattern(_AgentRuntimeProfile profile) {
    const genericInteractivePattern =
        r'([0-9]{1,2}[.)][[:space:]]*(Allow|Reject|Approve|Yes|No|Continue|Proceed))|([>❯][[:space:]]*[0-9]{1,2}[.)])|((permission|approval|confirm|allow|reject|proceed|continue).{0,80}[?？])|((waiting for|asking).{0,40}(user|input))';
    return '$genericInteractivePattern|${profile.approvalPromptPattern}';
  }

  String _buildReadyCheck(_AgentRuntimeProfile profile) {
    return '''
  if printf "%s" "\$ready_output" | grep -E -q ${_shellQuote(profile.readyPattern)}; then
    break
  fi
''';
  }

  String _buildUpdatePromptSkip(
    _AgentRuntimeProfile profile,
    String tmux,
    String session,
  ) {
    if (!profile.skipCodexUpdatePrompt) {
      return '';
    }
    return '''
  if [ "\$update_prompt_skipped" -eq 0 ] && printf "%s" "\$ready_output" | grep -q "Update available!"; then
    $tmux send-keys -t $session 2 Enter
    update_prompt_skipped=1
    sleep 1
    continue
  fi
''';
  }

  String _commandToken(String value) {
    return _homeExpandableToken(value.trim());
  }

  String _pathToken(String value) {
    return _homeExpandableToken(value.trim());
  }

  String _homeExpandableToken(String value) {
    final command = value.trim();
    if (command.startsWith(r'$HOME/')) {
      return '"\$HOME"/${_shellQuote(command.substring(6))}';
    }
    if (command.startsWith('~/')) {
      return '"\$HOME"/${_shellQuote(command.substring(2))}';
    }
    return _shellQuote(command);
  }

  String _doubleQuoteContent(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('`', r'\`');
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

class _ExecutionOutputState {
  static const _snapshotBegin = '__ARMIN_SNAPSHOT_BEGIN__';
  static const _snapshotEnd = '__ARMIN_SNAPSHOT_END__';

  @visibleForTesting
  static const snapshotBeginForTest = _snapshotBegin;

  @visibleForTesting
  static const snapshotEndForTest = _snapshotEnd;

  final StringBuffer _stream = StringBuffer();
  String _latestSnapshot = '';
  String _lastRawOutput = '';
  String _lastRawSignature = '';

  void write(String text) {
    _stream.write(text);
    final snapshot = _extractLatestSnapshot(_stream.toString());
    if (snapshot != null) {
      _latestSnapshot = snapshot;
    }
  }

  String get streamText => _stream.toString();

  String get observedText {
    return _latestSnapshot.trim().isEmpty ? streamText : _latestSnapshot;
  }

  String rawOutputForLatestUpdate({required String fallback}) {
    if (_latestSnapshot.trim().isEmpty) {
      return fallback;
    }
    if (_latestSnapshot == _lastRawOutput) {
      return '';
    }
    final signature = _semanticSignature(_latestSnapshot);
    if (signature.isNotEmpty && signature == _lastRawSignature) {
      _lastRawOutput = _latestSnapshot;
      return '';
    }
    final previous = _lastRawOutput;
    _lastRawOutput = _latestSnapshot;
    _lastRawSignature = signature;
    if (previous.isNotEmpty && _latestSnapshot.startsWith(previous)) {
      return _latestSnapshot.substring(previous.length);
    }
    return _latestSnapshot;
  }

  String? _extractLatestSnapshot(String text) {
    final end = text.lastIndexOf(_snapshotEnd);
    if (end < 0) {
      return null;
    }
    final begin = text.lastIndexOf(_snapshotBegin, end);
    if (begin < 0) {
      return null;
    }
    final start = begin + _snapshotBegin.length;
    return text.substring(start, end).trim();
  }

  String _semanticSignature(String snapshot) {
    final withoutAnsi =
        snapshot.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    return withoutAnsi
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !_isVolatileChromeLine(line))
        .join('\n');
  }

  bool _isVolatileChromeLine(String line) {
    final lower = line.toLowerCase();
    return RegExp(r'^[─▄▀█\s]+$').hasMatch(line) ||
        RegExp(r'^[⠁-⣿]\s').hasMatch(line) ||
        lower.contains('thinking...') ||
        lower.contains('esc to cancel') ||
        lower.contains('shift+tab to auto-accept edits') ||
        lower.contains('type your message') ||
        lower.contains('qoder cli') ||
        lower.contains('not login please auth') ||
        lower.startsWith('model · ctx') ||
        lower.startsWith('auto model · ctx') ||
        lower.startsWith('gpt-') ||
        lower.contains('ctx ░') ||
        lower.contains('ctx ');
  }
}

class SSHAuthPlan {
  const SSHAuthPlan({
    this.identities,
    this.onPasswordRequest,
  });

  final List<SSHKeyPair>? identities;
  final String Function()? onPasswordRequest;
}

class _AgentRuntimeProfile {
  const _AgentRuntimeProfile({
    required this.label,
    required this.workspaceFlag,
    required this.readyPattern,
    required this.approvalPromptPattern,
    required this.skipCodexUpdatePrompt,
  });

  final String label;
  final String workspaceFlag;
  final String readyPattern;
  final String approvalPromptPattern;
  final bool skipCodexUpdatePrompt;
}
