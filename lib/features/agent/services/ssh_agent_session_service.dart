import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../hosts/models/host_config.dart';
import '../parsers/approval_parser.dart';
import '../parsers/task_result_parser.dart';
import 'agent_session_service.dart';
import 'codex_output_cleaner.dart';
import 'native_output_observer.dart';

class SSHAgentSessionService implements AgentSessionService {
  SSHAgentSessionService({
    TaskResultParser? resultParser,
    ApprovalParser? approvalParser,
    Duration pollInterval = const Duration(seconds: 1),
    int maxPolls = 900,
    CodexOutputCleaner cleaner = const CodexOutputCleaner(),
  })  : _resultParser = resultParser ?? TaskResultParser(),
        _approvalParser = approvalParser ?? ApprovalParser(),
        _pollInterval = pollInterval,
        _maxPolls = maxPolls,
        _cleaner = cleaner;

  final TaskResultParser _resultParser;
  final ApprovalParser _approvalParser;
  final Duration _pollInterval;
  final int _maxPolls;
  final CodexOutputCleaner _cleaner;

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
      final success = !testOutput.contains('codex status: missing') &&
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
      if (errorMsg.contains('codex') || errorMsg.contains('agent command')) {
        return AgentConnectionTestResult(
          success: false,
          message: 'SSH connected and tmux is available, but Codex command '
              'is not available: ${request.agentCommand}.\n'
              'Set Agent command to the absolute codex path or add its '
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
      final output = StringBuffer();
      late final StreamSubscription<Uint8List> stdoutSub;
      late final StreamSubscription<Uint8List> stderrSub;
      late final StreamController<AgentExecutionUpdate> controller;

      controller = StreamController<AgentExecutionUpdate>(
        onCancel: () async {
          session.close();
          await stdoutSub.cancel();
          await stderrSub.cancel();
        },
      );

      stdoutSub = session.stdout.listen((chunk) {
        final text = utf8.decode(chunk, allowMalformed: true);
        output.write(text);
        controller.add(
          AgentExecutionUpdate(
            rawOutput: text,
            cleanedOutput: _cleaner.clean(text),
          ),
        );
      });
      stderrSub = session.stderr.listen((chunk) {
        final text = utf8.decode(chunk, allowMalformed: true);
        output.write(text);
        controller.add(
          AgentExecutionUpdate(
            rawOutput: text,
            cleanedOutput: _cleaner.clean(text),
          ),
        );
      });

      unawaited(
        Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
            .whenComplete(() async {
          if (controller.isClosed) {
            return;
          }
          final fullOutput = output.toString();
          if (_isMissingTmuxSession(fullOutput)) {
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput: _cleaner.clean(fullOutput),
                observerState: NativeOutputObserverState.runtimeLost,
                runtimeLost: true,
                done: true,
              ),
            );
            await controller.close();
            return;
          }
          final approval = _approvalParser.parse(fullOutput);
          final result = _resultParser.parse(fullOutput);
          if (approval != null || result != null) {
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput: _cleaner.clean(fullOutput),
                observerState: approval != null
                    ? NativeOutputObserverState.needAttention
                    : NativeOutputObserverState.turnIdle,
                turnIdle: approval == null,
                needsAttention: approval != null,
                approval: approval,
                result: result,
                done: true,
              ),
            );
          } else {
            final snapshot = NativeOutputObserver(cleaner: _cleaner)
                .observeSettled(fullOutput);
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                cleanedOutput: snapshot.cleanedOutput,
                observerState: snapshot.state,
                turnIdle: snapshot.turnIdle,
                runtimeLost: snapshot.runtimeLost,
                needsAttention: snapshot.needsAttention,
                done: true,
              ),
            );
          }
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

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    _validateControlRequest(request);
    await _pasteText(request, _buildFollowUpText(request));
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
    final tmux = _tmuxCommand(request.tmuxCommand);
    final command = '$tmux capture-pane -p -t '
        '${_shellQuote(request.tmuxSessionName)} -S -200 2>/dev/null || true';
    final output = await _runControlCommand(
      request,
      _wrapRemoteCommand(
        command,
        pathPrepend: request.pathPrepend,
        shellWrapper: request.shellWrapper,
      ),
    );
    return output.trim();
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
    final tmux = _tmuxCommand(request.tmuxCommand);
    final command =
        '$tmux send-keys -t ${_shellQuote(request.tmuxSessionName)} '
        '-- ${_shellQuote(text)} C-m';
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
  }

  Future<void> _pasteText(AgentControlRequest request, String text) async {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    final clearHistory = text.trimLeft().startsWith('APPROVAL_DECISION:')
        ? '; $tmux clear-history -t $session'
        : '';
    final command = 'printf %s ${_shellQuote(text)} | $tmux load-buffer -; '
        '$tmux paste-buffer -t $session; '
        '$tmux send-keys -t $session C-m'
        '$clearHistory';
    await _runControlCommand(
        request,
        _wrapRemoteCommand(
          command,
          pathPrepend: request.pathPrepend,
          shellWrapper: request.shellWrapper,
        ));
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
    final agentLaunchCommand = _interactiveAgentLaunchCommand(request);
    final longRunningAgentCommand = _shellQuote(
      '$agentLaunchCommand; code=\$?; echo; '
      'echo "Armin Codex exited with status \$code."; sleep 3600',
    );
    final prompt = _shellQuote(request.prompt);
    final delayMs = _pollInterval.inMilliseconds;
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
  ready_output="\$($tmux capture-pane -p -t $session -S -80 2>/dev/null || true)"
  if printf "%s" "\$ready_output" | grep -q "OpenAI Codex\\|directory:"; then
    break
  fi
  if [ "\$update_prompt_skipped" -eq 0 ] && printf "%s" "\$ready_output" | grep -q "Update available!"; then
    $tmux send-keys -t $session 2 Enter
    update_prompt_skipped=1
    sleep 1
    continue
  fi
  if printf "%s" "\$ready_output" | grep -q "Armin Codex exited with status"; then
    printf "%s\\n" "\$ready_output"
    exit 1
  fi
  i=\$((i + 1))
  sleep 1
done
if [ "\$i" -ge 20 ]; then
  printf "%s\\n" "\$ready_output"
  echo "Armin timed out waiting for Codex TUI to become ready."
  exit 1
fi
printf %s $prompt | $tmux load-buffer -
$tmux paste-buffer -t $session
sleep 0.2
$tmux send-keys -t $session Enter
sleep 2
''';
    final script = '''
set -eu
$sessionSetup
initial_output="\$($tmux capture-pane -p -t $session -S -200 2>/dev/null || true)"
initial_hash="\$(printf "%s" "\$initial_output" | shasum | awk "{print \\\$1}")"
last_hash="\$initial_hash"
stable_count=0
changed_after_start=0
i=0
while [ "\$i" -lt $_maxPolls ]; do
  pane_output="\$($tmux capture-pane -p -t $session -S -200 2>/dev/null || true)"
  if [ -z "\$pane_output" ] && ! $tmux has-session -t $session 2>/dev/null; then
    echo "Armin could not capture tmux pane because session ${_shellQuote(request.tmuxSessionName)} is not running."
    break
  fi
  current_hash="\$(printf "%s" "\$pane_output" | shasum | awk "{print \\\$1}")"
  if [ "\$current_hash" != "\$initial_hash" ]; then
    changed_after_start=1
  fi
  if [ "\$current_hash" = "\$last_hash" ]; then
    stable_count=\$((stable_count + 1))
  else
    stable_count=0
    last_hash="\$current_hash"
  fi
  codex_exited=0
  if printf "%s" "\$pane_output" | grep -q "Armin Codex exited with status"; then
    codex_exited=1
  fi
  if [ "\$codex_exited" -eq 1 ]; then
    printf "%s\\n" "\$pane_output"
    break
  fi
  if [ "\$changed_after_start" -eq 1 ] && [ "\$i" -ge 8 ] && [ "\$stable_count" -ge 3 ]; then
    printf "%s\\n" "\$pane_output"
    break
  fi
  if [ "\$i" -eq ${_maxPolls - 1} ]; then
    printf "%s\\n" "\$pane_output"
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
  printf "codex status: ok\\n"
  printf "codex path: %s\\n" "\$agent_path"
  printf "codex version: %s\\n" "\$agent_version"
else
  printf "codex status: missing\\n"
  printf "codex command: %s\\n" ${_shellQuote(request.agentCommand)}
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
  String missingStructuredResultLogForTest(String output) {
    return _missingResultLog(output);
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
    return '${_agentLaunchCommand(request)} -C ${_pathToken(request.projectPath)}';
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

class SSHAuthPlan {
  const SSHAuthPlan({
    this.identities,
    this.onPasswordRequest,
  });

  final List<SSHKeyPair>? identities;
  final String Function()? onPasswordRequest;
}
