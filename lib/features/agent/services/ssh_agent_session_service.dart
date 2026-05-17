import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../hosts/models/host_config.dart';
import '../parsers/approval_parser.dart';
import '../parsers/task_result_parser.dart';
import 'agent_session_service.dart';

class SSHAgentSessionService implements AgentSessionService {
  SSHAgentSessionService({
    TaskResultParser? resultParser,
    ApprovalParser? approvalParser,
    Duration pollInterval = const Duration(seconds: 1),
    int maxPolls = 900,
  })  : _resultParser = resultParser ?? TaskResultParser(),
        _approvalParser = approvalParser ?? ApprovalParser(),
        _pollInterval = pollInterval,
        _maxPolls = maxPolls;

  final TaskResultParser _resultParser;
  final ApprovalParser _approvalParser;
  final Duration _pollInterval;
  final int _maxPolls;

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
      final tmuxOutput = await client.run(_wrapRemoteCommand(
        '${_tmuxCommand(request.tmuxCommand)} -V',
        pathPrepend: request.pathPrepend,
        shellWrapper: request.shellWrapper,
      ));
      final tmuxVersion = utf8.decode(tmuxOutput, allowMalformed: true).trim();

      return AgentConnectionTestResult(
        success: true,
        message: 'SSH connected to ${request.username}@${request.host}.\n'
            'tmux version: $tmuxVersion',
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
      final controller = StreamController<AgentExecutionUpdate>();

      final stdoutSub = session.stdout.listen((chunk) {
        final text = utf8.decode(chunk, allowMalformed: true);
        output.write(text);
        controller.add(AgentExecutionUpdate(rawOutput: text));
      });
      final stderrSub = session.stderr.listen((chunk) {
        final text = utf8.decode(chunk, allowMalformed: true);
        output.write(text);
        controller.add(AgentExecutionUpdate(rawOutput: text));
      });

      unawaited(
        Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
            .whenComplete(() async {
          final fullOutput = output.toString();
          final approval = _approvalParser.parse(fullOutput);
          final result = _resultParser.parse(fullOutput);
          if (approval != null || result != null) {
            controller.add(
              AgentExecutionUpdate(
                rawOutput: '',
                approval: approval,
                result: result,
                done: true,
              ),
            );
          } else {
            controller.add(
              const AgentExecutionUpdate(
                rawOutput: '\nSSH session ended without structured result.\n',
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

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    _validateControlRequest(request);
    final update = '''
RUNTIME_UPDATE:
The user updated the task constraints.

New instruction:
- ${request.instruction}

Keep previous findings. Do not restart the entire task unless necessary.
''';
    await _sendKeys(request, update);
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
    await _sendRawKeys(request, 'C-c');
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

  Future<void> _runControlCommand(
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
      await client.run(command);
    } finally {
      client.close();
      await client.done;
    }
  }

  String _buildExecutionScript(AgentExecutionRequest request) {
    final tmux = _tmuxCommand(request.tmuxCommand);
    final session = _shellQuote(request.tmuxSessionName);
    final projectPath = _shellQuote(request.projectPath);
    final agentCommand = _shellQuote(request.agentCommand);
    final prompt = _shellQuote(request.prompt);
    final delayMs = _pollInterval.inMilliseconds;
    final script = '''
set -eu
if ! $tmux has-session -t $session 2>/dev/null; then
  $tmux new-session -d -s $session -c $projectPath -- $agentCommand
fi
$tmux send-keys -t $session -- $prompt C-m
last_hash=""
i=0
while [ "\$i" -lt $_maxPolls ]; do
  pane_output="\$($tmux capture-pane -p -t $session -S -2000)"
  current_hash="\$(printf "%s" "\$pane_output" | shasum | awk "{print \\\$1}")"
  if [ "\$current_hash" != "\$last_hash" ]; then
    printf "%s\\n" "\$pane_output"
    last_hash="\$current_hash"
  fi
  if printf "%s" "\$pane_output" | grep -q "TASK_RESULT_END\\|NEED_APPROVAL_END"; then
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

  void _validateExecutionRequest(AgentExecutionRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.projectPath.trim().isEmpty ||
        request.tmuxSessionName.trim().isEmpty ||
        request.agentCommand.trim().isEmpty ||
        request.tmuxCommand.trim().isEmpty ||
        request.prompt.trim().isEmpty ||
        (request.password?.trim().isEmpty ?? true)) {
      throw ArgumentError('SSH execution request is missing required fields.');
    }
  }

  void _validateConnectionTestRequest(AgentConnectionTestRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.tmuxCommand.trim().isEmpty ||
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

  String _doubleQuoteContent(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
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
