import 'package:armin/features/runtime/models/runtime_task_snapshot.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/runtime/services/bridge_runtime.dart';
import 'package:armin/features/runtime/services/runtime_event_bus.dart';
import 'package:armin/features/runtime/services/runtime_task_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bridge runtime emits task lifecycle events through event bus',
      () async {
    final eventBus = RuntimeEventBus();
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: eventBus,
    );
    final events = <RuntimeEvent>[];
    final subscription = eventBus.events.listen(events.add);
    final now = DateTime(2026, 6, 7, 10);

    await runtime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-1',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await runtime.startTask(
      taskId: 'task-1',
      sessionName: 'work-project',
      projectPath: '/repo',
      tmuxSessionName: 'armin-task-1',
      now: now.add(const Duration(seconds: 1)),
    );
    await runtime.markWaitingUser(
      'task-1',
      summary: 'Needs your decision',
      now: now.add(const Duration(seconds: 2)),
    );
    await runtime.completeTask(
      'task-1',
      summary: 'Done',
      now: now.add(const Duration(seconds: 3)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      events.map((event) => event.type.wireName),
      containsAll([
        'TASK_CREATED',
        'TASK_STARTED',
        'OBSERVER_ATTACHED',
        'TASK_WAITING_USER',
        'TASK_COMPLETED',
      ]),
    );
    expect(
      events.map((event) => event.type),
      contains(RuntimeEventType.observerAttached),
    );
    expect(events.last.snapshot?.status, RuntimeTaskStatus.completed);

    await subscription.cancel();
    await eventBus.dispose();
  });

  test('bridge runtime reuses session for the same project and tmux name',
      () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );
    final now = DateTime(2026, 6, 7, 10);

    await runtime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-1',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final first = await runtime.startTask(
      taskId: 'task-1',
      sessionName: 'work-project',
      projectPath: '/repo',
      tmuxSessionName: 'armin-work',
      now: now,
    );

    await runtime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-2',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final second = await runtime.startTask(
      taskId: 'task-2',
      sessionName: 'work-project',
      projectPath: '/repo',
      tmuxSessionName: 'armin-work',
      now: now.add(const Duration(minutes: 1)),
    );

    expect(second.sessionId, first.sessionId);
    expect(
        runtime.sessionManager.sessions.single.taskIds, ['task-1', 'task-2']);
  });

  test('watcher stores incremental log offset and emits progress only',
      () async {
    final eventBus = RuntimeEventBus();
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: eventBus,
    );
    final events = <RuntimeEvent>[];
    final subscription = eventBus.events.listen(events.add);
    final now = DateTime(2026, 6, 7, 10);

    await runtime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-1',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await runtime.observeOutput(
      taskId: 'task-1',
      capturedOutput: 'Planning\nprogress: 20%\n',
      now: now,
    );
    final updated = await runtime.observeOutput(
      taskId: 'task-1',
      capturedOutput:
          'Planning\nprogress: 20%\nRefactoring Task Detail UI 60%\n',
      now: now.add(const Duration(seconds: 1)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(updated?.progress, 60);
    expect(updated?.action, 'Refactoring Task Detail UI 60%');
    expect(updated?.lastLogOffset,
        'Planning\nprogress: 20%\nRefactoring Task Detail UI 60%\n'.length);
    expect(
      events.map((event) => event.type),
      contains(RuntimeEventType.taskProgress),
    );

    await subscription.cancel();
    await eventBus.dispose();
  });

  test('watcher promotes attention and terminal states to runtime events',
      () async {
    final eventBus = RuntimeEventBus();
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: eventBus,
    );
    final events = <RuntimeEvent>[];
    final subscription = eventBus.events.listen(events.add);
    final now = DateTime(2026, 6, 7, 10);

    await runtime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-1',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final waiting = await runtime.observeOutput(
      taskId: 'task-1',
      capturedOutput: 'Waiting for user decision\n',
      now: now,
    );
    final completed = await runtime.observeOutput(
      taskId: 'task-1',
      capturedOutput:
          'Waiting for user decision\nTask completed successfully\n',
      now: now.add(const Duration(seconds: 1)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(waiting?.status, RuntimeTaskStatus.waitingUser);
    expect(completed?.status, RuntimeTaskStatus.completed);
    expect(
      events.map((event) => event.type.wireName),
      containsAll(['TASK_WAITING_USER', 'TASK_COMPLETED']),
    );

    await subscription.cancel();
    await eventBus.dispose();
  });

  test('bridge runtime restores durable work state and event history',
      () async {
    final store = InMemoryRuntimeTaskStore();
    final now = DateTime(2026, 6, 7, 10);
    final firstRuntime = BridgeRuntime(
      taskStore: store,
      eventBus: RuntimeEventBus(),
    );

    await firstRuntime.createTask(
      RuntimeTaskSnapshot(
        taskId: 'task-1',
        status: RuntimeTaskStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await firstRuntime.startTask(
      taskId: 'task-1',
      sessionName: 'work-project',
      projectPath: '/repo',
      tmuxSessionName: 'armin-task-1',
      now: now.add(const Duration(seconds: 1)),
    );
    await firstRuntime.markWaitingUser(
      'task-1',
      summary: 'Needs your instruction',
      now: now.add(const Duration(seconds: 2)),
    );
    await Future<void>.delayed(Duration.zero);

    final restoredRuntime = BridgeRuntime(
      taskStore: store,
      eventBus: RuntimeEventBus(),
    );
    await restoredRuntime.restoreDurableState();

    expect(
      restoredRuntime.workState('task-1')?.phase,
      WorkPhase.turnIdle,
    );
    expect(
      restoredRuntime.diagnostics('task-1')?.lastRuntimeEventType,
      RuntimeEventType.taskWaitingUser.wireName,
    );
    expect(await store.loadEvents(taskId: 'task-1'), hasLength(4));
  });
}
