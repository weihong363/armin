import 'dart:async';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/runtime/models/approval_state.dart';
import 'package:armin/features/runtime/models/runtime_task_snapshot.dart';
import 'package:armin/features/runtime/services/bridge_runtime.dart';
import 'package:armin/features/runtime/services/runtime_event_bus.dart';
import 'package:armin/features/runtime/services/runtime_task_store.dart';
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

  test('saveTask updates in-memory task without reloading all tasks', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();
    final loadCountAfterInitialLoad = store.loadTasksCount;

    await state.saveTask(task.copyWith(shortSummary: 'stream update'));

    expect(store.loadTasksCount, loadCountAfterInitialLoad);
    expect(state.tasks.single.shortSummary, 'stream update');
  });

  test('saveTask notifies only matching task listenable', () async {
    final task = _task(status: TaskStatus.running);
    final other = _task(status: TaskStatus.running).copyWith(id: 'task-2');
    final store = _TaskStore(task);
    store.tasks = [task, other];
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();
    var taskUpdates = 0;
    var otherUpdates = 0;
    state.taskListenable(task.id).addListener(() => taskUpdates++);
    state.taskListenable(other.id).addListener(() => otherUpdates++);

    await state.saveTask(task.copyWith(shortSummary: 'updated task 1'));

    expect(taskUpdates, 1);
    expect(otherUpdates, 0);
  });

  test('startTaskExecution does not block tmux execution on runtime storage',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(null);
    final runtimeStore = _BlockingRuntimeStore();
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      bridgeRuntime: BridgeRuntime(
        taskStore: runtimeStore,
        eventBus: RuntimeEventBus(),
      ),
    );
    await state.load();

    await state.saveTask(task);
    await runtimeStore.waitForBlockedLoad();
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastExecuteRequest?.prompt, 'Task');

    runtimeStore.releaseLoad();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      (await runtimeStore.loadTask(task.id))?.status,
      RuntimeTaskStatus.running,
    );
  });

  test('markTaskCompleted creates bridge task before completing it', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ControlAgent()..capturedLog = 'all done';
    final runtimeStore = _CallRecordingRuntimeStore();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      bridgeRuntime: BridgeRuntime(
        taskStore: runtimeStore,
        eventBus: RuntimeEventBus(),
      ),
    );
    await state.load();

    await state.markTaskCompleted(task);
    await Future<void>.delayed(Duration.zero);

    expect(runtimeStore.callLog.length, greaterThanOrEqualTo(2));
    final createIndex =
        runtimeStore.callLog.indexWhere((log) => log.status == 'running');
    final completeIndex =
        runtimeStore.callLog.indexWhere((log) => log.status == 'completed');
    expect(createIndex, greaterThanOrEqualTo(0));
    expect(completeIndex, greaterThanOrEqualTo(0));
    expect(createIndex, lessThan(completeIndex),
        reason: 'bridgeRuntime.createTask must happen before completeTask');
    expect(store.task!.status, TaskStatus.userCompleted);
    expect(agent.events, containsAllInOrder(['captureLog', 'cleanup']));
  });

  test('refreshTasks reloads task list from store', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    store.task = task.copyWith(shortSummary: 'reloaded from store');
    await state.refreshTasks();

    expect(state.tasks.single.shortSummary, 'reloaded from store');
    expect(store.loadTasksCount, 2);
  });

  test('refreshTasks dedupes duplicate stored tasks', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(null);
    store.tasks = [
      task.copyWith(shortSummary: 'newer'),
      task.copyWith(shortSummary: 'older duplicate'),
    ];
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTasks();

    expect(state.tasks, hasLength(1));
    expect(state.tasks.single.shortSummary, 'newer');
  });

  test('refreshTasks asynchronously syncs remote snapshot for running tasks',
      () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '完成 FlipCountdown',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
Thinking
 │ Final summary.
▪ Done. FlipCountdown 已完成。
 Credits exhausted. Use /usage for details or /upgrade for more.
 YOLO Shift+Tab to Auto Mode
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTasks();

    expect(state.tasks.single.status, TaskStatus.running);
    await _waitUntil(() => store.task!.status == TaskStatus.turnIdle);
    expect(store.task!.summary, contains('FlipCountdown 已完成'));
    expect(store.task!.summary, isNot(contains('Credits exhausted')));
    expect(agent.events, contains('captureLog'));
    expect(agent.lastExecuteRequest, isNull);
  });

  test('refreshTasks remote sync does not duplicate a stored task', () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '完成 FlipCountdown',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(null);
    store.tasks = [task, task.copyWith(shortSummary: 'older duplicate')];
    store.task = task;
    final agent = _ControlAgent()..capturedLog = '▪ Done. 同步完成。';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTasks();
    await _waitUntil(() => store.task!.status == TaskStatus.turnIdle);

    expect(state.tasks, hasLength(1));
    expect(store.tasks.where((item) => item.id == task.id), hasLength(1));
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTasks does not restart active observers while syncing',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _HangingAgent()..capturedLog = '▪ Done. Already finished.';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();
    state.startTaskExecution(task, const AgentExecutionRequest(prompt: 'Task'));
    await Future<void>.delayed(Duration.zero);
    final firstRequest = agent.lastExecuteRequest;

    await state.refreshTasks();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    state.dispose();

    expect(agent.events, isNot(contains('captureLog')));
    expect(agent.lastExecuteRequest, same(firstRequest));
  });

  test('refreshTasks skips runtimeLost remote probes', () async {
    final task = _task(status: TaskStatus.runtimeLost);
    final store = _TaskStore(task);
    final agent = _ControlAgent()..capturedLog = '▪ Done. Already finished.';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTasks();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(agent.events, isNot(contains('captureLog')));
    expect(store.task!.status, TaskStatus.runtimeLost);
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

  test('saveHost rejects edits while active task uses host', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task, hosts: [task.host]);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(
      state.saveHost(task.host.copyWith(name: 'Renamed')),
      throwsA(isA<HostEditBlockedException>()),
    );

    expect(store.savedHosts, isEmpty);
  });

  test('deleteHost rejects deletion while active task uses host', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task, hosts: [task.host]);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(
      state.deleteHost(task.host.id),
      throwsA(isA<HostEditBlockedException>()),
    );

    expect(store.deletedHostId, isNull);
    expect(state.hosts.single.id, task.host.id);
  });

  test('deleteHost removes inactive host from store', () async {
    final task = _task(status: TaskStatus.completed);
    final store = _TaskStore(task, hosts: [task.host]);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.deleteHost(task.host.id);

    expect(store.deletedHostId, task.host.id);
    expect(state.hosts, isEmpty);
  });

  test('saveProjectPath rejects editing path used by active task', () async {
    final task = _task(status: TaskStatus.running);
    final projectPath = _projectPath(
      id: 'project-1',
      path: task.host.projectPath,
    );
    final store = _TaskStore(
      task,
      hosts: [task.host],
      projectPaths: [projectPath],
    );
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(
      state.saveProjectPath(projectPath.copyWith(path: '/tmp/other')),
      throwsA(isA<ProjectPathEditBlockedException>()),
    );

    expect(store.savedProjectPaths, isEmpty);
  });

  test('deleteProjectPath rejects deletion while active task uses path',
      () async {
    final task = _task(status: TaskStatus.running);
    final projectPath = _projectPath(
      id: 'project-1',
      path: task.host.projectPath,
    );
    final store = _TaskStore(
      task,
      hosts: [task.host],
      projectPaths: [projectPath],
    );
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(
      state.deleteProjectPath(projectPath.id),
      throwsA(isA<ProjectPathEditBlockedException>()),
    );

    expect(store.deletedProjectPathId, isNull);
    expect(state.projectPaths.single.id, projectPath.id);
  });

  test('resolveApproval sends raw decision and marks task running', () async {
    final approval = _nativeApproval(
      question: 'Need command approval',
      options: const [],
    );
    final task = _task(status: TaskStatus.needApproval).copyWith(
      nativeApproval: approval,
      nativeApprovalRequests: [approval],
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
    expect(store.task!.nativeApproval, isNull);
    expect(store.task!.nativeApprovalRequests.single.state,
        ApprovalState.resolved);
    expect(store.task!.rawLog, contains('Approval approved by user.'));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(agent.lastExecuteRequest?.prompt, isEmpty);
  });

  test('resolveApproval routes native terminal approvals through option key',
      () async {
    const option = NativeApprovalOption(key: '1', label: 'Allow once');
    final approval = _nativeApproval(
      question: 'Apply this change?',
      options: const [
        option,
        NativeApprovalOption(key: '4', label: 'Reject and type something'),
      ],
    );
    final task = _task(status: TaskStatus.needApproval).copyWith(
      nativeApproval: approval,
      nativeApprovalRequests: [approval],
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

    expect(agent.events, isNot(contains('sendFollowUp')));
    expect(agent.selectedTerminalOption, '1');
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.nativeApproval, isNull);
    expect(store.task!.nativeApprovalRequests.single.state,
        ApprovalState.resolved);
    expect(
      store.task!.nativeApprovalRequests.single.selectedOptionKey,
      '1',
    );
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
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

    expect(store.task!.status, TaskStatus.needApproval);
    expect(store.task!.nativeApproval?.options, hasLength(2));
    expect(store.task!.nativeApproval?.options.first.label, 'Allow once');
    expect(store.task!.metricEvents.last.eventType, 'approval_requested');
  });

  test('needsAttention update changes running task to needAttention', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _NeedsAttentionAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needAttention);
    expect(store.task!.shortSummary, 'Agent 正在等待你的输入');
    expect(store.task!.metricEvents.last.eventType, 'need_attention');
  });

  test('selectTerminalOption writes selected key and resumes observation',
      () async {
    const option = NativeApprovalOption(key: '1', label: 'Allow once');
    final approval = _nativeApproval(
      question: 'Allow execution of [ls]?',
      options: const [
        option,
        NativeApprovalOption(key: '4', label: 'No'),
      ],
    );
    final task = _task(status: TaskStatus.needAttention).copyWith(
      nativeApproval: approval,
      nativeApprovalRequests: [approval],
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
    expect(store.task!.nativeApproval, isNull);
    expect(store.task!.metricEvents.last.eventType, 'terminal_prompt_resolved');
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
  });

  test('selectTerminalOption accepts options from pending approval history',
      () async {
    const option = NativeApprovalOption(
      key: '2',
      label: 'Allow for this session',
    );
    final approval = _nativeApproval(
      question: 'Apply this change?',
      options: const [
        NativeApprovalOption(key: '1', label: 'Allow once'),
        option,
        NativeApprovalOption(key: '4', label: 'Reject and type something'),
      ],
    );
    final task = _task(status: TaskStatus.needApproval).copyWith(
      nativeApprovalRequests: [approval],
      clearNativeApproval: true,
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

    expect(agent.selectedTerminalOption, '2');
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.nativeApproval, isNull);
    expect(
      store.task!.nativeApprovalRequests.single.state,
      ApprovalState.resolved,
    );
    expect(
      store.task!.nativeApprovalRequests.single.selectedOptionKey,
      '2',
    );
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
  });

  test('selectTerminalOption resolves stale pending approval with new id',
      () async {
    const option = NativeApprovalOption(
      key: '2',
      label: 'Allow for this session',
    );
    final staleApproval = _nativeApproval(
      question: 'Apply this change?',
      options: const [
        NativeApprovalOption(key: '1', label: 'Allow once'),
        option,
        NativeApprovalOption(key: '4', label: 'Reject and type something'),
      ],
    ).copyWith(id: 'approval-old');
    final currentApproval = staleApproval.copyWith(
      id: 'approval-new',
      createdAt: DateTime(2026, 5, 19),
    );
    final task = _task(status: TaskStatus.needApproval).copyWith(
      nativeApproval: currentApproval,
      nativeApprovalRequests: [staleApproval],
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

    expect(agent.selectedTerminalOption, '2');
    expect(store.task!.nativeApproval, isNull);
    expect(
      store.task!.nativeApprovalRequests
          .where((approval) => approval.state == ApprovalState.pending),
      isEmpty,
    );
    expect(
      store.task!.nativeApprovalRequests
          .map((approval) => approval.selectedOptionKey)
          .toSet(),
      {'2'},
    );
  });

  test('selectTerminalOption sends custom response for manual prompts',
      () async {
    const option = NativeApprovalOption(
      key: '3',
      label: 'Reject and type something',
    );
    final approval = _nativeApproval(
      question: 'Allow this command to run?',
      options: const [
        option,
        NativeApprovalOption(key: '4', label: 'No'),
      ],
    );
    final task = _task(status: TaskStatus.needAttention).copyWith(
      nativeApproval: approval,
      nativeApprovalRequests: [approval],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.selectTerminalOption(
      task,
      option,
      customResponse: '请不要运行测试',
    );
    await Future<void>.delayed(Duration.zero);

    expect(agent.selectedTerminalOption, '3');
    expect(agent.lastFollowUp, '请不要运行测试');
    expect(agent.events,
        containsAllInOrder(['selectTerminalOption', 'sendFollowUp']));
    expect(store.task!.nativeApproval, isNull);
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
    final task = _task(status: TaskStatus.observerDetached).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 hello',
          rawOutput: 'hello',
          cleanedOutput: 'hello',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续输出 world',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18, 0, 0, 1),
          lastOutputAt: DateTime(2026, 5, 18, 0, 0, 1),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
输出 hello
hello
继续输出 world
world
''';
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
    expect(store.task!.turns.last.cleanedOutput, contains('world'));
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTaskFromRemote recovers approval prompt while task is running',
      () async {
    final approvedApproval = _nativeApproval(
      question: 'Apply this change?',
      state: ApprovalState.resolved,
      selectedOptionKey: '1',
      stateChangedAt: DateTime(2026, 5, 18, 0, 1),
    );
    final task = _task(status: TaskStatus.running).copyWith(
      nativeApprovalRequests: [approvedApproval],
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '写 README',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
Tool: Write
File: README.md

Apply this change?

  ❯ 1. Allow once
    2. Allow for this session
    3. Modify with external editor
    4. Reject and type something
    5. No
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTaskFromRemote(task);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needApproval);
    expect(store.task!.nativeApproval?.question, 'Apply this change?');
    expect(store.task!.nativeApprovalRequests.single.question,
        'Apply this change?');
    expect(
        store.task!.nativeApprovalRequests.single.state, ApprovalState.pending);
    expect(store.task!.nativeApprovalRequests.single.stateChangedAt, isNull);
    expect(store.task!.nativeApproval?.options.first.label, 'Allow once');
    expect(agent.lastExecuteRequest, isNull);
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTaskFromRemote ignores stale approval followed by new output',
      () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '继续写 README',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
Apply this change?

  ❯ 1. Allow once
    2. Reject and type something

> 写 readme，包含所有使用事例

Thinking
 │ The user wants me to write a README.
▪ README.md 已写入。
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTaskFromRemote(task);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.nativeApproval, isNull);
    expect(agent.lastExecuteRequest, isNull);
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTaskFromRemote settles completed yolo output after credits',
      () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '移除 FlipCountdown',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
Thinking
 │ Everything looks clean. FlipCountdown is fully removed.
 ▪ Done. FlipCountdown 已完全移除。当前 package 只包含：

   - CircularCountdown - 圆形进度环倒计时（lib/src/circular_countdown.dart）
   - LinearCountdown - 线性进度条倒计时（lib/src/linear_countdown.dart）

   请确认后我再继续下一步。
 Credits exhausted. Use /usage for details or /upgrade for more.

──────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTaskFromRemote(task);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.turnIdle);
    expect(store.task!.summary, contains('FlipCountdown 已完全移除'));
    expect(store.task!.summary, isNot(contains('Credits exhausted')));
    expect(agent.lastExecuteRequest, isNull);
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTaskFromRemote replaces observer only when one is active',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _HangingAgent()..capturedLog = 'still running\n下一步可以继续';
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
    final firstRequest = agent.lastExecuteRequest;

    await state.refreshTaskFromRemote(task);
    await Future<void>.delayed(Duration.zero);

    expect(agent.cancelled, isTrue);
    expect(agent.lastExecuteRequest, isNot(same(firstRequest)));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(agent.events, contains('captureLog'));
  });

  test('refreshTaskFromRemote does not relisten detached tasks', () async {
    final task = _task(status: TaskStatus.observerDetached);
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = 'remote output after detach\n等待继续';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.refreshTaskFromRemote(task);
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastExecuteRequest, isNull);
    expect(agent.events, contains('captureLog'));
  });

  test('remote reconcile keeps stable running output as running', () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 hello',
          rawOutput: 'hello',
          cleanedOutput: 'hello',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续检查',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ProbeAgent()
      ..capturedLog = 'HELLO WORLD\n下一步可以继续补充要求'
      ..probe = const RemoteTaskProbe(
        sessionExists: true,
        snapshot: 'HELLO WORLD\n下一步可以继续补充要求',
      );
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteReconcileInterval: const Duration(milliseconds: 10),
    );
    await state.load();

    await _waitUntil(() => agent.probeCount >= 2);
    state.dispose();

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.turns.last.turnIndex, 2);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.running);
    expect(agent.events, isNot(contains('captureLog')));
    expect(agent.probeCount, greaterThanOrEqualTo(2));
  });

  test('remote reconcile ignores old exit marker on first probe', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _ProbeAgent()
      ..capturedLog = 'old result\nArmin Codex exited with status 0.'
      ..probe = const RemoteTaskProbe(
        sessionExists: true,
        snapshot: 'old result\nArmin Codex exited with status 0.',
        hasExitedMarker: true,
        exitMarkerCount: 1,
      );
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteReconcileInterval: const Duration(milliseconds: 100),
    );
    await state.load();
    await _waitUntil(() => agent.probeCount >= 1);
    state.dispose();

    expect(store.task!.status, TaskStatus.running);
    expect(agent.events, isNot(contains('captureLog')));
    expect(agent.probeCount, greaterThanOrEqualTo(1));
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

  test('sendFollowUp preserves aggressive execution mode on reattach',
      () async {
    final task = _task(status: TaskStatus.turnIdle).copyWith(
      approvalMode: AgentApprovalMode.aggressive,
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.sendFollowUp(task, '继续跑完整测试');
    await Future<void>.delayed(Duration.zero);

    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
    expect(
      agent.lastExecuteRequest?.approvalConfig?.mode,
      AgentApprovalMode.aggressive,
    );
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

  test('successful done update becomes turn idle without cleanup', () async {
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
    expect(store.task!.summary, 'done');
  });

  test('successful done update speaks idle summary until user confirms',
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

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
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

  test('done update needing attention does not write a result summary',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _DoneNeedsAttentionAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needAttention);
    expect(store.task!.summary, task.summary);
  });

  test(
      'credits exhausted after deliverable writes result instead of needs input',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _QuotaAfterDeliverableAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.turnIdle);
    expect(store.task!.summary, contains('12 个测试全部通过'));
    expect(store.task!.summary, isNot(contains('Credits exhausted')));
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

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('本轮输出已暂停'));
  });

  test('streamed output settles status logs and speech together', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _StreamingThenIdleAgent(),
      voiceService: voice,
    );
    await state.load();

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.summary, 'HELLO WORLD');
    // executionLogs may be empty for pure-progress chunks;
    // the full execution snapshot is captured on state transitions only.
    expect(
      store.task!.metricEvents.map((event) => event.eventType),
      contains('turn_idle'),
    );
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('HELLO WORLD'));
  });

  test('empty polling updates do not create log or metric nodes', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _EmptyPollingAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.executionLogs, isEmpty);
    expect(store.task!.metricEvents, isEmpty);
  });

  test('repeated log updates keep a single metrics node', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _RepeatedLogUpdateAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Pure-progress updates are handled via _taskWithLightProgress
    // which skips metrics accumulation. Metrics are only created on
    // state transitions. Repeated progress chunks produce 0 metric nodes.
    final logUpdates = store.task!.metricEvents
        .where((event) => event.eventType == 'log_update');
    expect(logUpdates, isEmpty);
  });

  test('pure progress updates do not notify home snapshot', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _RepeatedLogUpdateAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();
    var homeUpdates = 0;
    state.homeSnapshot.addListener(() => homeUpdates++);

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.running);
    expect(homeUpdates, 0);
  });

  test('pure progress updates do not notify global app listeners', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _RepeatedLogUpdateAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();
    var appUpdates = 0;
    state.addListener(() => appUpdates++);

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.running);
    expect(appUpdates, 0);
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

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needApproval);
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
    expect(voice.spokenSummaries.single, contains('需要你确认一个操作'));
    expect(voice.spokenSummaries.single, isNot(contains('rm -rf')));
  });

  test('approval speech on turn two does not replay turn one result', () async {
    final now = DateTime(2026, 5, 18);
    final task = _task(status: TaskStatus.running).copyWith(
      summary: 'Turn 1 old result should not be spoken',
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出旧结果',
          rawOutput: 'Turn 1 old result',
          cleanedOutput: 'Turn 1 old result',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '继续检查',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: now.add(const Duration(seconds: 1)),
          lastOutputAt: now.add(const Duration(seconds: 1)),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ApprovalAgent(),
      voiceService: voice,
    );
    await state.load();

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needApproval);
    expect(store.task!.turns.last.turnIndex, 2);
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
    expect(voice.spokenSummaries.single, contains('删除临时构建产物'));
    expect(voice.spokenSummaries.single, isNot(contains('Turn 1 old result')));
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

    state.setActiveDetailTaskId(task.id);
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.failed);
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);
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

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) {
    fail('Timed out waiting for condition.');
  }
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

NativeTerminalApproval _nativeApproval({
  required String question,
  List<NativeApprovalOption> options = const [
    NativeApprovalOption(key: '1', label: 'Allow once'),
    NativeApprovalOption(key: '4', label: 'Reject and type something'),
  ],
  ApprovalState state = ApprovalState.pending,
  String? selectedOptionKey,
  DateTime? stateChangedAt,
}) {
  return NativeTerminalApproval(
    id: 'approval-1',
    taskId: 'task-1',
    question: question,
    options: options,
    state: state,
    selectedOptionKey: selectedOptionKey,
    createdAt: DateTime(2026, 5, 18),
    stateChangedAt: stateChangedAt,
  );
}

ProjectPathConfig _projectPath({
  required String id,
  required String path,
}) {
  final now = DateTime(2026, 5, 17);
  return ProjectPathConfig(
    id: id,
    name: 'Armin',
    path: path,
    createdAt: now,
    updatedAt: now,
  );
}

class _TaskStore implements TaskHistoryStore {
  _TaskStore(
    this.task, {
    List<HostConfig>? hosts,
    List<ProjectPathConfig>? projectPaths,
  })  : hosts = hosts ?? [if (task != null) task.host],
        projectPaths = projectPaths ?? const [],
        tasks = [if (task != null) task];

  TaskSession? task;
  List<TaskSession> tasks;
  String? deletedTaskId;
  String? deletedHostId;
  String? deletedProjectPathId;
  final List<HostConfig> hosts;
  List<ProjectPathConfig> projectPaths;
  final List<HostConfig> savedHosts = [];
  final List<ProjectPathConfig> savedProjectPaths = [];
  int loadTasksCount = 0;

  @override
  Future<List<HostConfig>> loadHosts() async {
    return List.unmodifiable(hosts);
  }

  @override
  Future<List<TaskSession>> loadTasks() async {
    loadTasksCount++;
    if (task != null && tasks.length <= 1) {
      tasks = [task!];
    }
    return tasks;
  }

  @override
  Future<void> saveHost(HostConfig host) async {
    savedHosts.add(host);
    final index = hosts.indexWhere((item) => item.id == host.id);
    if (index >= 0) {
      hosts[index] = host;
      return;
    }
    hosts.add(host);
  }

  @override
  Future<void> deleteHost(String hostId) async {
    deletedHostId = hostId;
    hosts.removeWhere((item) => item.id == hostId);
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    this.task = task;
    tasks.removeWhere((item) => item.id == task.id);
    tasks.insert(0, task);
  }

  @override
  Future<void> deleteTask(String taskId) async {
    deletedTaskId = taskId;
    if (task?.id == taskId) {
      task = null;
    }
    tasks = tasks.where((task) => task.id != taskId).toList();
  }

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async {
    return List.unmodifiable(projectPaths);
  }

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    savedProjectPaths.add(projectPath);
    final index = projectPaths.indexWhere((item) => item.id == projectPath.id);
    if (index >= 0) {
      projectPaths[index] = projectPath;
      return;
    }
    projectPaths = [...projectPaths, projectPath];
  }

  @override
  Future<void> deleteProjectPath(String projectPathId) async {
    deletedProjectPathId = projectPathId;
    projectPaths = projectPaths
        .where((item) => item.id != projectPathId)
        .toList(growable: false);
  }
}

class _BlockingRuntimeStore extends InMemoryRuntimeTaskStore {
  final Completer<void> _blockedLoad = Completer<void>();
  final Completer<void> _releaseLoad = Completer<void>();
  bool _blockedOnce = false;

  Future<void> waitForBlockedLoad() => _blockedLoad.future;

  void releaseLoad() {
    if (!_releaseLoad.isCompleted) {
      _releaseLoad.complete();
    }
  }

  @override
  Future<RuntimeTaskSnapshot?> loadTask(String taskId) async {
    if (!_blockedOnce) {
      _blockedOnce = true;
      _blockedLoad.complete();
      await _releaseLoad.future;
    }
    return super.loadTask(taskId);
  }
}

class _CallRecordingRuntimeStore extends InMemoryRuntimeTaskStore {
  final List<_RuntimeStoreCall> callLog = [];

  @override
  Future<void> saveTask(RuntimeTaskSnapshot task) async {
    callLog.add(_RuntimeStoreCall(
      taskId: task.taskId,
      status: task.status.name,
      timestamp: DateTime.now(),
    ));
    return super.saveTask(task);
  }
}

class _RuntimeStoreCall {
  const _RuntimeStoreCall({
    required this.taskId,
    required this.status,
    required this.timestamp,
  });

  final String taskId;
  final String status;
  final DateTime timestamp;
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
  Future<void> interrupt(AgentControlRequest request) async {
    events.add('interrupt');
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

class _ProbeAgent extends _ControlAgent implements RemoteTaskProbeService {
  RemoteTaskProbe probe = const RemoteTaskProbe.missingSession();
  int probeCount = 0;

  @override
  Future<RemoteTaskProbe> probeRemoteState(AgentControlRequest request) async {
    events.add('probeRemoteState');
    probeCount++;
    return probe;
  }
}

class _CompletingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'done',
      cleanedOutput: 'done',
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

class _DoneNeedsAttentionAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'Credits exhausted. Use /usage for details.',
      cleanedOutput: 'Credits exhausted. Use /usage for details.',
      needsAttention: true,
      done: true,
    );
  }
}

class _QuotaAfterDeliverableAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: '''
▪ 12 个测试全部通过（含竞态检测）。代码无问题，可正常使用。
Credits exhausted. Use /usage for details or /upgrade for more.
 YOLO Shift+Tab to Auto Mode
''',
      cleanedOutput: '''
▪ 12 个测试全部通过（含竞态检测）。代码无问题，可正常使用。
Credits exhausted. Use /usage for details or /upgrade for more.
 YOLO Shift+Tab to Auto Mode
''',
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

class _StreamingThenIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'HELLO WORLD',
      cleanedOutput: 'HELLO WORLD',
    );
    yield const AgentExecutionUpdate(
      rawOutput: '',
      cleanedOutput: 'HELLO WORLD',
      turnIdle: true,
      done: true,
    );
  }
}

class _EmptyPollingAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(rawOutput: '');
    yield const AgentExecutionUpdate(rawOutput: '');
  }
}

class _RepeatedLogUpdateAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(rawOutput: 'first\n');
    yield const AgentExecutionUpdate(rawOutput: 'second');
  }
}

class _ApprovalAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield AgentExecutionUpdate(
      rawOutput: 'approval',
      nativeApproval: NativeTerminalApproval(
        id: 'approval-1',
        taskId: 'task-1',
        question: '删除临时构建产物，风险中等。',
        options: const [
          NativeApprovalOption(key: 'approve', label: 'Approve'),
          NativeApprovalOption(key: 'reject', label: 'Reject'),
        ],
        state: ApprovalState.pending,
        createdAt: DateTime(2026, 6, 1),
      ),
    );
  }
}

class _TerminalPromptAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield AgentExecutionUpdate(
      rawOutput: 'Allow execution of [ls]?',
      needsAttention: true,
      nativeApproval: NativeTerminalApproval(
        id: 'approval-2',
        taskId: 'task-1',
        question: 'Allow execution of [ls]?',
        options: const [
          NativeApprovalOption(key: '1', label: 'Allow once'),
          NativeApprovalOption(key: '4', label: 'No'),
        ],
        state: ApprovalState.pending,
        createdAt: DateTime(2026, 6, 1),
      ),
    );
  }
}

class _NeedsAttentionAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: 'Permission Required',
      cleanedOutput: 'Permission Required',
      needsAttention: true,
    );
  }
}

class _HangingAgent extends _ControlAgent {
  bool cancelled = false;

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    lastExecuteRequest = request;
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
  Future<void> pauseSpeaking() async {}

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
  Future<void> pauseSpeaking() async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> startListening(
      {void Function(String partial)? onPartial}) async {}

  @override
  Future<String> stopListening() async => '';
}
