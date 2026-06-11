import 'dart:async';

import 'package:armin/features/agent/parsers/task_result_parser.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';

class MockAgentSessionService implements AgentSessionService {
  MockAgentSessionService({
    TaskResultParser? resultParser,
  }) : _resultParser = resultParser ?? TaskResultParser();

  final TaskResultParser _resultParser;

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

    const resultOutput = '''
TASK_RESULT_START
status: success
summary: Mock Phase 1 execution completed.
changed_files:
- lib/features/tasks/screens/task_draft_screen.dart
validation:
- Mock validation passed.
risks:
- SSH/tmux is not implemented in Phase 1.
next_actions:
- Wire SQLite and real SSH in Phase 2.
TASK_RESULT_END
''';
    yield AgentExecutionUpdate(
      rawOutput: resultOutput,
      result: _resultParser.parse(resultOutput),
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
