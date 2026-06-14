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

  test('watcher cleans tui graphics before storing current action', () async {
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
    final updated = await runtime.observeOutput(
      taskId: 'task-1',
      capturedOutput: '''
Thinking
│ I should inspect the implementation.
▫ Bash(cd /repo && flutter test)
┌──────────┬────────────┐
│ 功能分类 │ 功能名称   │
└──────────┴────────────┘
▪ README.md 已写入，包含完整使用示例。
''',
      now: now,
    );

    expect(updated?.action, 'README.md 已写入，包含完整使用示例。');
    expect(updated?.currentStep, 'README.md 已写入，包含完整使用示例。');
    expect(updated?.summary, 'README.md 已写入，包含完整使用示例。');
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

  test('bridge runtime returns reconcile decision for attention probe',
      () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );

    final decisions = await runtime.reconcileOnce(
      targets: const [
        RuntimeReconcileTarget(
          taskId: 'task-1',
          status: RuntimeTaskStatus.running,
        ),
      ],
      probe: (_) async => const RuntimeRemoteProbe(
        sessionExists: true,
        snapshot: 'Apply this change?',
        needsAttention: true,
      ),
    );

    expect(decisions.single.taskId, 'task-1');
    expect(decisions.single.action, RuntimeReconcileAction.refresh);
    expect(decisions.single.reason, RuntimeReconcileReason.needsAttention);
  });

  test('bridge runtime returns refreshAsIdle after stable output', () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );
    const targets = [
      RuntimeReconcileTarget(
        taskId: 'task-1',
        status: RuntimeTaskStatus.running,
      ),
    ];

    final first = await runtime.reconcileOnce(
      targets: targets,
      probe: (_) async => const RuntimeRemoteProbe(
        sessionExists: true,
        snapshot: 'HELLO WORLD',
      ),
    );
    final second = await runtime.reconcileOnce(
      targets: targets,
      probe: (_) async => const RuntimeRemoteProbe(
        sessionExists: true,
        snapshot: 'HELLO WORLD',
      ),
    );

    expect(first, isEmpty);
    expect(second.single.action, RuntimeReconcileAction.refreshAsIdle);
    expect(second.single.markIdleIfNoAttention, isTrue);
  });

  test('bridge runtime limits reconcile probes per run', () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );
    var probeCount = 0;

    await runtime.reconcileOnce(
      targets: const [
        RuntimeReconcileTarget(
          taskId: 'task-1',
          status: RuntimeTaskStatus.running,
        ),
        RuntimeReconcileTarget(
          taskId: 'task-2',
          status: RuntimeTaskStatus.running,
        ),
        RuntimeReconcileTarget(
          taskId: 'task-3',
          status: RuntimeTaskStatus.running,
        ),
      ],
      maxTasksPerRun: 2,
      probe: (_) async {
        probeCount++;
        return const RuntimeRemoteProbe(sessionExists: true);
      },
    );

    expect(probeCount, 2);
  });

  test('bridge runtime skips timed out probe and continues candidates',
      () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );

    final decisions = await runtime.reconcileOnce(
      targets: const [
        RuntimeReconcileTarget(
          taskId: 'slow-task',
          status: RuntimeTaskStatus.running,
        ),
        RuntimeReconcileTarget(
          taskId: 'attention-task',
          status: RuntimeTaskStatus.running,
        ),
      ],
      probeTimeout: const Duration(milliseconds: 1),
      probe: (target) async {
        if (target.taskId == 'slow-task') {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return const RuntimeRemoteProbe(sessionExists: true);
        }
        return const RuntimeRemoteProbe(
          sessionExists: true,
          needsAttention: true,
        );
      },
    );

    expect(decisions, hasLength(1));
    expect(decisions.single.taskId, 'attention-task');
    expect(decisions.single.reason, RuntimeReconcileReason.needsAttention);
  });

  test('bridge runtime reconcile loop catches load target failures', () async {
    final runtime = BridgeRuntime(
      taskStore: InMemoryRuntimeTaskStore(),
      eventBus: RuntimeEventBus(),
    );
    var loadAttempts = 0;

    runtime.startReconcileLoop(
      interval: const Duration(milliseconds: 1),
      loadTargets: () async {
        loadAttempts++;
        throw StateError('storage temporarily unavailable');
      },
      probe: (_) async => const RuntimeRemoteProbe(sessionExists: true),
      onDecision: (_) async {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    runtime.stopReconcileLoop();

    expect(loadAttempts, greaterThan(0));
  });
}
