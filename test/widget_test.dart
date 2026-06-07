import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:armin/app.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
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

  testWidgets('Armin reloads state when app resumes', (tester) async {
    final state = _CountingAppState();

    await tester.pumpWidget(ArminApp(state: state));
    await tester.pumpAndSettle();

    expect(state.loadCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(state.loadCount, 2);
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

  @override
  Future<void> load() async {
    loadCount += 1;
    await super.load();
  }
}
