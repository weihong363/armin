import 'dart:async';

import 'package:armin/features/agent/services/agent_session_service.dart';

class MockAgentSessionService implements AgentSessionService {
  MockAgentSessionService();

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(
      success: true,
      message: 'Mock SSH connection succeeded.',
    );
  }

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    return const AgentInstructionDiscoveryResult(paths: []);
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(rawOutput: 'Mock agent accepted task.\n');
    await Future<void>.delayed(const Duration(seconds: 1));
    yield const AgentExecutionUpdate(
        rawOutput: 'Mock agent is reading files.\n');
    await Future<void>.delayed(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1));

    yield const AgentExecutionUpdate(
      rawOutput: 'Mock Phase 1 execution completed.',
      cleanedOutput: 'Mock Phase 1 execution completed.',
      done: true,
    );
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {}

  @override
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {}

  @override
  Future<void> pause(AgentControlRequest request) async {}

  @override
  Future<void> resume(AgentControlRequest request) async {}

  @override
  Future<void> interrupt(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}

  @override
  Future<void> cleanup(AgentControlRequest request) async {}

  @override
  Future<String> captureLog(AgentControlRequest request) async => '';
}
