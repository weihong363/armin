import 'package:armin/app.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/agent/services/mock_agent_session_service.dart';
import 'features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('Armin home renders mock task queue', (tester) async {
    await tester.pumpWidget(
      ArminApp(
        state: ArminAppState(
          store: InMemoryTaskHistoryStore(),
          agentSessionService: MockAgentSessionService(),
          voiceService: MockVoiceService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Armin'), findsOneWidget);
    expect(find.text('创建任务，让它去跑'), findsOneWidget);
    expect(find.text('还没有活跃任务'), findsOneWidget);
    expect(find.text('创建第一个任务'), findsOneWidget);
    expect(find.text('新建任务'), findsOneWidget);
  });

  testWidgets('home opens the scheduled task manager', (tester) async {
    await tester.pumpWidget(
      ArminApp(
        state: ArminAppState(
          store: InMemoryTaskHistoryStore(),
          agentSessionService: MockAgentSessionService(),
          voiceService: MockVoiceService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home-schedule-button')));
    await tester.pumpAndSettle();

    expect(find.text('计划任务'), findsOneWidget);
    expect(find.text('暂无计划任务'), findsOneWidget);
  });

  testWidgets('settings exposes notification permission state', (tester) async {
    await tester.pumpWidget(
      ArminApp(
        state: ArminAppState(
          store: InMemoryTaskHistoryStore(),
          agentSessionService: MockAgentSessionService(),
          voiceService: MockVoiceService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-notifications')));
    await tester.pumpAndSettle();

    expect(find.text('任务通知'), findsOneWidget);
    expect(find.text('当前平台暂不支持'), findsOneWidget);
  });

  testWidgets('settings exposes native model capability', (tester) async {
    await tester.pumpWidget(
      ArminApp(
        state: ArminAppState(
          store: InMemoryTaskHistoryStore(),
          agentSessionService: MockAgentSessionService(),
          voiceService: MockVoiceService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-slm')));
    await tester.pumpAndSettle();

    expect(find.text('端侧模型'), findsOneWidget);
    expect(find.text('模型不可用'), findsOneWidget);
    expect(find.text('运行时'), findsOneWidget);
    expect(find.text('模型文件'), findsOneWidget);
  });

  testWidgets('Armin resumes runtime without reloading app state',
      (tester) async {
    final state = _CountingAppState();

    await tester.pumpWidget(ArminApp(state: state));
    await tester.pumpAndSettle();

    expect(state.loadCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(state.loadCount, 1);
    expect(state.resumeCount, 1);
    expect(state.isRuntimeForeground, isTrue);
  });
}

class _CountingAppState extends ArminAppState {
  _CountingAppState()
      : super(
          store: InMemoryTaskHistoryStore(),
          agentSessionService: MockAgentSessionService(),
          voiceService: MockVoiceService(),
        );

  int loadCount = 0;
  int resumeCount = 0;

  @override
  Future<void> load() async {
    loadCount += 1;
    await super.load();
  }

  @override
  Future<void> resumeRuntime() async {
    resumeCount += 1;
    await super.resumeRuntime();
  }
}
