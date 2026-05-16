import 'dart:async';

import '../parsers/approval_parser.dart';
import '../parsers/task_result_parser.dart';
import 'agent_session_service.dart';

class MockAgentSessionService implements AgentSessionService {
  MockAgentSessionService({
    TaskResultParser? resultParser,
    ApprovalParser? approvalParser,
  })  : _resultParser = resultParser ?? TaskResultParser(),
        _approvalParser = approvalParser ?? ApprovalParser();

  final TaskResultParser _resultParser;
  final ApprovalParser _approvalParser;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(rawOutput: 'Mock agent accepted task.\n');
    await Future<void>.delayed(const Duration(seconds: 1));
    yield const AgentExecutionUpdate(
        rawOutput: 'Mock agent is reading files.\n');
    await Future<void>.delayed(const Duration(seconds: 1));

    if (request.scenario == MockAgentScenario.needApproval) {
      const approvalOutput = '''
NEED_APPROVAL_START
reason: Mock execution wants to run a high risk command.
command: rm -rf build
risk: high
NEED_APPROVAL_END
''';
      yield AgentExecutionUpdate(
        rawOutput: approvalOutput,
        approval: _approvalParser.parse(approvalOutput),
        done: true,
      );
      return;
    }

    await Future<void>.delayed(const Duration(seconds: 1));
    final resultOutput = request.scenario == MockAgentScenario.failed
        ? '''
TASK_RESULT_START
status: failed
summary: Mock execution failed after reading agent output.
changed_files:
- none
validation:
- Mock validation failed.
risks:
- The remote agent reported an error.
next_actions:
- Open raw logs and send a follow-up with missing context.
TASK_RESULT_END
'''
        : '''
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
  Future<void> pause(AgentControlRequest request) async {}

  @override
  Future<void> resume(AgentControlRequest request) async {}

  @override
  Future<void> stop(AgentControlRequest request) async {}
}
