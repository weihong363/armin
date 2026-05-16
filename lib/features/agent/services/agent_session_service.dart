import '../parsers/approval_request.dart';
import '../parsers/task_result.dart';

enum MockAgentScenario {
  completed,
  needApproval,
  failed,
}

class AgentExecutionRequest {
  const AgentExecutionRequest({
    required this.prompt,
    this.scenario = MockAgentScenario.completed,
    this.hostId = '',
    this.projectPath = '',
    this.agentCommand = 'codex',
  });

  final String prompt;
  final MockAgentScenario scenario;
  final String hostId;
  final String projectPath;
  final String agentCommand;

  bool get simulateApproval => scenario == MockAgentScenario.needApproval;
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

abstract class AgentSessionService {
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request);
}
