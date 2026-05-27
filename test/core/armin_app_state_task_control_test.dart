import 'dart:async';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/parsers/terminal_prompt.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pauseTask persists paused status', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _HangingAgent()..capturedLog = 'latest pane output';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await state.pauseTask(task);

    expect(agent.paused, isTrue);
    expect(agent.cancelled, isTrue);
    expect(agent.cleanedUp, isFalse);
    expect(store.task!.status, TaskStatus.paused);
    expect(store.task!.rawLog, contains('Task paused by user.'));
  });

  test('resumeTask persists running status and reattaches observer', () async {
    final task = _task(status: TaskStatus.paused);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resumeTask(task);
    await Future<void>.delayed(Duration.zero);

    expect(agent.resumed, isTrue);
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.rawLog, contains('Task resumed by user.'));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(
      agent.lastExecuteRequest?.tmuxSessionName,
      task.host.tmuxSessionName,
    );
  });

  test('resumeTask uses current host password for stored task snapshots',
      () async {
    final task = _task(status: TaskStatus.paused).copyWith(
      host: _task(status: TaskStatus.paused).host.copyWith(password: ''),
    );
    final currentHost = task.host.copyWith(password: 'secure-password');
    final store = _TaskStore(task, hosts: [currentHost]);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resumeTask(task);
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastResumeRequest?.password, 'secure-password');
    expect(store.task!.status, TaskStatus.running);
    expect(agent.lastExecuteRequest?.password, 'secure-password');
  });

  test('stopTask persists stopped status', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ControlAgent()..capturedLog = 'latest pane output';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.stopTask(task);

    expect(agent.stopped, isTrue);
    expect(agent.cleanedUp, isTrue);
    expect(agent.events, containsAllInOrder(['captureLog', 'stop', 'cleanup']));
    expect(store.task!.status, TaskStatus.stopped);
    expect(store.task!.completedAt, isNotNull);
    expect(store.task!.rawLog, contains('Final captured output'));
    expect(store.task!.rawLog, contains('latest pane output'));
    expect(store.task!.rawLog, contains('Task stopped by user.'));
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.stopped);
    expect(store.task!.turns.single.userDecision, 'stopped');
  });

  test('stopTask records cleanup failure before surfacing stop error',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _CleanupFailingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(state.stopTask(task), throwsStateError);

    expect(store.task!.status, TaskStatus.stopped);
    expect(store.task!.shortSummary, contains('远端会话清理未确认'));
    expect(store.task!.rawLog, contains('Remote tmux session cleanup failed'));
    expect(store.task!.metricEvents.last.eventType, 'runtime_cleanup_failed');
  });

  test('updateTaskStatus can mark hung task failed', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.updateTaskStatus(task, TaskStatus.failed);

    expect(store.task!.status, TaskStatus.failed);
    expect(store.task!.completedAt, isNotNull);
    expect(store.task!.shortSummary, '用户手动标记为失败');
  });

  test('deleteTask removes task from store', () async {
    final task = _task(status: TaskStatus.userCompleted);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.deleteTask(task.id);

    expect(store.deletedTaskId, task.id);
    expect(state.tasks, isEmpty);
  });

  test('deleteTask rejects non-terminal active tasks', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(state.deleteTask(task.id), throwsStateError);

    expect(store.deletedTaskId, isNull);
    expect(state.tasks.single.id, task.id);
  });

  test('resolveApproval sends raw decision and marks task running', () async {
    final task = _task(status: TaskStatus.needApproval).copyWith(
      approval: const ApprovalRequest(
        reason: 'Need command approval',
        command: 'rm tmp.txt',
        risk: 'medium',
      ),
      approvalRequests: const [
        ApprovalRequest(
          reason: 'Need command approval',
          command: 'rm tmp.txt',
          risk: 'medium',
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.resolveApproval(task, approved: true);
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastFollowUp, startsWith('APPROVAL_DECISION:'));
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.approval, isNull);
    expect(store.task!.approvalRequests.single.status, 'approved');
    expect(store.task!.rawLog, contains('Approval approved by user.'));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(agent.lastExecuteRequest?.prompt, isEmpty);
  });

  test('terminal prompt update persists selectable terminal actions', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _TerminalPromptAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needAttention);
    expect(store.task!.terminalPrompt?.options, hasLength(2));
    expect(store.task!.terminalPrompt?.options.first.label, 'Allow once');
    expect(
        store.task!.metricEvents.last.eventType, 'terminal_prompt_requested');
  });

  test('selectTerminalOption writes selected key and resumes observation',
      () async {
    const option = TerminalPromptOption(key: '1', label: 'Allow once');
    final task = _task(status: TaskStatus.needAttention).copyWith(
      terminalPrompt: const TerminalPrompt(
        question: 'Allow execution of [ls]?',
        options: [option, TerminalPromptOption(key: '4', label: 'No')],
      ),
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.selectTerminalOption(task, option);
    await Future<void>.delayed(Duration.zero);

    expect(agent.selectedTerminalOption, '1');
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.terminalPrompt, isNull);
    expect(store.task!.metricEvents.last.eventType, 'terminal_prompt_resolved');
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
  });

  test('disconnectTask detaches observer without cleanup or failing task',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _HangingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await state.disconnectTask(task);

    expect(agent.cancelled, isTrue);
    expect(agent.cleanedUp, isFalse);
    expect(store.task!.status, TaskStatus.observerDetached);
    expect(store.task!.completedAt, isNull);
    expect(store.task!.rawLog, contains('Observer detached by user'));
    expect(store.task!.shortSummary, contains('已断开手机监听'));
  });

  test('reconnectTask uses attach-only request and returns to running',
      () async {
    final task = _task(status: TaskStatus.observerDetached);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.reconnectTask(task);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.running);
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(
        agent.lastExecuteRequest?.tmuxSessionName, task.host.tmuxSessionName);
  });

  test('sendFollowUp sends clean prompt and relistens current tmux session',
      () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.sendFollowUp(task, '只输出 pets 名字');
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastFollowUp, '只输出 pets 名字');
    expect(agent.lastFollowUp, isNot(contains('RUNTIME_UPDATE:')));
    expect(store.task!.status, TaskStatus.running);
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(store.task!.turns, hasLength(2));
    expect(store.task!.turns.last.turnIndex, 2);
    expect(store.task!.turns.last.userInput, '只输出 pets 名字');
  });

  test('sendFollowUp persists constraints recognized from user language',
      () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.sendFollowUp(
      task,
      '先别大改，不要提交 Git',
      addedConstraints: const {
        TaskConstraint.minimalChange,
        TaskConstraint.noGitCommit,
      },
    );

    expect(store.task!.constraints, contains(TaskConstraint.minimalChange));
    expect(store.task!.constraints, contains(TaskConstraint.noGitCommit));
  });

  test('voice follow-up stores redacted STT input for task audit', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.sendFollowUp(
      task,
      '继续检查',
      rawVoiceText: '继续检查 password=hunter2',
    );

    expect(store.task!.voiceInputs, hasLength(1));
    expect(
        store.task!.voiceInputs.single.rawSttText, '继续检查 password=[REDACTED]');
    expect(store.task!.metricEvents.last.eventType, 'voice_follow_up');
  });

  test('voice control command is retained when it ends the task', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.markTaskCompleted(task, rawVoiceText: '任务完成');

    expect(store.task!.status, TaskStatus.userCompleted);
    expect(store.task!.voiceInputs.single.rawSttText, '任务完成');
    expect(store.task!.metricEvents.last.eventType, 'user_mark_completed');
  });

  test('legacy successful result becomes turn idle without cleanup', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _CompletingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.completedAt, isNull);
    expect(agent.cleanedUp, isFalse);
    expect(store.task!.result?.summary, 'done');
  });

  test('legacy successful result speaks idle summary until user confirms',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _CompletingAgent();
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: voice,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(voice.spokenSummaries.single, contains('本轮输出已暂停'));
    expect(voice.spokenSummaries.single, contains('done'));
  });

  test('turn idle update does not complete or clean up task', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _TurnIdleAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.completedAt, isNull);
    expect(agent.cleanedUp, isFalse);
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.turnIdle);
    expect(store.task!.turns.single.rawOutput, contains('hello'));
  });

  test('turn idle output is spoken once for repeated same summary', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _RepeatedTurnIdleAgent(),
      voiceService: voice,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('本轮输出已暂停'));
  });

  test('approval request is spoken when attention speech is enabled', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ApprovalAgent(),
      voiceService: voice,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needApproval);
    expect(voice.spokenSummaries.single, contains('需要你确认一个操作'));
    expect(voice.spokenSummaries.single, isNot(contains('rm -rf')));
  });

  test('speech settings can disable attention speech', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _TurnIdleAgent(),
      voiceService: voice,
    );
    await state.load();
    state.updateSpeechSettings(
      state.speechSettings.copyWith(speakAttention: false),
    );

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(voice.spokenSummaries, isEmpty);
  });

  test('user marked completed cleans up tmux session', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _ControlAgent()..capturedLog = 'final pane output';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.markTaskCompleted(task);

    expect(store.task!.status, TaskStatus.userCompleted);
    expect(store.task!.completedAt, isNotNull);
    expect(agent.cleanedUp, isTrue);
    expect(agent.events, containsAllInOrder(['captureLog', 'cleanup']));
    expect(store.task!.rawLog, contains('Final captured output'));
    expect(store.task!.rawLog, contains('final pane output'));
    expect(
      store.task!.turns.single.status,
      NativeOutputTurnStatus.completedByUser,
    );
    expect(store.task!.turns.single.userDecision, 'completed');
  });

  test('user marked failed updates current turn', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _ControlAgent()..capturedLog = 'final pane output';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.markTaskFailed(task);

    expect(store.task!.status, TaskStatus.userFailed);
    expect(store.task!.completedAt, isNotNull);
    expect(agent.cleanedUp, isTrue);
    expect(agent.events, containsAllInOrder(['captureLog', 'cleanup']));
    expect(store.task!.rawLog, contains('Final captured output'));
    expect(store.task!.rawLog, contains('final pane output'));
    expect(
      store.task!.turns.single.status,
      NativeOutputTurnStatus.failedByUser,
    );
    expect(store.task!.turns.single.userDecision, 'failed');
  });

  test('cleanup failure is visible and terminal task can retry cleanup',
      () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final failingAgent = _CleanupFailingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: failingAgent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.markTaskCompleted(task);

    expect(store.task!.status, TaskStatus.userCompleted);
    expect(store.task!.shortSummary, contains('远端会话清理未确认'));
    expect(store.task!.rawLog, contains('Remote tmux session cleanup failed'));
    expect(store.task!.metricEvents.last.eventType, 'runtime_cleanup_failed');

    final retryAgent = _ControlAgent();
    final retryState = ArminAppState(
      store: store,
      agentSessionService: retryAgent,
      voiceService: const _SilentVoiceService(),
    );
    await retryState.load();
    await retryState.cleanupRemoteSession(store.task!);

    expect(retryAgent.cleanedUp, isTrue);
    expect(store.task!.status, TaskStatus.userCompleted);
    expect(store.task!.rawLog, contains('cleanup requested by user'));
    expect(store.task!.metricEvents.last.eventType, 'runtime_cleanup');
  });

  test('missing tmux session surfaces ended session summary', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _MissingSessionAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.runtimeLost);
    expect(store.task!.shortSummary, '远端会话不存在，可能已结束');
  });

  test('runtime timeout captures final pane before cleaning up session',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _RuntimeTimeoutAgent()..capturedLog = 'last visible output';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.runtimeLost);
    expect(store.task!.shortSummary, '任务达到最长运行时限，远端会话已清理');
    expect(store.task!.rawLog, contains('last visible output'));
    expect(agent.events, containsAllInOrder(['captureLog', 'cleanup']));
  });

  test('failed execution cleans up tmux session after error is saved',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _FailingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.failed);
    expect(store.task!.rawLog, contains('ssh failed'));
    expect(agent.cleanedUp, isTrue);
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.failed);
  });

  test('failed execution speaks failure summary', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _FailingAgent(),
      voiceService: voice,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.failed);
    expect(voice.spokenSummaries.single, contains('任务失败'));
    expect(voice.spokenSummaries.single, contains('建议先查看失败原因'));
  });

  test('socket interruption detaches observer without killing tmux session',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ConnectionInterruptedAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.observerDetached);
    expect(store.task!.completedAt, isNull);
    expect(store.task!.shortSummary, contains('可以重新监听或停止任务'));
    expect(store.task!.rawLog, contains('SocketException'));
    expect(store.task!.metricEvents.last.eventType, 'observer_connection_lost');
    expect(agent.cleanedUp, isFalse);
  });
}

TaskSession _task({required TaskStatus status}) {
  final now = DateTime(2026, 5, 17);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret-password',
    ),
    title: 'Task',
    status: status,
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Task',
    userText: 'Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Task',
    secretRecords: const [],
    rawLog: '',
  );
}

class _TaskStore implements TaskHistoryStore {
  _TaskStore(this.task, {List<HostConfig>? hosts}) : _hosts = hosts;

  TaskSession? task;
  String? deletedTaskId;
  final List<HostConfig>? _hosts;

  @override
  Future<List<HostConfig>> loadHosts() async {
    return _hosts ?? [if (task != null) task!.host];
  }

  @override
  Future<List<TaskSession>> loadTasks() async => [if (task != null) task!];

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> saveTask(TaskSession task) async {
    this.task = task;
  }

  @override
  Future<void> deleteTask(String taskId) async {
    deletedTaskId = taskId;
    if (task?.id == taskId) {
      task = null;
    }
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {}

  @override
  Future<void> deleteProjectPath(String projectPathId) async {}
}

class _ControlAgent implements AgentSessionService {
  bool paused = false;
  bool resumed = false;
  bool stopped = false;
  bool cleanedUp = false;
  String capturedLog = '';
  String? lastFollowUp;
  String? selectedTerminalOption;
  final List<String> events = [];
  AgentControlRequest? lastResumeRequest;
  AgentExecutionRequest? lastExecuteRequest;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    lastExecuteRequest = request;
  }

  @override
  Future<void> pause(AgentControlRequest request) async {
    events.add('pause');
    paused = true;
  }

  @override
  Future<void> resume(AgentControlRequest request) async {
    events.add('resume');
    resumed = true;
    lastResumeRequest = request;
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    events.add('sendFollowUp');
    lastFollowUp = request.instruction;
  }

  @override
  Future<void> selectTerminalOption(
    AgentControlRequest request,
    String optionKey,
  ) async {
    events.add('selectTerminalOption');
    selectedTerminalOption = optionKey;
  }

  @override
  Future<void> stop(AgentControlRequest request) async {
    events.add('stop');
    stopped = true;
    await cleanup(request);
  }

  @override
  Future<void> cleanup(AgentControlRequest request) async {
    events.add('cleanup');
    cleanedUp = true;
  }

  @override
  Future<String> captureLog(AgentControlRequest request) async {
    events.add('captureLog');
    return capturedLog;
  }

  @override
  Future<AgentConnectionTestResult> testConnection(
    AgentConnectionTestRequest request,
  ) async {
    return const AgentConnectionTestResult(success: true, message: 'ok');
  }

  @override
  Future<AgentInstructionDiscoveryResult> discoverAgentInstructions(
    AgentInstructionDiscoveryRequest request,
  ) async {
    return const AgentInstructionDiscoveryResult(paths: []);
  }
}

class _CompletingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'done',
      result: TaskResult(
        status: 'success',
        summary: 'done',
        changedFiles: [],
        validation: [],
        risks: [],
        nextActions: [],
      ),
      done: true,
    );
  }
}

class _FailingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    throw StateError('ssh failed');
  }
}

class _ConnectionInterruptedAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    throw StateError(
      'SSHSocketError(SocketException: Software caused connection abort)',
    );
  }
}

class _CleanupFailingAgent extends _ControlAgent {
  @override
  Future<void> cleanup(AgentControlRequest request) async {
    events.add('cleanup');
    throw StateError('cleanup transport failed');
  }
}

class _TurnIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'hello',
      cleanedOutput: 'hello',
      turnIdle: true,
      done: true,
    );
  }
}

class _MissingSessionAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: '',
      cleanedOutput: 'Armin could not find tmux session armin-12345678.',
      runtimeLost: true,
      done: true,
    );
  }
}

class _RuntimeTimeoutAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'Armin runtime limit reached while session armin-2800 '
          'remains active.',
      cleanedOutput: 'Armin runtime limit reached while session armin-2800 '
          'remains active.',
      runtimeLost: true,
      done: true,
    );
  }
}

class _RepeatedTurnIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'hello',
      cleanedOutput: 'hello',
      turnIdle: true,
    );
    yield const AgentExecutionUpdate(
      rawOutput: 'hello',
      cleanedOutput: 'hello',
      turnIdle: true,
    );
  }
}

class _ApprovalAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'approval',
      approval: ApprovalRequest(
        reason: '删除临时构建产物，风险中等。',
        command: 'rm -rf build',
        risk: 'medium',
      ),
    );
  }
}

class _TerminalPromptAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'Allow execution of [ls]?',
      needsAttention: true,
      terminalPrompt: TerminalPrompt(
        question: 'Allow execution of [ls]?',
        options: [
          TerminalPromptOption(key: '1', label: 'Allow once'),
          TerminalPromptOption(key: '4', label: 'No'),
        ],
      ),
    );
  }
}

class _HangingAgent extends _ControlAgent {
  bool cancelled = false;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    final controller = StreamController<AgentExecutionUpdate>(
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }
}

class _SilentVoiceService implements VoiceService {
  const _SilentVoiceService();

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => '';

  @override
  Future<void> speakSummary(String summary) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}

class _CapturingVoiceService implements VoiceService {
  final List<String> spokenSummaries = [];

  @override
  bool get isAvailable => true;

  @override
  Future<String> listenOnce() async => '';

  @override
  Future<void> speakSummary(String summary) async {
    spokenSummaries.add(summary);
  }

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}
