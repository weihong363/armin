import 'package:armin/app_state_scope.dart';
import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/in_memory_task_history_store.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/projects/screens/project_path_list_screen.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('project path delete is blocked while active task uses path',
      (tester) async {
    await _pumpProjectPaths(tester);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('无法删除项目目录'), findsOneWidget);
    expect(find.textContaining('请先将它们停止或完成'), findsOneWidget);
    expect(find.text('Armin'), findsOneWidget);
  });

  testWidgets('project path edit is blocked while active task uses old path',
      (tester) async {
    await _pumpProjectPaths(tester);

    await tester.tap(find.text('Armin'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '远端项目路径'),
      '/tmp/other',
    );
    await tester.tap(find.text('保存项目目录'));
    await tester.pumpAndSettle();

    expect(find.text('无法编辑项目目录'), findsOneWidget);
    expect(find.textContaining('请先将它们停止或完成'), findsOneWidget);
  });
}

Future<void> _pumpProjectPaths(WidgetTester tester) async {
  final store = InMemoryTaskHistoryStore();
  final host = _host(projectPath: '/tmp/armin');
  await store.saveHost(host);
  await store.saveProjectPath(_projectPath(path: '/tmp/armin'));
  await store.saveTask(_task(host: host, status: TaskStatus.running));
  final state = ArminAppState(
    store: store,
    agentSessionService: MockAgentSessionService(),
    voiceService: MockVoiceService(),
  );
  await state.load();

  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: const MaterialApp(home: ProjectPathListScreen()),
    ),
  );
  await tester.pump();
}

HostConfig _host({required String projectPath}) {
  final now = DateTime(2026, 5, 17);
  return HostConfig(
    id: 'host-1',
    name: 'Dev',
    host: '127.0.0.1',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: projectPath,
    tmuxSessionName: 'armin-codex',
    agentCommand: 'codex',
    createdAt: now,
    updatedAt: now,
    password: 'secret-password',
  );
}

ProjectPathConfig _projectPath({required String path}) {
  final now = DateTime(2026, 5, 17);
  return ProjectPathConfig(
    id: 'project-1',
    name: 'Armin',
    path: path,
    createdAt: now,
    updatedAt: now,
  );
}

TaskSession _task({
  required HostConfig host,
  required TaskStatus status,
}) {
  final now = DateTime(2026, 5, 17);
  return TaskSession(
    id: 'task-1',
    host: host,
    title: 'Active Task',
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Active Task',
    userText: 'Active Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Active Task',
    secretRecords: const [],
    rawLog: '',
  );
}
