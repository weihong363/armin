import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

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
    final identities = privateKeyPem == null || privateKeyPem.trim().isEmpty
        ? null
        : SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase);
    return SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest:
          password == null || password.isEmpty ? null : () => password,
    );
  }

  Future<void> _sendKeys(AgentControlRequest request, String text) async {
    final command = 'tmux send-keys -t ${_shellQuote(request.tmuxSessionName)} '
        '-- ${_shellQuote(text)} C-m';
    await _runControlCommand(request, command);
  }

  Future<void> _sendRawKeys(AgentControlRequest request, String key) async {
    final command = 'tmux send-keys -t ${_shellQuote(request.tmuxSessionName)} '
        '${_shellQuote(key)}';
    await _runControlCommand(request, command);
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
    final session = _shellQuote(request.tmuxSessionName);
    final projectPath = _shellQuote(request.projectPath);
    final agentCommand = _shellQuote(request.agentCommand);
    final prompt = _shellQuote(request.prompt);
    final delayMs = _pollInterval.inMilliseconds;
    return '''
set -eu
if ! tmux has-session -t $session 2>/dev/null; then
  tmux new-session -d -s $session -c $projectPath -- $agentCommand
fi
tmux send-keys -t $session -- $prompt C-m
last_hash=""
i=0
while [ "\$i" -lt $_maxPolls ]; do
  pane_output="\$(tmux capture-pane -p -t $session -S -2000)"
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
  }

  void _validateExecutionRequest(AgentExecutionRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.projectPath.trim().isEmpty ||
        request.tmuxSessionName.trim().isEmpty ||
        request.agentCommand.trim().isEmpty ||
        request.prompt.trim().isEmpty) {
      throw ArgumentError('SSH execution request is missing required fields.');
    }
  }

  void _validateControlRequest(AgentControlRequest request) {
    if (request.host.trim().isEmpty ||
        request.username.trim().isEmpty ||
        request.tmuxSessionName.trim().isEmpty) {
      throw ArgumentError('SSH control request is missing required fields.');
    }
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
