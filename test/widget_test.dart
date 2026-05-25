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
    expect(find.text('当前任务'), findsOneWidget);
    expect(find.text('最近任务'), findsOneWidget);
    expect(find.text('新任务'), findsOneWidget);
  });
}
