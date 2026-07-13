import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../hosts/models/host_config.dart';
import '../../runtime/models/approval_state.dart';
import '../../tasks/services/agent_instruction_discovery.dart';
import '../parsers/terminal_prompt.dart';
import '../parsers/terminal_prompt_parser.dart';
import 'agent_output_cleaner.dart';
import 'agent_runtime_adapter.dart';
import 'agent_runtime_config.dart';
import 'agent_session_service.dart';
import 'native_output_observer.dart';
import 'runtime_policy.dart';

class SSHAgentSessionService
    implements AgentSessionService, RemoteTaskProbeService {
  static const _staleExitMarker = '__ARMIN_STALE_EXIT_MARKER__';
  static const _probeSessionExistsMarker = '__ARMIN_PROBE_SESSION_EXISTS__';
  static const _probeSessionMissingMarker = '__ARMIN_PROBE_SESSION_MISSING__';
  static const _monitorScriptVersion = 'runtime-monitor-v11';
  static const _monitorDiagnosticsVerbose =
      bool.fromEnvironment('ARMIN_MONITOR_DIAG_VERBOSE');
  static const _controlCommandTimeout = Duration(seconds: 15);
  static const _controlConnectionIdleTimeout = Duration(seconds: 20);

  SSHAgentSessionService({
    TerminalPromptParser terminalPromptParser = const TerminalPromptParser(),
    Duration pollInterval = AgentRuntimeConfig.pollInterval,
    RuntimePolicy runtimePolicy = const RuntimePolicy(),
    AgentOutputCleaner cleaner = const AgentOutputCleaner(),
  })  : _terminalPromptParser = terminalPromptParser,
        _pollInterval = pollInterval,
        _runtimePolicy = runtimePolicy,
        _cleaner = cleaner;

  final TerminalPromptParser _terminalPromptParser;
  final Duration _pollInterval;
  final RuntimePolicy _runtimePolicy;
  final AgentOutputCleaner _cleaner;
  final Map<String, _PooledControlConnection> _controlConnections = {};
  final Map<String, Future<_PooledControlConnection>>
      _controlConnectionCreates = {};

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
      final runtimePolicy = _runtimePolicyFor(request);
      final observer = NativeOutputObserver(
        cleaner: _cleaner,
        runtimeAdapter: AgentRuntimeAdapter.forCommand(request.agentCommand),
        idleThreshold: runtimePolicy.idleThreshold,
        reconnectThreshold: runtimePolicy.reconnectThreshold,
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
        if (controller.isClosed) return;
        _debugPrintRuntimeDiagnostics(text);
        output.write(text);
        final update = _buildStreamingUpdate(text, output, observer);
        controller.add(update);
        if (update.done) {
          session.close();
          unawaited(controller.close());
        }
      });
      stderrSub = session.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((text) {
        if (controller.isClosed) return;
        _debugPrintRuntimeDiagnostics(text);
        output.write(text);
        final update = _buildStreamingUpdate(text, output, observer);
        controller.add(update);
        if (update.done) {
          session.close();
          unawaited(controller.close());
        }
      });

      unawaited(
        Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
            .whenComplete(() async {
          if (controller.isClosed) {
            return;
          }
          final streamOutput = output.streamText;
          final observedOutput = output.observedText;
          if (_isStaleExit(streamOutput)) {
            controller.add(
              const AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput:
                    'Armin observed an old agent exit marker without new output.',
                observerState: NativeOutputObserverState.runtimeLost,
                runtimeLost: true,
                done: true,
              ),
            );
            await controller.close();
            return;
          }
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
            final finalRawOutput =
                output.rawOutputForLatestUpdate(fallback: '');
            final promptState = output.promptState(
              terminalPromptParser: _terminalPromptParser,
              candidateOutput: finalRawOutput,
            );
            final terminalPrompt = promptState.terminalPrompt;
            final snapshot = observer.observeSettled(observedOutput);
            final hasSettledState = snapshot.turnIdle ||
                snapshot.runtimeLost ||
                terminalPrompt != null;
            if (hasSettledState) {
              controller.add(
                AgentExecutionUpdate(
                  rawOutput: '',
                  cleanedOutput: snapshot.cleanedOutput,
                  observerState: snapshot.state,
                  turnIdle: snapshot.turnIdle,
                  runtimeLost: snapshot.runtimeLost,
                  needsAttention: terminalPrompt != null,
                  nativeApproval: _nativeApprovalFromPrompt(terminalPrompt),
                  done: true,
                ),
              );
              await controller.close();
              return;
            }
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
          controller.add(
            _buildStreamCompletionUpdate(
              output: output,
              observer: observer,
              observedOutput: observedOutput,
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
    final settled = output.consumeSettledCandidate();
    final snapshot = settled
        ? observer.observeSettled(observedOutput)
        : observer.observe(observedOutput);
    final promptState = output.promptState(
      terminalPromptParser: _terminalPromptParser,
      candidateOutput: rawOutput,
    );
    final terminalPrompt = snapshot.state == NativeOutputObserverState.running
        ? null
        : promptState.terminalPrompt;
    final hasSettledOutput =
        observer.hasSettledTurnEvidence(snapshot.cleanedOutput);
    final turnIdle = settled && snapshot.turnIdle && hasSettledOutput;
    final observerState =
        snapshot.state == NativeOutputObserverState.turnIdle && !turnIdle
            ? NativeOutputObserverState.outputQuieting
            : snapshot.state;
    return AgentExecutionUpdate(
      rawOutput: rawOutput,
      cleanedOutput: snapshot.cleanedOutput,
      observerState: observerState,
      runtimeLost: snapshot.runtimeLost,
      needsAttention: terminalPrompt != null || snapshot.needsAttention,
      nativeApproval: _nativeApprovalFromPrompt(terminalPrompt),
      turnIdle: turnIdle,
      done: turnIdle ||
          snapshot.runtimeLost ||
          snapshot.needsAttention ||
          terminalPrompt != null,
    );
  }

  AgentExecutionUpdate _buildStreamCompletionUpdate({
    required _ExecutionOutputState output,
    required NativeOutputObserver observer,
    required String observedOutput,
  }) {
    final finalRawOutput = output.rawOutputForLatestUpdate(fallback: '');
    final promptState = output.promptState(
      terminalPromptParser: _terminalPromptParser,
      candidateOutput: finalRawOutput,
    );
    final settledSnapshot = observer.observeSettled(observedOutput);
    final hasSettledOutput =
        observer.hasSettledTurnEvidence(settledSnapshot.cleanedOutput);
    final snapshot =
        hasSettledOutput ? settledSnapshot : observer.observe(observedOutput);
    final terminalPrompt = snapshot.state == NativeOutputObserverState.running
        ? null
        : promptState.terminalPrompt;
    final turnIdle = hasSettledOutput && snapshot.turnIdle;
    final observerState =
        snapshot.state == NativeOutputObserverState.turnIdle && !turnIdle
            ? NativeOutputObserverState.outputQuieting
            : snapshot.state;
    return AgentExecutionUpdate(
      rawOutput: '',
      cleanedOutput: snapshot.cleanedOutput,
      observerState: observerState,
      turnIdle: turnIdle,
      runtimeLost: snapshot.runtimeLost,
      needsAttention: terminalPrompt != null || snapshot.needsAttention,
      nativeApproval: _nativeApprovalFromPrompt(terminalPrompt),
      done: turnIdle ||
          snapshot.runtimeLost ||
          snapshot.needsAttention ||
          terminalPrompt != null,
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

  bool _isStaleExit(String output) {
    return output.contains(_staleExitMarker);
  }

  NativeTerminalApproval? _nativeApprovalFromPrompt(
    TerminalPrompt? prompt,
  ) {
    final question = prompt?.question.trim() ?? '';
    if (question.isEmpty) {
      return null;
    }
    final options = prompt!.options
        .map(
          (option) => NativeApprovalOption(
            key: option.key,
            label: option.label,
          ),
        )
        .toList(growable: false);
    return NativeTerminalApproval(
      id: 'approval-${question.hashCode}',
      taskId: '',
      question: question,
      options: options,
      state: ApprovalState.pending,
      createdAt: DateTime.now(),
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

  @override
  Future<RemoteTaskProbe> probeRemoteState(AgentControlRequest request) async {
    _validateControlRequest(request);
    final output = await _runControlCommand(
      request,
      _wrapRemoteCommand(
        _buildProbeRemoteStateCommand(request),
        pathPrepend: request.pathPrepend,
        shellWrapper: request.shellWrapper,
      ),
    );
    return _parseRemoteTaskProbe(output);
  }

  String _buildCaptureLogCommand(AgentControlRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    return '$tmux capture-pane -p -t '
        '${_shellQuote(request.tmuxSessionName)} '
        '-S -${_runtimePolicy.finalCaptureLines} 2>/dev/null || true';
  }

  String _buildProbeRemoteStateCommand(AgentControlRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    return '''
if $tmux has-session -t $session 2>/dev/null; then
  printf '%s\\n' '$_probeSessionExistsMarker'
  $tmux capture-pane -p -t $session -S -${_runtimePolicy.monitorCaptureLines} 2>/dev/null || true
else
  printf '%s\\n' '$_probeSessionMissingMarker'
fi
''';
  }

  RemoteTaskProbe _parseRemoteTaskProbe(String output) {
    if (output.contains(_probeSessionMissingMarker)) {
      return const RemoteTaskProbe.missingSession();
    }
    if (!output.contains(_probeSessionExistsMarker)) {
      throw const FormatException('Remote probe returned no session marker.');
    }
    final snapshot = output.replaceFirst(_probeSessionExistsMarker, '').trim();
    final terminalPrompt = _terminalPromptParser.parse(snapshot);
    final currentAttention =
        !_hasNewerWorkOutputAfterAttention(snapshot, terminalPrompt);
    final exitMarkerCount = _exitMarkerCount(snapshot);
    return RemoteTaskProbe(
      sessionExists: true,
      snapshot: snapshot,
      hasApprovalPrompt: terminalPrompt != null && currentAttention,
      hasTerminalPrompt: terminalPrompt != null && currentAttention,
      hasExitedMarker: exitMarkerCount > 0,
      exitMarkerCount: exitMarkerCount,
    );
  }

  int _exitMarkerCount(String output) {
    return RegExp(
      r'Armin\s+(?:Codex|Qoder)\s+exited with status',
      caseSensitive: false,
    ).allMatches(output).length;
  }

  bool _hasNewerWorkOutputAfterAttention(
    String snapshot,
    TerminalPrompt? terminalPrompt,
  ) {
    final anchor = terminalPrompt?.question.trim() ?? '';
    if (anchor.isEmpty) {
      return false;
    }
    final index = snapshot.toLowerCase().lastIndexOf(anchor.toLowerCase());
    if (index < 0) {
      return false;
    }
    final tail = snapshot.substring(index + anchor.length);
    return tail.split('\n').any(_isNewerWorkOutputLine);
  }

  bool _isNewerWorkOutputLine(String line) {
    final text = line.trim();
    if (text.isEmpty) {
      return false;
    }
    if (RegExp(r'^(?:[❯>]\s*)?\d+\.\s+').hasMatch(text)) {
      return false;
    }
    if (text == 'Permission Required' || text == 'Apply this change?') {
      return false;
    }
    return text == 'Thinking' ||
        text.startsWith('▪') ||
        text.startsWith('▫') ||
        text.startsWith('> ') ||
        text.contains('Armin Codex exited with status') ||
        text.contains('Armin Qoder exited with status');
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
      // dartssh2 2.17 can leave a periodic ping in flight after close().
      keepAliveInterval: null,
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
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          _buildKillSessionCommand(request),
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  String _buildKillSessionCommand(AgentControlRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    return '''
$tmux kill-session -t $session 2>/dev/null || true
attempt=0
while $tmux has-session -t $session 2>/dev/null; do
  attempt=\$((attempt + 1))
  if [ "\$attempt" -ge 20 ]; then
    echo "Armin could not remove tmux session $session." >&2
    exit 1
  fi
  sleep 0.1
done
''';
  }

  Future<String> _runControlCommand(
    AgentControlRequest request,
    String command,
  ) async {
    final key = _controlConnectionKey(request);
    final connection = await _controlConnectionFor(key, request);
    connection.beginCommand();
    try {
      final output =
          await connection.client.run(command).timeout(_controlCommandTimeout);
      return utf8.decode(output, allowMalformed: true);
    } catch (_) {
      _dropControlConnection(key, connection);
      rethrow;
    } finally {
      connection.endCommand(
        idleTimeout: _controlConnectionIdleTimeout,
        onIdle: () => _dropControlConnection(key, connection),
      );
    }
  }

  Future<_PooledControlConnection> _controlConnectionFor(
    String key,
    AgentControlRequest request,
  ) {
    final existing = _controlConnections[key];
    if (existing != null && !existing.closed) {
      return Future<_PooledControlConnection>.value(existing);
    }
    return _controlConnectionCreates.putIfAbsent(key, () async {
      try {
        final client = await _connect(
          host: request.host,
          port: request.port,
          username: request.username,
          password: request.password,
          privateKeyPem: request.privateKeyPem,
          privateKeyPassphrase: request.privateKeyPassphrase,
        );
        final connection = _PooledControlConnection(client);
        _controlConnections[key] = connection;
        return connection;
      } finally {
        _controlConnectionCreates.remove(key);
      }
    });
  }

  void _dropControlConnection(
    String key,
    _PooledControlConnection connection,
  ) {
    if (_controlConnections[key] == connection) {
      _controlConnections.remove(key);
    }
    unawaited(connection.close());
  }

  String _controlConnectionKey(AgentControlRequest request) {
    return [
      request.host,
      request.port,
      request.username,
      request.tmuxSessionName,
      request.password.hashCode,
      request.privateKeyPem.hashCode,
      request.privateKeyPassphrase.hashCode,
    ].join('|');
  }

  String _buildExecutionScript(AgentExecutionRequest request) {
    final runtimePolicy = _runtimePolicyFor(request);
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
    final stablePolls = runtimePolicy.stablePollCount(_pollInterval);
    final maxPolls = runtimePolicy.maxPollCount(_pollInterval);
    final staleExitPolls =
        (const Duration(seconds: 10).inMilliseconds + delayMs - 1) ~/ delayMs;
    final monitorStart = -runtimePolicy.monitorCaptureLines;
    const monitorDiagnosticsVerbose = _monitorDiagnosticsVerbose ? 1 : 0;
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
set -e
$sessionSetup
emit_armin_snapshot() {
  printf "\\n__ARMIN_SNAPSHOT_BEGIN__\\n"
  printf "%s\\n" "\$pane_output"
  printf "__ARMIN_SNAPSHOT_END__\\n"
}
ARMIN_DIAG_VERBOSE=$monitorDiagnosticsVerbose
armin_diag_verbose() {
  if [ "\$ARMIN_DIAG_VERBOSE" -eq 1 ]; then
    echo "ARMIN_DIAG: \$*"
  fi
}

# ── Deterministic semantic pane hash ────────────────────────────
# Normalises \r, ANSI escapes, dynamic TUI chrome, trailing whitespace
# and empty lines before computing SHA-1.
armin_pane_semantic() {
  if ! command -v perl >/dev/null 2>&1; then
    echo "ARMIN_DIAG: FATAL perl is required for semantic pane filtering" >&2
    return 1
  fi
  perl -CSDA -0ne '
    s/\\r/\\n/g;
    s/\\e\\[[0-?]*[ -\\/]*[@-~]//g;
    s/[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]//g;
    my @outcomes = /(
      ARMIN_LOOP_OUTCOME_BEGIN
      .*?^\\s*state\\s*=\\s*(?:DONE|CONTINUE|BLOCKED)\\s*\$
      .*?ARMIN_LOOP_OUTCOME_END
    )/gmsx;
    if (@outcomes) {
      my \$outcome = \$outcomes[-1];
      \$outcome =~ s/[ \\t]+\$//mg;
      print "\$outcome\\n";
      next;
    }
    for my \$line (split /\\n/) {
      next if \$line =~ /[\\x{2800}-\\x{28ff}]/;
      \$line =~ s/\\s*[\\x{2800}-\\x{28ff}]\\s+(?:Thinking|.{1,80}\\.\\.\\.).*\$//i;
      \$line =~ s/\\s*\\b(?:Auto\\s+)?Model\\b.*\\bctx\\b.*\$//i;
      \$line =~ s/\\s*\\bctx\\b\\s*[^\\s]*\\s*\\d+%.*\$//i;
      next if \$line =~ /\\besc to cancel\\b/i;
      next if \$line =~ /\\b(?:Auto\\s+)?Model\\b.*\\bctx\\b/i;
      next if \$line =~ /\\bctx\\b\\s*\\d+%/i;
      next if \$line =~ /\\bEnjoy Off-Peak Discount\\b/i;
      next if \$line =~ /\\bTry \\/model to switch models\\b/i;
      next if \$line =~ /\\b\\d+\\s+MCP servers?\\s*[·|]\\s*\\d+\\s+skills\\b/i;
      next if \$line =~ /^\\s*[\\x{2800}-\\x{28ff}]\\s+.{1,80}\\.\\.\\.\\s*\$/;
      next if \$line =~ /^\\s*[\\x{2800}-\\x{28ff}]?\\s*Thinking[. …]*(?:\\([^)]*\\))?\\s*\$/i;
      \$line =~ s/\\bType your message or \\@path\\/to\\/file\\b.*//i;
      \$line =~ s/\\?\\s*for shortcuts\\b.*//i;
      \$line =~ s/(?:YOLO\\s+)?\\bShift\\+Tab to Auto(?:-accept Edits| Mode)?\\b.*//i;
      \$line =~ s/\\bAuto Model\\b.*//i;
      \$line =~ s/\\b(?:Auto\\s+)?Model\\b\\s*[·.].*//i;
      \$line =~ s/\\bctx\\b.*//i;
      \$line =~ s/[\\s\\x{2800}-\\x{28ff}]*Thinking[. …]*(?:\\([^)]*\\))?.*//i;
      \$line =~ s/Credits exhausted\\..*//i;
      \$line =~ s/Use \\/usage for details.*//i;
      \$line =~ s/Use \\/upgrade for more.*//i;
      \$line =~ s/[░█▁▂▃▄▅▆▇▀━─]+//g;
      \$line =~ s/[\\x{2800}-\\x{28ff}]//g;
      \$line =~ s/[ \\t]+\$//;
      next if \$line =~ /^\\s*(?:[·.])?\\s*(?:\\d+%|ctx\\b).*\\s*\$/i;
      next if \$line =~ /^[\\s·.\\-|%0-9:\\/~_]+\$/;
      next if \$line =~ /^\\s*\$/;
      print "\$line\\n";
    }
  '
}

armin_pane_hash() {
  armin_pane_semantic \\
  | shasum | awk '{print \$1}'
}

# ── Hash validation (must be exactly 40 hex chars) ─────────────
_validate_hash() {
  if [ -z "\$1" ] || ! printf "%s" "\$1" | grep -Eq '^[0-9a-f]{40}\$'; then
    echo "ARMIN_DIAG: FATAL hash=\$1 (expected 40-char hex)"
    exit 1
  fi
}
initial_output="\$($tmux capture-pane -p -t $session -S $monitorStart 2>/dev/null || true)"
initial_hash="\$(printf "%s" "\$initial_output" | armin_pane_hash)"
_validate_hash "\$initial_hash"
armin_diag_verbose "initial_hash=\$initial_hash stablePolls=$stablePolls"
echo "ARMIN_DIAG: monitor_version=$_monitorScriptVersion"
initial_exit_marker_count="\$(printf "%s" "\$initial_output" | grep -c "Armin ${profile.label} exited with status" || true)"
initial_attention_marker_count="\$(printf "%s" "\$initial_output" | grep -E -i -c ${_shellQuote(approvalPromptPattern)} || true)"
last_hash="\$initial_hash"
last_emitted_hash="\$initial_hash"
STABLE_POLLS=$stablePolls
$promptSubmit
stable_count=0
stale_exit_polls=0
last_stable_emitted_hash=""
changed_after_start=0
i=0
while [ "\$i" -lt $maxPolls ]; do
  if ! $tmux has-session -t $session 2>/dev/null; then
    echo "ARMIN_DIAG: BREAK_SESSION_LOST i=\$i"
    echo "Armin could not capture tmux pane because session ${_shellQuote(request.tmuxSessionName)} is not running."
    break
  fi
  pane_output="\$($tmux capture-pane -p -t $session -S $monitorStart 2>/dev/null || true)"
  current_hash="\$(printf "%s" "\$pane_output" | armin_pane_hash)"
  _validate_hash "\$current_hash"
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
  if [ "\$i" -lt 20 ]; then
    armin_diag_verbose "i=\$i cur=\${current_hash:0:12} changed=\$changed_after_start st=\$stable_count last=\${last_hash:0:12}"
  fi
  if [ "\$stable_count" -ge "\$STABLE_POLLS" ] && [ "\$changed_after_start" -eq 1 ]; then
    armin_diag_verbose "PRE_SETTLED i=\$i ch=\$changed_after_start st=\$stable_count se=\$snapshot_emitted lsh=\${last_stable_emitted_hash:0:12} chash=\${current_hash:0:12}"
    if [ "\$current_hash" != "\$last_stable_emitted_hash" ]; then
      armin_diag_verbose "EMITTING_SETTLED"
      if [ "\$current_hash" != "\$last_emitted_hash" ]; then
        armin_diag_verbose "SNAPSHOT_BEFORE_SETTLED i=\$i hash=\${current_hash:0:12}"
        emit_armin_snapshot
        snapshot_emitted=1
        last_emitted_hash="\$current_hash"
      else
        armin_diag_verbose "REUSE_SETTLED_SNAPSHOT i=\$i hash=\${current_hash:0:12}"
      fi
      armin_diag_verbose "BEFORE_SETTLED_CANDIDATE i=\$i"
      printf "%s\\n" "${_ExecutionOutputState.settledCandidateForTest}"
      armin_diag_verbose "AFTER_SETTLED_CANDIDATE i=\$i"
      armin_diag_verbose "SETTLED i=\$i hash=\${current_hash:0:12}"
      last_stable_emitted_hash="\$current_hash"
    else
      armin_diag_verbose "SKIP_SETTLED_ALREADY_EMITTED i=\$i hash=\${current_hash:0:12}"
    fi
  fi
  if [ "\$current_hash" != "\$last_emitted_hash" ]; then
    emit_armin_snapshot
    last_emitted_hash="\$current_hash"
    snapshot_emitted=1
  fi
  agent_exited=0
  exit_marker_count="\$(printf "%s" "\$pane_output" | grep -c "Armin ${profile.label} exited with status" || true)"
  if [ "\$exit_marker_count" -gt "\$initial_exit_marker_count" ]; then
    agent_exited=1
  fi
  if [ "\$agent_exited" -eq 1 ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    echo "ARMIN_DIAG: BREAK_AGENT_EXITED i=\$i"
    break
  fi
  if [ "\$initial_exit_marker_count" -gt 0 ] && [ "\$exit_marker_count" -eq "\$initial_exit_marker_count" ] && [ "\$changed_after_start" -eq 0 ]; then
    stale_exit_polls=\$((stale_exit_polls + 1))
    if [ "\$stale_exit_polls" -ge $staleExitPolls ]; then
      echo "ARMIN_DIAG: BREAK_STALE_EXIT i=\$i"
      echo "$_staleExitMarker"
      break
    fi
  else
    stale_exit_polls=0
  fi
  attention_marker_count="\$(printf "%s" "\$pane_output" | grep -E -i -c ${_shellQuote(approvalPromptPattern)} || true)"
  if [ "\$attention_marker_count" -gt "\$initial_attention_marker_count" ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
      snapshot_emitted=1
    fi
    echo "ARMIN_DIAG: ATTENTION_SNAPSHOT i=\$i"
  fi
  armin_diag_verbose "CHECK i=\$i changed=\$changed_after_start st=\$stable_count STABLE_POLLS=\$STABLE_POLLS"
  if [ "\$i" -eq ${maxPolls - 1} ]; then
    if [ "\$snapshot_emitted" -eq 0 ]; then
      emit_armin_snapshot
    fi
    echo "ARMIN_DIAG: BREAK_RUNTIME_LIMIT i=\$i"
    echo "Armin runtime limit reached while session ${_shellQuote(request.tmuxSessionName)} remains active."
    break
  fi
  i=\$((i + 1))
  sleep ${delayMs / 1000}
done
''';
    return _wrapRemoteCommand(
      script,
      pathPrepend: request.pathPrepend,
      shellWrapper: request.shellWrapper,
    );
  }

  RuntimePolicy _runtimePolicyFor(AgentExecutionRequest request) {
    return _runtimePolicy.forApprovalMode(request.approvalConfig?.mode);
  }

  void _debugPrintRuntimeDiagnostics(String text) {
    for (final line in _runtimeDiagnosticLines(text)) {
      debugPrint(line);
    }
  }

  List<String> _runtimeDiagnosticLines(String text) {
    if (!text.contains('ARMIN_DIAG:')) {
      return const [];
    }
    return const LineSplitter()
        .convert(text)
        .where((line) => line.contains('ARMIN_DIAG:'))
        .map((line) => line.trimRight())
        .toList(growable: false);
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
  List<String> runtimeDiagnosticLinesForTest(String text) {
    return _runtimeDiagnosticLines(text);
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
  String buildProbeRemoteStateCommandForTest(AgentControlRequest request) {
    return _buildProbeRemoteStateCommand(request);
  }

  @visibleForTesting
  String buildKillSessionCommandForTest(AgentControlRequest request) {
    return _buildKillSessionCommand(request);
  }

  @visibleForTesting
  RemoteTaskProbe parseRemoteTaskProbeForTest(String output) {
    return _parseRemoteTaskProbe(output);
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
  bool staleExitForTest(String output) {
    return _isStaleExit(output);
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
  List<String> rawOutputsForSnapshotChunksForTest(List<String> chunks) {
    final output = _ExecutionOutputState();
    return chunks.map((chunk) {
      output.write(chunk);
      return output.rawOutputForLatestUpdate(fallback: '');
    }).toList(growable: false);
  }

  @visibleForTesting
  int get streamTextLimitForTest => _ExecutionOutputState.streamTextLimit;

  @visibleForTesting
  String streamTextForChunksForTest(List<String> chunks) {
    final output = _ExecutionOutputState();
    for (final chunk in chunks) {
      output.write(chunk);
    }
    return output.streamText;
  }

  @visibleForTesting
  List<AgentExecutionUpdate> streamingUpdatesForChunksForTest(
    List<String> chunks, {
    Duration idleThreshold = const Duration(milliseconds: 1),
    String agentCommand = 'qodercli',
  }) {
    final output = _ExecutionOutputState();
    final observer = NativeOutputObserver(
      cleaner: _cleaner,
      runtimeAdapter: AgentRuntimeAdapter.forCommand(agentCommand),
      idleThreshold: idleThreshold,
    );
    return chunks.map((chunk) {
      output.write(chunk);
      return _buildStreamingUpdate(chunk, output, observer);
    }).toList(growable: false);
  }

  @visibleForTesting
  AgentExecutionUpdate streamCompletionUpdateForTextForTest(
    String text, {
    Duration idleThreshold = const Duration(milliseconds: 1),
    String agentCommand = 'qodercli',
  }) {
    final output = _ExecutionOutputState();
    output.write(
      '\n${_ExecutionOutputState.snapshotBeginForTest}\n'
      '$text\n'
      '${_ExecutionOutputState.snapshotEndForTest}\n',
    );
    final observer = NativeOutputObserver(
      cleaner: _cleaner,
      runtimeAdapter: AgentRuntimeAdapter.forCommand(agentCommand),
      idleThreshold: idleThreshold,
    );
    observer.observe(output.observedText);
    return _buildStreamCompletionUpdate(
      output: output,
      observer: observer,
      observedOutput: output.observedText,
    );
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
            r'Permission Required|Apply this change|Allow once|Reject and type something',
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
        r'([0-9]{1,2}[.)][[:space:]]*(Allow|Reject|Yes|No))|([>❯][[:space:]]*[0-9]{1,2}[.)])|((permission|approval|confirm|allow|reject).{0,80}[?？])|((waiting for|asking).{0,40}(user|approval|permission))';
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
  static const _settledCandidate = '__ARMIN_SETTLED_CANDIDATE__';
  static const streamTextLimit = 256 * 1024;

  @visibleForTesting
  static const snapshotBeginForTest = _snapshotBegin;

  @visibleForTesting
  static const snapshotEndForTest = _snapshotEnd;

  @visibleForTesting
  static const settledCandidateForTest = _settledCandidate;

  String _streamText = '';
  final StringBuffer _snapshot = StringBuffer();
  String _latestSnapshot = '';
  String _lastRawOutput = '';
  String _lastRawSignature = '';
  String _lastPromptParseSignature = '';
  _PromptParseResult _lastPromptParseResult = const _PromptParseResult();
  bool _capturingSnapshot = false;
  int _snapshotBeginMatch = 0;
  int _snapshotEndMatch = 0;
  int _settledCandidateCount = 0;
  int _consumedSettledCandidateCount = 0;

  void write(String text) {
    _appendStreamText(text);
    _scanSnapshotMarkers(text);
    _settledCandidateCount = _settledCandidate.allMatches(_streamText).length;
  }

  bool consumeSettledCandidate() {
    if (_consumedSettledCandidateCount >= _settledCandidateCount) {
      return false;
    }
    _consumedSettledCandidateCount = _settledCandidateCount;
    return true;
  }

  String get streamText => _streamText;

  String get observedText {
    return _latestSnapshot.trim().isEmpty ? streamText : _latestSnapshot;
  }

  _PromptParseResult promptState({
    required TerminalPromptParser terminalPromptParser,
    String candidateOutput = '',
  }) {
    final observed =
        candidateOutput.trim().isEmpty ? observedText : candidateOutput;
    final semanticSignature = _semanticSignature(observed);
    final signature =
        semanticSignature.isEmpty ? observed.trim() : semanticSignature;
    if (signature == _lastPromptParseSignature) {
      return _lastPromptParseResult;
    }
    _lastPromptParseSignature = signature;
    _lastPromptParseResult = _PromptParseResult(
      terminalPrompt: terminalPromptParser.parse(observed),
    );
    return _lastPromptParseResult;
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

  void _appendStreamText(String text) {
    if (text.length >= streamTextLimit) {
      _streamText = text.substring(text.length - streamTextLimit);
      return;
    }
    final next = '$_streamText$text';
    if (next.length > streamTextLimit) {
      _streamText = next.substring(next.length - streamTextLimit);
      return;
    }
    _streamText = next;
  }

  void _scanSnapshotMarkers(String text) {
    for (var index = 0; index < text.length; index++) {
      final codeUnit = text.codeUnitAt(index);
      if (_capturingSnapshot) {
        _scanSnapshotEnd(codeUnit);
      } else {
        _scanSnapshotBegin(codeUnit);
      }
    }
  }

  void _scanSnapshotBegin(int codeUnit) {
    if (codeUnit == _snapshotBegin.codeUnitAt(_snapshotBeginMatch)) {
      _snapshotBeginMatch++;
      if (_snapshotBeginMatch == _snapshotBegin.length) {
        _capturingSnapshot = true;
        _snapshotBeginMatch = 0;
        _snapshotEndMatch = 0;
        _snapshot.clear();
      }
      return;
    }
    _snapshotBeginMatch = codeUnit == _snapshotBegin.codeUnitAt(0) ? 1 : 0;
  }

  void _scanSnapshotEnd(int codeUnit) {
    if (codeUnit == _snapshotEnd.codeUnitAt(_snapshotEndMatch)) {
      _snapshotEndMatch++;
      if (_snapshotEndMatch == _snapshotEnd.length) {
        _latestSnapshot = _snapshot.toString().trim();
        _snapshot.clear();
        _capturingSnapshot = false;
        _snapshotEndMatch = 0;
      }
      return;
    }
    if (_snapshotEndMatch > 0) {
      _snapshot.write(_snapshotEnd.substring(0, _snapshotEndMatch));
      _snapshotEndMatch = 0;
      if (codeUnit == _snapshotEnd.codeUnitAt(0)) {
        _snapshotEndMatch = 1;
        return;
      }
    }
    _snapshot.writeCharCode(codeUnit);
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

class _PooledControlConnection {
  _PooledControlConnection(this.client);

  final SSHClient client;
  Timer? _idleTimer;
  int _activeCommands = 0;
  bool closed = false;

  void beginCommand() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeCommands++;
  }

  void endCommand({
    required Duration idleTimeout,
    required VoidCallback onIdle,
  }) {
    if (_activeCommands > 0) {
      _activeCommands--;
    }
    if (_activeCommands == 0 && !closed) {
      _idleTimer = Timer(idleTimeout, onIdle);
    }
  }

  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    client.close();
    await client.done;
  }
}

class _PromptParseResult {
  const _PromptParseResult({
    this.terminalPrompt,
  });

  final TerminalPrompt? terminalPrompt;
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
