import 'agent_session_service.dart';

class SSHAgentSessionService implements AgentSessionService {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    // TODO(phase2): connect over SSH, attach/create tmux, cd project path,
    // start the configured agent command, send prompt, and stream output.
    throw UnimplementedError('SSH/tmux execution is planned for Phase 2.');
  }
}
