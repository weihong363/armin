import '../parsers/approval_request.dart';
import '../parsers/task_result.dart';

class AgentExecutionRequest {
  const AgentExecutionRequest({
    required this.prompt,
    this.hostId = '',
    this.host = '',
    this.port = 22,
    this.username = '',
    this.projectPath = '',
    this.tmuxSessionName = 'armin-codex',
    this.agentCommand = 'codex',
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
  });

  final String prompt;
  final String hostId;
  final String host;
  final int port;
  final String username;
  final String projectPath;
  final String tmuxSessionName;
  final String agentCommand;
  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
}

class AgentExecutionUpdate {
  const AgentExecutionUpdate({
    required this.rawOutput,
    this.result,
    this.approval,
    this.done = false,
  });

  final String rawOutput;
  final TaskResult? result;
  final ApprovalRequest? approval;
  final bool done;
}

class AgentControlRequest {
  const AgentControlRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.tmuxSessionName,
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.instruction = '',
  });

  final String host;
  final int port;
  final String username;
  final String tmuxSessionName;
  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
  final String instruction;
}

class AgentConnectionTestRequest {
  const AgentConnectionTestRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  final String host;
  final int port;
  final String username;
  final String password;
}

class AgentConnectionTestResult {
  const AgentConnectionTestResult({
    required this.success,
    required this.message,
  });

  final bool success;
  final String message;
}

abstract class AgentSessionService {
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request);

  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  );

  Future<void> sendFollowUp(AgentControlRequest request);

  Future<void> pause(AgentControlRequest request);

  Future<void> resume(AgentControlRequest request);

  Future<void> stop(AgentControlRequest request);
}
