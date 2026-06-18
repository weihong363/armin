import '../../hosts/models/host_config.dart';
import '../../runtime/models/approval_state.dart';
import '../../tasks/services/agent_instruction_discovery.dart';
import '../models/agent_approval_config.dart';
import 'native_output_observer.dart';

export '../../tasks/services/agent_instruction_discovery.dart'
    show AgentInstructionDiscoveryResult;

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
    this.approvalConfig,
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
  final AgentApprovalConfig? approvalConfig;
}

class AgentExecutionUpdate {
  const AgentExecutionUpdate({
    required this.rawOutput,
    this.cleanedOutput,
    this.observerState = NativeOutputObserverState.running,
    this.turnIdle = false,
    this.runtimeLost = false,
    this.needsAttention = false,
    this.nativeApproval,
    this.done = false,
  });

  final String rawOutput;
  final String? cleanedOutput;
  final NativeOutputObserverState observerState;
  final bool turnIdle;
  final bool runtimeLost;
  final bool needsAttention;
  final NativeTerminalApproval? nativeApproval;
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

class RemoteTaskProbe {
  const RemoteTaskProbe({
    required this.sessionExists,
    this.snapshot = '',
    this.hasApprovalPrompt = false,
    this.hasTerminalPrompt = false,
    this.hasExitedMarker = false,
    this.exitMarkerCount = 0,
  });

  const RemoteTaskProbe.missingSession()
      : sessionExists = false,
        snapshot = '',
        hasApprovalPrompt = false,
        hasTerminalPrompt = false,
        hasExitedMarker = false,
        exitMarkerCount = 0;

  final bool sessionExists;
  final String snapshot;
  final bool hasApprovalPrompt;
  final bool hasTerminalPrompt;
  final bool hasExitedMarker;
  final int exitMarkerCount;

  bool get needsAttention => hasApprovalPrompt || hasTerminalPrompt;
}

abstract class RemoteTaskProbeService {
  Future<RemoteTaskProbe> probeRemoteState(AgentControlRequest request);
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

class AgentInstructionDiscoveryRequest {
  const AgentInstructionDiscoveryRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.projectPath,
    this.pathPrepend = '',
    this.shellWrapper = ShellWrapper.none,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String projectPath;
  final String pathPrepend;
  final ShellWrapper shellWrapper;
}

abstract class AgentSessionService {
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request);

  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  );

  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  );

  Future<void> sendFollowUp(AgentControlRequest request);

  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  );

  Future<void> pause(AgentControlRequest request);

  Future<void> resume(AgentControlRequest request);

  Future<void> interrupt(AgentControlRequest request);

  Future<void> stop(AgentControlRequest request);

  Future<void> cleanup(AgentControlRequest request);

  Future<String> captureLog(AgentControlRequest request);
}
