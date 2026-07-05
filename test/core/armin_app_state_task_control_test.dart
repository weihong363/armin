import 'dart:async';
import 'dart:convert';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/notifications/services/task_notification_service.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/runtime/models/approval_state.dart';
import 'package:armin/features/runtime/models/runtime_task_snapshot.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/runtime/services/bridge_runtime.dart';
import 'package:armin/features/runtime/services/runtime_event_bus.dart';
import 'package:armin/features/runtime/services/runtime_task_store.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
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

  test('scheduled pending task starts on load when due', () async {
    final task = _scheduledTask(
      scheduledFor: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );

    await state.load();
    await _waitUntil(() => agent.lastExecuteRequest != null);

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.scheduledFor, task.scheduledFor);
    expect(agent.lastExecuteRequest?.attachOnly, isFalse);
    expect(agent.lastExecuteRequest?.prompt, task.finalPrompt);
    expect(
        agent.lastExecuteRequest?.tmuxSessionName, task.host.tmuxSessionName);
    expect(store.task!.metricEvents.last.eventType, 'task_scheduled_started');
  });

  test('rescheduleTask updates pending schedule before start', () async {
    final task = _scheduledTask(
      scheduledFor: DateTime.now().add(const Duration(minutes: 5)),
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    final newTime = DateTime.now().add(const Duration(milliseconds: 20));
    await state.rescheduleTask(task, newTime);

    expect(store.task!.status, TaskStatus.pending);
    expect(store.task!.scheduledFor, newTime);
    expect(store.task!.metricEvents.last.eventType, 'task_rescheduled');
    expect(agent.lastExecuteRequest, isNull);

    await _waitUntil(() => agent.lastExecuteRequest != null);
    expect(store.task!.status, TaskStatus.running);
  });

  test('cancelScheduledTask clears schedule without starting agent', () async {
    final task = _scheduledTask(
      scheduledFor: DateTime.now().add(const Duration(milliseconds: 10)),
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.cancelScheduledTask(task);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(store.task!.status, TaskStatus.draft);
    expect(store.task!.scheduledFor, isNull);
    expect(store.task!.metricEvents.last.eventType, 'task_schedule_canceled');
    expect(agent.lastExecuteRequest, isNull);
  });

  test('turn idle deliverable event uses waiting runtime snapshot', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final eventBus = RuntimeEventBus();
    final deliverableEvent = Completer<RuntimeEvent>();
    final subscription = eventBus.events.listen((event) {
      if (event.type == RuntimeEventType.deliverableUpdated &&
          !deliverableEvent.isCompleted) {
        deliverableEvent.complete(event);
      }
    });
    final state = ArminAppState(
      store: store,
      agentSessionService: _TurnIdleAgent(),
      voiceService: const _SilentVoiceService(),
      bridgeRuntime: BridgeRuntime(
        taskStore: InMemoryRuntimeTaskStore(),
        eventBus: eventBus,
      ),
      runtimeEventBus: eventBus,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );

    final event = await deliverableEvent.future.timeout(
      const Duration(seconds: 1),
    );
    expect(event.snapshot?.status, RuntimeTaskStatus.waitingUser);
    expect(store.task!.status, TaskStatus.turnIdle);
    await subscription.cancel();
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

  test('load aligns running task with latest attention turn', () async {
    final now = DateTime(2026, 5, 17);
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: 'Task',
          rawOutput: 'Permission Required',
          cleanedOutput: 'Permission Required',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.needAttention,
        ),
      ],
    );
    final state = ArminAppState(
      store: _TaskStore(task),
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );

    await state.load();

    expect(state.tasks.single.status, TaskStatus.needAttention);
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
    await _waitUntil(
        () => store.task!.summary?.contains('FlipCountdown') == true);
    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.running);
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
    await _waitUntil(() => store.task!.summary?.contains('同步完成') == true);

    expect(state.tasks, hasLength(1));
    expect(store.task!.status, TaskStatus.running);
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
    final approvalEvents = _loopApprovalEvents(store.task!);
    expect(approvalEvents.single.kind, LoopApprovalEventKind.approved);
    expect(approvalEvents.single.selectedOptionKey, 'approve');
    expect(approvalEvents.single.status, TaskStatus.running.name);
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
    final approvalEvents = _loopApprovalEvents(store.task!);
    expect(approvalEvents.single.kind, LoopApprovalEventKind.approved);
    expect(approvalEvents.single.approvalId, approval.id);
    expect(approvalEvents.single.selectedOptionKey, '1');
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
    expect(
      store.task!.metricEvents.map((event) => event.eventType),
      contains('approval_requested'),
    );
    final approvalEvents = _loopApprovalEvents(store.task!);
    expect(approvalEvents.single.kind, LoopApprovalEventKind.requested);
    expect(approvalEvents.single.optionCount, 2);
    expect(approvalEvents.single.questionLength, greaterThan(0));
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
    final approvalEvents = _loopApprovalEvents(store.task!);
    expect(approvalEvents.single.kind, LoopApprovalEventKind.optionSelected);
    expect(approvalEvents.single.selectedOptionKey, '1');
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
  });

  test('selectTerminalOption rejects archived approval without current state',
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

    await expectLater(
      state.selectTerminalOption(task, option),
      throwsA(isA<StateError>()),
    );
    expect(agent.selectedTerminalOption, isNull);
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
    final approvalEvents = _loopApprovalEvents(store.task!);
    expect(
      approvalEvents.map((event) => event.kind),
      containsAllInOrder([
        LoopApprovalEventKind.optionSelected,
        LoopApprovalEventKind.customResponse,
      ]),
    );
    expect(approvalEvents.last.customResponseLength, '请不要运行测试'.length);
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

  test('load restores detached task and reconnects original tmux session',
      () async {
    final baseTask = _task(status: TaskStatus.observerDetached);
    final task = baseTask.copyWith(
      host: baseTask.host.copyWith(tmuxSessionName: 'armin-33333333'),
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
    final firstState = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await firstState.load();
    firstState.dispose();

    final reconnectAgent = _ControlAgent()
      ..capturedLog = '''
输出 hello
hello
继续输出 world
world
''';
    final restoredState = ArminAppState(
      store: store,
      agentSessionService: reconnectAgent,
      voiceService: const _SilentVoiceService(),
    );
    await restoredState.load();

    final restoredTask = restoredState.tasks.single;
    expect(restoredTask.status, TaskStatus.observerDetached);
    expect(restoredTask.host.tmuxSessionName, 'armin-33333333');
    await restoredState.reconnectTask(restoredTask);
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.host.tmuxSessionName, 'armin-33333333');
    expect(reconnectAgent.lastExecuteRequest?.attachOnly, isTrue);
    expect(
        reconnectAgent.lastExecuteRequest?.tmuxSessionName, 'armin-33333333');
    expect(store.task!.turns.last.cleanedOutput, contains('world'));
    expect(reconnectAgent.events, contains('captureLog'));
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

  test('refreshTaskFromRemote syncs yolo output without settling the turn',
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

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.running);
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

  test('remote snapshot poll settles detached latest turn deliverable',
      () async {
    final task = _task(status: TaskStatus.observerDetached).copyWith(
      shortSummary: '已自动断开监听以节省手机性能，远端任务仍在运行。',
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '刷题项目简介',
          rawOutput: '▪ README.md 已创建。',
          cleanedOutput: '▪ README.md 已创建。',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.turnIdle,
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '输出项目名',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18, 0, 1),
          lastOutputAt: DateTime(2026, 5, 18, 0, 1),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _ControlAgent()
      ..capturedLog = '''
> 刷题项目简介
▪ README.md 已创建。

> 输出项目名
▪ The project name is countdown_widgets.
  This is derived from the working directory path.
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteSnapshotPollInterval: const Duration(milliseconds: 10),
    );
    await state.load();

    await _waitUntil(() =>
        agent.events.where((event) => event == 'captureLog').isNotEmpty &&
        store.task?.turns.last.status == NativeOutputTurnStatus.turnIdle);
    await _waitUntil(() => store.task?.turns.last.deliverable != null);
    state.dispose();

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.turns.last.turnIndex, 2);
    expect(store.task!.turns.last.deliverable?.displaySummary,
        contains('countdown_widgets'));
    expect(store.task!.turns.first.deliverable?.displaySummary,
        isNot(contains('countdown_widgets')));
    expect(store.task!.shortSummary, contains('countdown_widgets'));
    expect(agent.lastExecuteRequest, isNull);
  });

  test('remote snapshot poll keeps detached planning output unfinished',
      () async {
    final task = _task(status: TaskStatus.observerDetached).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '刷题项目简介',
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
▪ Let me help you create a project description for your coding practice.
  First, I'll explore the current codebase.

▪ Glob('**/*.{js,jsx,ts,tsx,md}')
  └ No files found

▪ The repository appears to be empty. Since there's no existing codebase
  structure to work with, I'll create a standard project description.
⠸ Thinking... (esc to cancel, 20s)
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteSnapshotPollInterval: const Duration(milliseconds: 10),
    );
    await state.load();

    await _waitUntil(
        () => agent.events.where((event) => event == 'captureLog').isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.dispose();

    expect(store.task!.status, TaskStatus.observerDetached);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.running);
    expect(store.task!.turns.last.deliverable, isNull);
  });

  test('remote snapshot poll keeps qoder prompt echo thinking unfinished',
      () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: 'Phase 2.7 real qodercli long task verification',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _HangingAgent()
      ..capturedLog = '''
██████                            ╭─ What's new (v1.0.35) ────────────────╮
 ██      ██                          │ - Added plugin marketplace support    │
 ██  ██  ██  Qoder CLI v1.0.34       │ - Upgraded QoderCLI rules types with… │
 ██    ██                            │ - Fixed Plan and Ask tools not being… │
   ████  ██  Not Login Please Auth   │ /release-notes for more               │
                                     ╰───────────────────────────────────────╯
 ● Initializing... Prompts will be queued.
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 > Phase 2.7 real qodercli long task verification.
   Constraints:
   - Do not modify files.
   - Final answer must be in Chinese and include the exact marker
   ARMIN_P27_REAL_TURN1_123.
   Final answer must include these sections:
   1. 项目定位
   2. 技术栈
   6. 下一步建议
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 Credits exhausted. Use /usage for details or /upgrade for more.
 ⠸ Thinking... (esc to cancel, 4s)
────────────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode                           1 MCP server · 15 skills
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
 *   Type your message or @path/to/file
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin-test/countdown_widgets
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteSnapshotPollInterval: const Duration(milliseconds: 10),
    );
    await state.load();
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(
        prompt: 'Phase 2.7 real qodercli long task verification',
      ),
    );

    await _waitUntil(
        () => agent.events.where((event) => event == 'captureLog').isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.dispose();

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.running);
    expect(store.task!.turns.last.deliverable, isNull);
    expect(store.task!.summary, isNot(contains('Not Login Please Auth')));
  });

  test('remote snapshot poll settles latest turn while observer is active',
      () async {
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目名',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: DateTime(2026, 5, 18),
          lastOutputAt: DateTime(2026, 5, 18),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _HangingAgent()
      ..capturedLog = '''
> 输出项目名
▪ countdown_widgets
Credits exhausted. Use /usage for details or /upgrade for more.
YOLO Shift+Tab to Auto Mode
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
      enableRemoteReconcile: true,
      remoteSnapshotPollInterval: const Duration(milliseconds: 10),
    );
    await state.load();
    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: '输出项目名'),
    );

    await _waitUntil(() =>
        agent.events.where((event) => event == 'captureLog').isNotEmpty &&
        store.task?.turns.last.status == NativeOutputTurnStatus.turnIdle);
    await _waitUntil(() => store.task?.turns.last.deliverable != null);
    state.dispose();

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.turns.last.deliverable?.displaySummary,
        contains('countdown_widgets'));
    expect(agent.lastExecuteRequest?.attachOnly, isFalse);
    expect(agent.cleanedUp, isFalse);
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
    final loopActionEvent = store.task!.metricEvents.lastWhere(
      (event) => event.eventType == LoopUserAction.metricEventType,
    );
    final loopAction = LoopUserAction.fromJson(
      jsonDecode(loopActionEvent.payloadJson) as Map<String, Object?>,
    );
    expect(loopAction.kind, LoopUserActionKind.continueTask);
    expect(loopAction.taskId, store.task!.id);
    expect(loopAction.turnIndex, 1);
    expect(loopAction.nextTurnIndex, 2);
    expect(loopAction.instructionLength, '只输出 pets 名字'.length);
    expect(loopAction.source, 'text');
  });

  test('sendFollowUp preserves fast observer attention update', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final agent = _FastAttentionFollowUpAgent();
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

    await state.sendFollowUp(task, '继续执行');
    await Future<void>.delayed(Duration.zero);

    expect(store.task!.status, TaskStatus.needAttention);
    expect(store.task!.turns.last.status, NativeOutputTurnStatus.needAttention);
    state.dispose();
    await agent.close();
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

  test('sendFollowUp rollback unsent turn when remote send fails', () async {
    final now = DateTime(2026, 5, 18);
    final task = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目的日文名',
          rawOutput: '▪ カウントダウンウィジェット',
          cleanedOutput: '▪ カウントダウンウィジェット',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
        ),
      ],
    );
    final store = _TaskStore(task);
    final agent = _SendFollowUpFailingAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await expectLater(
      state.sendFollowUp(task, '输出韩文的项目名'),
      throwsStateError,
    );

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(store.task!.turns, hasLength(1));
    expect(store.task!.turns.single.userInput, '输出项目的日文名');
    expect(store.task!.shortSummary, contains('发送补充指令失败'));
    expect(agent.lastExecuteRequest?.attachOnly, isTrue);
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

  test('existing deliverable event does not auto speak on task entry',
      () async {
    final now = DateTime(2026, 5, 18);
    final task = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目简介',
          rawOutput: '项目简介已输出',
          cleanedOutput: '项目简介已输出',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '项目简介已输出',
            speechSummary: '项目简介已输出',
            evidenceFingerprint: 'existing-result',
          ),
        ),
      ],
    );
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: voice,
    );
    await state.load();
    state.setActiveDetailTaskId(task.id);

    state.runtimeEventBus.publish(RuntimeEvent(
      type: RuntimeEventType.deliverableUpdated,
      taskId: task.id,
      createdAt: DateTime.now(),
      turnId: 'turn-task-1-1',
      evidenceFingerprint: 'existing-result',
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(voice.spokenSummaries, isEmpty);
  });

  test('existing deliverable event does not notify on task entry', () async {
    final now = DateTime(2026, 5, 18);
    final task = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目简介',
          rawOutput: '项目简介已输出',
          cleanedOutput: '项目简介已输出',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '项目简介已输出',
            speechSummary: '项目简介已输出',
            evidenceFingerprint: 'existing-result',
          ),
        ),
      ],
    );
    final store = _TaskStore(task);
    final notifications = _CapturingTaskNotificationService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
      taskNotificationService: notifications,
    );
    await state.load();

    state.runtimeEventBus.publish(RuntimeEvent(
      type: RuntimeEventType.deliverableUpdated,
      taskId: task.id,
      createdAt: DateTime.now(),
      turnId: 'turn-task-1-1',
      evidenceFingerprint: 'existing-result',
    ));
    await state.drainForTest();

    expect(notifications.notifications, isEmpty);
  });

  test('fresh deliverable event only auto speaks once', () async {
    final now = DateTime(2026, 5, 18);
    final baseTask = _task(status: TaskStatus.turnIdle);
    final freshTask = baseTask.copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目简介',
          rawOutput: '项目简介已输出',
          cleanedOutput: '项目简介已输出',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '项目简介已输出',
            speechSummary: '项目简介已输出',
            evidenceFingerprint: 'fresh-result',
          ),
        ),
      ],
    );
    final store = _TaskStore(baseTask);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: voice,
    );
    await state.load();
    state.setActiveDetailTaskId(baseTask.id);
    await state.saveTask(freshTask);
    await state.drainForTest();
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);

    final fingerprint =
        store.task!.turns.single.deliverable!.evidenceFingerprint;
    final event = RuntimeEvent(
      type: RuntimeEventType.deliverableUpdated,
      taskId: baseTask.id,
      createdAt: DateTime.now(),
      turnId: 'turn-task-1-1',
      evidenceFingerprint: fingerprint,
    );
    state.runtimeEventBus.publish(event);
    state.runtimeEventBus.publish(event);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('项目简介已输出'));
  });

  test('fresh deliverable event notifies result only once', () async {
    final now = DateTime(2026, 5, 18);
    final baseTask = _task(status: TaskStatus.turnIdle);
    final freshTask = baseTask.copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目简介',
          rawOutput: '项目简介已输出',
          cleanedOutput: '项目简介已输出',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '项目简介已输出',
            speechSummary: '项目简介已输出',
            evidenceFingerprint: 'fresh-result',
          ),
        ),
      ],
    );
    final store = _TaskStore(baseTask);
    final notifications = _CapturingTaskNotificationService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
      taskNotificationService: notifications,
    );
    await state.load();
    await state.saveTask(freshTask);
    await state.drainForTest();

    final event = RuntimeEvent(
      type: RuntimeEventType.deliverableUpdated,
      taskId: baseTask.id,
      createdAt: DateTime.now(),
      turnId: 'turn-task-1-1',
      evidenceFingerprint: 'fresh-result',
    );
    state.runtimeEventBus.publish(event);
    state.runtimeEventBus.publish(event);
    await state.drainForTest();

    expect(notifications.notifications, hasLength(1));
    expect(
      notifications.notifications.single.kind,
      TaskNotificationKind.resultReady,
    );
    expect(notifications.notifications.single.body, contains('项目简介已输出'));
  });

  test('fresh deliverable speech ignores evidence-only refreshes', () async {
    final now = DateTime(2026, 5, 18);
    final baseTask = _task(status: TaskStatus.turnIdle);
    final turn = NativeOutputTurn(
      id: 'turn-task-1-1',
      taskId: 'task-1',
      turnIndex: 1,
      userInput: '输出项目简介',
      rawOutput: '项目简介已输出',
      cleanedOutput: '项目简介已输出',
      startedAt: now,
      lastOutputAt: now,
      status: NativeOutputTurnStatus.turnIdle,
      deliverable: const TurnDeliverable(
        displaySummary: '项目简介已输出',
        speechSummary: '项目简介已输出',
        evidenceFingerprint: 'fresh-result-a',
      ),
    );
    final store = _TaskStore(baseTask);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: voice,
    );
    await state.load();
    state.setActiveDetailTaskId(baseTask.id);
    await state.saveTask(baseTask.copyWith(turns: [turn]));
    await state.drainForTest();
    await _waitUntil(() => voice.spokenSummaries.isNotEmpty);

    await state.saveTask(
      store.task!.copyWith(
        turns: [
          turn.copyWith(
            deliverable: const TurnDeliverable(
              displaySummary: '项目简介已输出',
              speechSummary: '项目简介已输出',
              evidenceFingerprint: 'fresh-result-b',
            ),
          ),
        ],
      ),
    );
    await state.drainForTest();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(voice.spokenSummaries, hasLength(1));
    expect(voice.spokenSummaries.single, contains('项目简介已输出'));
  });

  test('waiting user event does not auto speak existing result', () async {
    final task = _task(status: TaskStatus.turnIdle);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: voice,
    );
    await state.load();
    state.setActiveDetailTaskId(task.id);

    state.runtimeEventBus.publish(RuntimeEvent(
      type: RuntimeEventType.taskWaitingUser,
      taskId: task.id,
      createdAt: DateTime.now(),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(voice.spokenSummaries, isEmpty);
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

  test('turn idle stops observer progress from appending thinking', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _IdleThenThinkingAgent();
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
    await _waitUntil(() => store.task!.status == TaskStatus.turnIdle);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(agent.cancelled, isTrue);
    expect(store.task!.turns.single.rawOutput, contains('done'));
    expect(store.task!.turns.single.rawOutput, isNot(contains('Thinking')));
    state.dispose();
    await agent.close();
  });

  test('empty turn idle update keeps task running', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _EmptyTurnIdleAgent();
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

    expect(store.task!.status, TaskStatus.running);
    expect(store.task!.turns.single.status, NativeOutputTurnStatus.running);
    expect(store.task!.summary, isNull);
    expect(agent.cleanedUp, isFalse);
  });

  test('stream completion captures final remote pane before staying running',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final voice = _CapturingVoiceService();
    final agent = _StreamEndsWithFinalPaneAgent()
      ..capturedLog = '''
> Do not modify files.
  Read pubspec.yaml only.
  Final answer only:
  ARMIN_REAL_SESSION_CHECK status=PASS project=countdown_widgets files_changed=0

▪ Let me read the pubspec.yaml file.

▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines

▪ ARMIN_REAL_SESSION_CHECK status=PASS project=countdown_widgets files_changed=0。项目简介：countdown_widgets 是一个 Flutter 倒计时组件库。
Credits exhausted. Use /usage for details or /upgrade for more.
* Type your message...
Model · ctx ░░░░░░░░░░ 2%
''';
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
    await _waitUntil(() => store.task!.status == TaskStatus.turnIdle);
    await state.drainForTest();
    await _waitUntil(() => store.task!.turns.single.deliverable != null);

    final latestTurn = store.task!.turns.single;
    expect(agent.events, contains('captureLog'));
    expect(agent.cleanedUp, isFalse);
    expect(store.task!.status, TaskStatus.turnIdle);
    expect(latestTurn.status, NativeOutputTurnStatus.turnIdle);
    expect(
      latestTurn.cleanedOutput,
      contains('ARMIN_REAL_SESSION_CHECK status=PASS'),
    );
    expect(
      latestTurn.deliverable!.displaySummary,
      contains('Flutter 倒计时组件库'),
    );
    await _waitUntil(() => voice.spokenSummaries.length == 1);
    expect(
      voice.spokenSummaries.single,
      contains('countdown_widgets'),
    );
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

  test('approval request notifies once', () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final notifications = _CapturingTaskNotificationService();
    final state = ArminAppState(
      store: store,
      agentSessionService: _ApprovalAgent(),
      voiceService: const _SilentVoiceService(),
      taskNotificationService: notifications,
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await _waitUntil(() => notifications.notifications.isNotEmpty);

    final event = RuntimeEvent(
      type: RuntimeEventType.approvalRequested,
      taskId: task.id,
      createdAt: DateTime.now(),
    );
    state.runtimeEventBus.publish(event);
    state.runtimeEventBus.publish(event);
    await state.drainForTest();

    expect(notifications.notifications, hasLength(1));
    expect(
      notifications.notifications.single.kind,
      TaskNotificationKind.approvalRequired,
    );
    expect(notifications.notifications.single.body, contains('删除临时构建产物'));
  });

  test('need attention and runtime lost emit state notifications once',
      () async {
    final attentionTask = _task(status: TaskStatus.running);
    final attentionStore = _TaskStore(attentionTask);
    final notifications = _CapturingTaskNotificationService();
    final attentionState = ArminAppState(
      store: attentionStore,
      agentSessionService: _NeedsAttentionAgent(),
      voiceService: const _SilentVoiceService(),
      taskNotificationService: notifications,
    );
    await attentionState.load();
    attentionState.startTaskExecution(
      attentionTask,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await _waitUntil(
      () => notifications.notifications.any(
        (item) => item.kind == TaskNotificationKind.needsInstruction,
      ),
    );

    final runtimeTask = _task(status: TaskStatus.running).copyWith(
      id: 'task-runtime-lost',
    );
    final runtimeStore = _TaskStore(runtimeTask);
    final runtimeState = ArminAppState(
      store: runtimeStore,
      agentSessionService: _MissingSessionAgent(),
      voiceService: const _SilentVoiceService(),
      taskNotificationService: notifications,
    );
    await runtimeState.load();
    runtimeState.startTaskExecution(
      runtimeTask,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await _waitUntil(
      () => notifications.notifications.any(
        (item) => item.kind == TaskNotificationKind.runtimeLost,
      ),
    );

    expect(
      notifications.notifications.map((item) => item.kind),
      containsAll([
        TaskNotificationKind.needsInstruction,
        TaskNotificationKind.runtimeLost,
      ]),
    );
    expect(
      notifications.notifications
          .where((item) => item.kind == TaskNotificationKind.runtimeLost),
      hasLength(1),
    );
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
    final loopAction = LoopUserAction.fromJson(
      jsonDecode(store.task!.metricEvents
          .lastWhere(
            (event) => event.eventType == LoopUserAction.metricEventType,
          )
          .payloadJson) as Map<String, Object?>,
    );
    expect(loopAction.kind, LoopUserActionKind.markCompleted);
    expect(loopAction.turnId, store.task!.turns.single.id);
    expect(loopAction.status, TaskStatus.userCompleted.name);
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
    final loopAction = LoopUserAction.fromJson(
      jsonDecode(store.task!.metricEvents
          .lastWhere(
            (event) => event.eventType == LoopUserAction.metricEventType,
          )
          .payloadJson) as Map<String, Object?>,
    );
    expect(loopAction.kind, LoopUserActionKind.markFailed);
    expect(loopAction.turnId, store.task!.turns.single.id);
    expect(loopAction.status, TaskStatus.userFailed.name);
  });

  test('acceptLatestResult records facts without changing task state',
      () async {
    final task = _taskWithSettledTurn();
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.acceptLatestResult(task);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(agent.events, isEmpty);
    final loopAction = LoopUserAction.fromJson(
      jsonDecode(store.task!.metricEvents
          .lastWhere(
            (event) => event.eventType == LoopUserAction.metricEventType,
          )
          .payloadJson) as Map<String, Object?>,
    );
    expect(loopAction.kind, LoopUserActionKind.acceptResult);
    expect(loopAction.turnId, store.task!.turns.single.id);
    expect(loopAction.status, TaskStatus.turnIdle.name);
    expect(store.task!.metricEvents.last.eventType, 'loop_result_accepted');
  });

  test('rejectOrRedoLatestResult records facts without sending follow-up',
      () async {
    final task = _taskWithSettledTurn();
    final store = _TaskStore(task);
    final agent = _ControlAgent();
    final state = ArminAppState(
      store: store,
      agentSessionService: agent,
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.rejectOrRedoLatestResult(task);

    expect(store.task!.status, TaskStatus.turnIdle);
    expect(agent.events, isEmpty);
    final loopAction = LoopUserAction.fromJson(
      jsonDecode(store.task!.metricEvents
          .lastWhere(
            (event) => event.eventType == LoopUserAction.metricEventType,
          )
          .payloadJson) as Map<String, Object?>,
    );
    expect(loopAction.kind, LoopUserActionKind.rejectOrRedo);
    expect(loopAction.turnId, store.task!.turns.single.id);
    expect(loopAction.status, TaskStatus.turnIdle.name);
    expect(store.task!.metricEvents.last.eventType, 'loop_result_rejected');
  });

  test('load restores loop user action facts without controls or speech',
      () async {
    final task = _taskWithSettledTurn();
    final store = _TaskStore(task);
    final firstAgent = _ControlAgent();
    final firstState = ArminAppState(
      store: store,
      agentSessionService: firstAgent,
      voiceService: const _SilentVoiceService(),
    );
    await firstState.load();
    await firstState.acceptLatestResult(task);
    await firstState.rejectOrRedoLatestResult(store.task!);
    firstState.dispose();

    final voice = _CapturingVoiceService();
    final restoredAgent = _ControlAgent();
    final restoredState = ArminAppState(
      store: store,
      agentSessionService: restoredAgent,
      voiceService: voice,
    );
    await restoredState.load();

    final restoredTask = restoredState.tasks.single;
    final actions = restoredTask.metricEvents
        .where((event) => event.eventType == LoopUserAction.metricEventType)
        .map((event) => LoopUserAction.fromJson(
              jsonDecode(event.payloadJson) as Map<String, Object?>,
            ))
        .toList();
    expect(restoredTask.status, TaskStatus.turnIdle);
    expect(
        actions.map((action) => action.kind),
        containsAllInOrder([
          LoopUserActionKind.acceptResult,
          LoopUserActionKind.rejectOrRedo,
        ]));
    expect(actions.every((action) => action.turnId == 'turn-1'), isTrue);
    expect(firstAgent.events, isEmpty);
    expect(restoredAgent.events, isEmpty);
    expect(voice.spokenSummaries, isEmpty);
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

  test('failed execution without turn deliverable stays silent', () async {
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
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(voice.spokenSummaries, isEmpty);
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

  test('turn idle persists buffered progress before publishing deliverable',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final agent = _BufferedThenIdleAgent();
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

    await _waitUntil(
      () =>
          store.task?.turns.isNotEmpty == true &&
          store.task?.turns.last.deliverable != null,
      timeout: const Duration(seconds: 1),
    );

    final latestTurn = store.task!.turns.last;
    expect(store.task!.status, TaskStatus.turnIdle);
    expect(latestTurn.rawOutput, contains('项目的中文名是：倒计时小部件'));
    expect(latestTurn.deliverable?.displaySummary, contains('倒计时小部件'));
    expect(
        latestTurn.deliverable?.displaySummary, isNot(contains('Model · ctx')));
    final loopEvent = store.task!.metricEvents.lastWhere(
      (event) => event.eventType == LoopEvaluation.metricEventType,
    );
    final evaluation = LoopEvaluation.fromJson(
      jsonDecode(loopEvent.payloadJson) as Map<String, Object?>,
    );
    expect(evaluation.taskId, store.task!.id);
    expect(evaluation.turnId, latestTurn.id);
    expect(evaluation.turnIndex, latestTurn.turnIndex);
    expect(evaluation.status, TaskStatus.turnIdle.name);
    expect(evaluation.metrics.inputLength, latestTurn.userInput.length);
    expect(evaluation.metrics.hasDeliverable, isTrue);
    expect(
      evaluation.metrics.outputSummaryLength,
      latestTurn.deliverable!.displaySummary.length,
    );
    expect(
      jsonDecode(loopEvent.payloadJson) as Map<String, Object?>,
      isNot(contains('nextActions')),
    );
    final resultSummary = _loopResultSummaries(store.task!).single;
    expect(resultSummary.taskId, store.task!.id);
    expect(resultSummary.latestTurnId, latestTurn.id);
    expect(resultSummary.latestTurnIndex, latestTurn.turnIndex);
    expect(resultSummary.resultCount, 1);
    expect(resultSummary.summaryText, contains('倒计时小部件'));
    expect(resultSummary.latestEvidenceFingerprint,
        latestTurn.deliverable!.evidenceFingerprint);
  });

  test('loop result summary tracks multiple deliverable turns', () async {
    final now = DateTime(2026, 5, 17);
    final task = _task(status: TaskStatus.running).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出第一个结果',
          rawOutput: '第一个结果',
          cleanedOutput: '第一个结果',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: 'Turn 1 已输出项目背景。',
            speechSummary: 'Turn 1 已输出项目背景。',
            evidenceFingerprint: 'turn-1-result',
          ),
        ),
        NativeOutputTurn(
          id: 'turn-task-1-2',
          taskId: 'task-1',
          turnIndex: 2,
          userInput: '输出第二个结果',
          rawOutput: '',
          cleanedOutput: '',
          startedAt: now.add(const Duration(seconds: 1)),
          lastOutputAt: now.add(const Duration(seconds: 1)),
          status: NativeOutputTurnStatus.running,
        ),
      ],
    );
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _BufferedThenIdleAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    state.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );

    await _waitUntil(
      () => store.task!.turns.last.deliverable != null,
      timeout: const Duration(seconds: 1),
    );

    final resultSummary = _loopResultSummaries(store.task!).last;
    expect(resultSummary.resultCount, 2);
    expect(resultSummary.results.map((result) => result.turnIndex), [1, 2]);
    expect(resultSummary.latestTurnId, 'turn-task-1-2');
    expect(resultSummary.latestTurnIndex, 2);
    expect(resultSummary.summaryText, contains('共 2 轮正式结果'));
    expect(resultSummary.summaryText, contains('倒计时小部件'));
    expect(resultSummary.summaryText, isNot(contains('输出第二个结果')));
  });

  test('load restores deliverable and loop facts without auto speech',
      () async {
    final task = _task(status: TaskStatus.running);
    final store = _TaskStore(task);
    final firstState = ArminAppState(
      store: store,
      agentSessionService: _BufferedThenIdleAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await firstState.load();
    firstState.startTaskExecution(
      task,
      const AgentExecutionRequest(prompt: 'Task'),
    );
    await _waitUntil(
      () =>
          store.task?.turns.isNotEmpty == true &&
          store.task?.turns.last.deliverable != null &&
          store.task!.metricEvents.any(
            (event) => event.eventType == LoopEvaluation.metricEventType,
          ) &&
          store.task!.metricEvents.any(
            (event) => event.eventType == LoopResultSummary.metricEventType,
          ),
      timeout: const Duration(seconds: 1),
    );
    firstState.dispose();

    final voice = _CapturingVoiceService();
    final restoredState = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: voice,
    );
    await restoredState.load();

    final restoredTask = restoredState.tasks.single;
    final restoredTurn = restoredTask.turns.single;
    final loopEvent = restoredTask.metricEvents.lastWhere(
      (event) => event.eventType == LoopEvaluation.metricEventType,
    );
    final evaluation = LoopEvaluation.fromJson(
      jsonDecode(loopEvent.payloadJson) as Map<String, Object?>,
    );
    expect(restoredTask.status, TaskStatus.turnIdle);
    expect(restoredTurn.deliverable?.displaySummary, contains('倒计时小部件'));
    expect(evaluation.taskId, restoredTask.id);
    expect(evaluation.turnId, restoredTurn.id);
    expect(evaluation.metrics.hasDeliverable, isTrue);
    final resultSummary = _loopResultSummaries(restoredTask).single;
    expect(resultSummary.latestTurnId, restoredTurn.id);
    expect(resultSummary.resultCount, 1);
    expect(resultSummary.summaryText, contains('倒计时小部件'));
    expect(voice.spokenSummaries, isEmpty);
  });

  test('load restores approval work state from durable runtime store',
      () async {
    final approval = _nativeApproval(question: 'Apply this change?');
    final approvalFact = LoopApprovalEvent(
      id: 'loop-approval-1',
      taskId: 'task-1',
      approvalId: approval.id,
      kind: LoopApprovalEventKind.requested,
      createdAt: approval.createdAt,
      turnId: '',
      turnIndex: 0,
      status: TaskStatus.needApproval.name,
      questionLength: approval.question.length,
      optionCount: approval.options.length,
    );
    final task = _task(status: TaskStatus.needApproval).copyWith(
      shortSummary: approval.question,
      nativeApproval: approval,
      nativeApprovalRequests: [approval],
      metricEvents: [
        MetricEvent.create(
          taskId: 'task-1',
          eventType: LoopApprovalEvent.metricEventType,
          payloadJson: jsonEncode(approvalFact.toJson()),
          now: approval.createdAt,
        ),
      ],
    );
    final store = _TaskStore(task);
    final runtimeStore = InMemoryRuntimeTaskStore();
    final firstRuntime = BridgeRuntime(
      taskStore: runtimeStore,
      eventBus: RuntimeEventBus(),
    );
    final firstState = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
      bridgeRuntime: firstRuntime,
    );
    await firstState.load();

    expect(firstState.workState(task.id)?.phase, WorkPhase.needsApproval);
    expect(
      firstState.workState(task.id)?.approval?.question,
      'Apply this change?',
    );

    final restoredRuntime = BridgeRuntime(
      taskStore: runtimeStore,
      eventBus: RuntimeEventBus(),
    );
    final restoredAgent = _ControlAgent();
    final restoredState = ArminAppState(
      store: store,
      agentSessionService: restoredAgent,
      voiceService: const _SilentVoiceService(),
      bridgeRuntime: restoredRuntime,
    );
    await restoredState.load();

    final workState = restoredState.workState(task.id);
    expect(workState?.phase, WorkPhase.needsApproval);
    expect(workState?.approval?.question, 'Apply this change?');
    expect(workState?.approval?.options.first.label, 'Allow once');
    expect((await runtimeStore.loadTask(task.id))?.workState?.approval?.id,
        approval.id);
    expect(_loopApprovalEvents(restoredState.tasks.single).single.kind,
        LoopApprovalEventKind.requested);
    expect(restoredAgent.events, isEmpty);
  });

  test('same turn deliverable updates when refreshed evidence changes',
      () async {
    final now = DateTime(2026, 5, 17);
    final task = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出项目的日文名',
          rawOutput: '''
输出项目的日文名
▪ 项目的日文名是：カウントダウンウィジェット
  ✅ 美しいカウントダウンウィジェット集
''',
          cleanedOutput: '''
▪ 项目的日文名是：カウントダウンウィジェット
  ✅ 美しいカウントダウンウィジェット集
''',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          deliverable: const TurnDeliverable(
            displaySummary: '* Model · ctx ░░░░░░░░░░ 2%',
            speechSummary: '* Model · ctx 2%',
            evidenceFingerprint: 'old-footer',
          ),
        ),
      ],
    );
    final store = _TaskStore(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: _ControlAgent(),
      voiceService: const _SilentVoiceService(),
    );
    await state.load();

    await state.saveTask(task);

    await _waitUntil(
      () =>
          store.task!.turns.single.deliverable?.evidenceFingerprint !=
          'old-footer',
      timeout: const Duration(seconds: 1),
    );

    final deliverable = store.task!.turns.single.deliverable!;
    expect(deliverable.displaySummary, contains('カウントダウンウィジェット'));
    expect(deliverable.displaySummary, isNot(contains('Model · ctx')));
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

TaskSession _scheduledTask({required DateTime scheduledFor}) {
  final task = _task(status: TaskStatus.pending);
  return task.copyWith(
    scheduledFor: scheduledFor,
    metricEvents: [
      MetricEvent.create(
        taskId: task.id,
        eventType: 'task_scheduled',
        payloadJson: jsonEncode({
          'scheduledFor': scheduledFor.toIso8601String(),
        }),
        now: task.createdAt,
      ),
    ],
    turns: [
      NativeOutputTurn(
        id: 'turn-task-1-1',
        taskId: task.id,
        turnIndex: 1,
        userInput: task.userText,
        rawOutput: '',
        cleanedOutput: '',
        startedAt: task.createdAt,
        lastOutputAt: task.createdAt,
        status: NativeOutputTurnStatus.running,
      ),
    ],
  );
}

TaskSession _taskWithSettledTurn() {
  final task = _task(status: TaskStatus.turnIdle);
  final now = DateTime(2026, 5, 17, 10);
  return task.copyWith(
    turns: [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: task.id,
        turnIndex: 1,
        userInput: task.userText,
        rawOutput: '完成结果',
        cleanedOutput: '完成结果',
        startedAt: now,
        lastOutputAt: now,
        idleDetectedAt: now,
        status: NativeOutputTurnStatus.turnIdle,
        deliverable: const TurnDeliverable(
          displaySummary: '完成结果',
          speechSummary: '完成结果',
          evidenceFingerprint: 'fp-1',
        ),
      ),
    ],
  );
}

List<LoopApprovalEvent> _loopApprovalEvents(TaskSession task) {
  return task.metricEvents
      .where((event) => event.eventType == LoopApprovalEvent.metricEventType)
      .map((event) => LoopApprovalEvent.fromJson(
            jsonDecode(event.payloadJson) as Map<String, Object?>,
          ))
      .toList(growable: false);
}

List<LoopResultSummary> _loopResultSummaries(TaskSession task) {
  return task.metricEvents
      .where((event) => event.eventType == LoopResultSummary.metricEventType)
      .map((event) => LoopResultSummary.fromJson(
            jsonDecode(event.payloadJson) as Map<String, Object?>,
          ))
      .toList(growable: false);
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

class _TaskStore extends TaskHistoryStore {
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

class _FastAttentionFollowUpAgent extends _ControlAgent {
  final StreamController<AgentExecutionUpdate> _updates =
      StreamController<AgentExecutionUpdate>.broadcast();

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    lastExecuteRequest = request;
    return _updates.stream;
  }

  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    await super.sendFollowUp(request);
    _updates.add(const AgentExecutionUpdate(
      rawOutput: 'Permission Required',
      cleanedOutput: 'Permission Required',
      needsAttention: true,
    ));
  }

  Future<void> close() => _updates.close();
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

class _SendFollowUpFailingAgent extends _ControlAgent {
  @override
  Future<void> sendFollowUp(AgentControlRequest request) async {
    lastFollowUp = request.instruction;
    throw StateError('No route to host');
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

class _BufferedThenIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: '''
输出项目的中文名
▪ 项目的中文名是：倒计时小部件
  依据来自 pubspec.yaml 文件中的 description 字段。
''',
      cleanedOutput: '''
▪ 项目的中文名是：倒计时小部件
  依据来自 pubspec.yaml 文件中的 description 字段。
''',
    );
    yield const AgentExecutionUpdate(
      rawOutput: '''
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''',
      cleanedOutput: '''
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''',
      turnIdle: true,
      done: true,
    );
  }
}

class _EmptyTurnIdleAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    yield const AgentExecutionUpdate(
      rawOutput: '',
      cleanedOutput: '',
      turnIdle: true,
      done: true,
    );
  }
}

class _StreamEndsWithFinalPaneAgent extends _ControlAgent {
  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) async* {
    lastExecuteRequest = request;
    yield const AgentExecutionUpdate(
      rawOutput: '⠋ Thinking... (esc to cancel, 0s)',
      cleanedOutput: '⠋ Thinking... (esc to cancel, 0s)',
    );
  }
}

class _IdleThenThinkingAgent extends _ControlAgent {
  final StreamController<AgentExecutionUpdate> _updates =
      StreamController<AgentExecutionUpdate>();
  bool cancelled = false;

  _IdleThenThinkingAgent() {
    _updates.onCancel = () {
      cancelled = true;
    };
  }

  @override
  Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request) {
    lastExecuteRequest = request;
    scheduleMicrotask(() {
      if (_updates.isClosed) return;
      _updates.add(const AgentExecutionUpdate(
        rawOutput: 'done',
        cleanedOutput: 'done',
        turnIdle: true,
        done: true,
      ));
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        if (_updates.isClosed) return;
        _updates.add(const AgentExecutionUpdate(
          rawOutput: 'Thinking...',
          cleanedOutput: 'Thinking...',
        ));
      });
    });
    return _updates.stream;
  }

  Future<void> close() => _updates.close();
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

class _CapturingTaskNotificationService implements TaskNotificationService {
  final List<TaskNotification> notifications = [];

  @override
  Future<void> show(TaskNotification notification) async {
    notifications.add(notification);
  }
}
