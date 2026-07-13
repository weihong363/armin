import 'dart:convert';

import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/ai/services/native_slm_client.dart';
import 'package:armin/features/history/screens/audit_history_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/notifications/services/task_notification_service.dart';
import 'package:armin/features/runtime/models/runtime_task_snapshot.dart';
import 'package:armin/features/runtime/services/bridge_runtime.dart';
import 'package:armin/features/runtime/services/runtime_event_bus.dart';
import 'package:armin/features/runtime/services/runtime_task_store.dart';
import 'package:armin/features/tasks/models/loop_evaluation.dart';
import 'package:armin/features/tasks/models/metric_event.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_recurrence.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/screens/scheduled_tasks_screen.dart';
import 'package:armin/features/tasks/services/loop_evaluation_assistant.dart';
import 'package:armin/features/tasks/services/loop_quality_analyzer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/features/agent/services/mock_agent_session_service.dart';
import '../test/features/voice/services/mock_voice_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('P3-PRODUCT-01..08 productization device gate', (tester) async {
    final store = InMemoryTaskHistoryStore();
    final task = _task();
    await store.saveTask(task);
    final state = ArminAppState(
      store: store,
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
      taskNotificationService: NativeTaskNotificationService(),
    );
    await state.load();

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: ScheduledTasksScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('计划任务'), findsOneWidget);
    expect(find.text('产品化真机门禁'), findsOneWidget);
    expect(find.textContaining('每天'), findsOneWidget);

    final permission = await state.taskNotificationService.permissionStatus();
    expect(permission, isNot(TaskNotificationPermission.unsupported));

    const highRiskAction = LoopNextAction(
      id: 'cleanup_generated_files',
      title: '清理生成文件',
      reason: '涉及删除，需要用户确认。',
      draft: '删除生成文件。',
      policy: LoopNextActionPolicy.confirmationRequired,
    );
    final confirmed = await state.confirmLoopNextAction(
      task,
      highRiskAction,
      instruction: '仅删除 build/tmp 中已确认的生成文件。',
    );
    expect(confirmed, isTrue);
    final updated = state.tasks.firstWhere((item) => item.id == task.id);
    expect(updated.turns, hasLength(2));
    expect(
      updated.metricEvents.any((event) {
        if (event.eventType != LoopAutoAction.metricEventType) return false;
        final payload = jsonDecode(event.payloadJson) as Map<String, Object?>;
        return payload['state'] == LoopAutoActionState.confirmed.name;
      }),
      isTrue,
    );

    final slm = await const NativeSlmClient().capability();
    expect(slm.backend, 'llama.cpp');
    expect(slm.modelPath, endsWith('/files/slm/model.gguf'));
    expect(slm.modelPath, isNot(contains('/data/local/tmp/')));
    expect(slm.message, isNotEmpty);

    final quality = const LoopQualityAnalyzer().analyze(task);
    expect(quality.evaluatedTurns, 1);
    expect(quality.deliverableTurns, 1);
    expect(quality.acceptanceRate, 1);

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: AuditHistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('审计历史'), findsOneWidget);
    expect(find.text('Loop 评估'), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'loop_evaluated');
    await tester.pumpAndSettle();
    expect(find.text('Loop 评估'), findsOneWidget);

    final runtimeStore = InMemoryRuntimeTaskStore();
    final runtime = BridgeRuntime(
      taskStore: runtimeStore,
      eventBus: RuntimeEventBus(),
    );
    for (var index = 0; index < 3; index++) {
      await runtimeStore.saveEvent(
        RuntimeEvent(
          type: RuntimeEventType.taskProgress,
          taskId: 'runtime-device-gate',
          createdAt: _now.add(Duration(seconds: index)),
          message: 'event-$index',
        ),
      );
    }
    final firstPage = <RuntimeEvent>[];
    final cursor = await runtime.replayArchivedEvents(
      taskId: 'runtime-device-gate',
      limit: 2,
      onEvent: firstPage.add,
    );
    final secondPage = <RuntimeEvent>[];
    await runtime.replayArchivedEvents(
      taskId: 'runtime-device-gate',
      afterArchiveId: cursor,
      onEvent: secondPage.add,
    );
    expect(firstPage, hasLength(2));
    expect(secondPage, hasLength(1));

    await runtimeStore.saveTask(
      RuntimeTaskSnapshot(
        taskId: 'runtime-device-gate',
        status: RuntimeTaskStatus.running,
        createdAt: _now,
        updatedAt: _now,
        sessionId: 'armin-runtime-device-gate',
      ),
    );
    final restoredRuntime = BridgeRuntime(
      taskStore: runtimeStore,
      eventBus: RuntimeEventBus(),
    );
    await restoredRuntime.restoreDurableState();
    final restored = await restoredRuntime.taskSnapshot('runtime-device-gate');
    expect(restored?.status, RuntimeTaskStatus.running);
    expect(restored?.sessionId, 'armin-runtime-device-gate');

    await state.drainForTest();
    state.dispose();
  });
}

final _now = DateTime(2026, 7, 12, 12);

TaskSession _task() {
  final evaluation = LoopEvaluation(
    id: 'evaluation-1',
    taskId: 'product-task',
    turnId: 'turn-1',
    turnIndex: 1,
    status: 'turnIdle',
    createdAt: _now,
    metrics: const LoopTurnMetrics(
      inputLength: 80,
      outputSummaryLength: 120,
      approvalCount: 0,
      retryCount: 0,
      waitMs: 3000,
      hasDeliverable: true,
    ),
  );
  final accepted = LoopUserAction(
    id: 'accepted-1',
    taskId: 'product-task',
    kind: LoopUserActionKind.acceptResult,
    createdAt: _now,
    turnId: 'turn-1',
    turnIndex: 1,
    status: 'turnIdle',
  );
  return TaskSession(
    id: 'product-task',
    host: HostConfig(
      id: 'host-product',
      name: 'Product Host',
      host: '127.0.0.1',
      port: 22,
      username: 'user',
      authType: HostAuthType.password,
      projectPath: '/tmp/project',
      tmuxSessionName: 'armin-product',
      agentCommand: 'qodercli',
      createdAt: _now,
      updatedAt: _now,
    ),
    title: '产品化真机门禁',
    createdAt: _now,
    updatedAt: _now,
    startedAt: _now,
    scheduledFor: DateTime.now().add(const Duration(days: 1)),
    recurrence: TaskRecurrence.daily,
    rawSttText: '',
    cleanedDraft: '',
    userText: '验证产品化能力',
    context: '',
    constraints: const {},
    finalPrompt: '',
    secretRecords: const [],
    approvalMode: AgentApprovalMode.balanced,
    metricEvents: [
      MetricEvent.create(
        taskId: 'product-task',
        eventType: LoopEvaluation.metricEventType,
        payloadJson: jsonEncode(evaluation.toJson()),
        now: _now,
      ),
      MetricEvent.create(
        taskId: 'product-task',
        eventType: LoopUserAction.metricEventType,
        payloadJson: jsonEncode(accepted.toJson()),
        now: _now.add(const Duration(seconds: 1)),
      ),
    ],
    turns: [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'product-task',
        turnIndex: 1,
        userInput: '验证产品化能力',
        rawOutput: '',
        cleanedOutput: '产品化验证完成。',
        startedAt: _now,
        lastOutputAt: _now,
        idleDetectedAt: _now,
        status: NativeOutputTurnStatus.turnIdle,
        deliverable: const TurnDeliverable(
          displaySummary: '产品化验证完成。',
          speechSummary: '产品化验证完成。',
          evidenceFingerprint: 'product-evidence',
        ),
      ),
    ],
  );
}
