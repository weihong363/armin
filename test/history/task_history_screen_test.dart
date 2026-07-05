import 'package:armin/app_state_scope.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:armin/core/storage/task_history_store.dart';
import 'package:armin/features/history/screens/task_history_screen.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agent/services/mock_agent_session_service.dart';
import '../features/voice/services/mock_voice_service.dart';

void main() {
  testWidgets('history task opens task detail', (tester) async {
    final state = ArminAppState(
      store: _HistoryStore(_task()),
      agentSessionService: MockAgentSessionService(),
      voiceService: MockVoiceService(),
    );
    await state.load();
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: TaskHistoryScreen()),
      ),
    );

    expect(find.text('历史任务'), findsOneWidget);
    expect(find.text('修复登录流程'), findsOneWidget);

    await tester.tap(find.text('修复登录流程'));
    await tester.pumpAndSettle();

    expect(find.text('任务详情'), findsOneWidget);
  });
}

TaskSession _task() {
  final now = DateTime(2026, 5, 25);
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
      tmuxSessionName: 'armin',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
    ),
    title: '修复登录流程',
    createdAt: now,
    updatedAt: now,
    rawSttText: '',
    cleanedDraft: '',
    userText: '修复登录流程',
    context: '',
    constraints: const {},
    finalPrompt: '',
    secretRecords: const [],
    rawLog: '',
    shortSummary: '已完成',
  );
}

class _HistoryStore extends TaskHistoryStore {
  _HistoryStore(this.task);

  final TaskSession task;

  @override
  Future<List<TaskSession>> loadTasks() async => [task];

  @override
  Future<List<HostConfig>> loadHosts() async => [];

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async => [];

  @override
  Future<void> saveTask(TaskSession task) async {}

  @override
  Future<void> saveHost(HostConfig host) async {}

  @override
  Future<void> deleteHost(String hostId) async {}

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {}

  @override
  Future<void> deleteTask(String taskId) async {}

  @override
  Future<void> deleteProjectPath(String projectPathId) async {}
}
