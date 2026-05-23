import '../../hosts/models/host_config.dart';
import '../parsers/approval_request.dart';
import '../parsers/task_result.dart';
import 'native_output_observer.dart';

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
    this.tmuxCommand = 'tmux',
    this.pathPrepend = '',
    this.shellWrapper = ShellWrapper.none,
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.attachOnly = false,
  });

  final String prompt;
  final String hostId;
  final String host;
  final int port;
  final String username;
  final String projectPath;
  final String tmuxSessionName;
  final String agentCommand;
  final String tmuxCommand;
  final String pathPrepend;
  final ShellWrapper shellWrapper;
  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
  final bool attachOnly;
}

class AgentExecutionUpdate {
  const AgentExecutionUpdate({
    required this.rawOutput,
    this.cleanedOutput,
    this.observerState = NativeOutputObserverState.running,
    this.turnIdle = false,
    this.runtimeLost = false,
    this.needsAttention = false,
    this.result,
    this.approval,
    this.done = false,
  });

  final String rawOutput;
  final String? cleanedOutput;
  final NativeOutputObserverState observerState;
  final bool turnIdle;
  final bool runtimeLost;
  final bool needsAttention;
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
    this.tmuxCommand = 'tmux',
    this.pathPrepend = '',
    this.shellWrapper = ShellWrapper.none,
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.instruction = '',
  });

  final String host;
  final int port;
  final String username;
  final String tmuxSessionName;
  final String tmuxCommand;
  final String pathPrepend;
  final ShellWrapper shellWrapper;
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
    this.tmuxCommand = 'tmux',
    this.agentCommand = 'codex',
    this.pathPrepend = '',
    this.shellWrapper = ShellWrapper.none,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String tmuxCommand;
  final String agentCommand;
  final String pathPrepend;
  final ShellWrapper shellWrapper;
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

  Future<void> cleanup(AgentControlRequest request);

  Future<String> captureLog(AgentControlRequest request);
}
