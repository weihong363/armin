import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:armin/core/models/task_status.dart';
import 'package:armin/core/storage/json_task_history_store.dart';
import 'package:armin/core/storage/secure_password_store.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/agent/parsers/terminal_prompt.dart';
import 'package:armin/features/projects/models/project_path_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';

import 'mock_secure_storage.dart';

void main() {
  test('JsonTaskHistoryStore persists hosts', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final mockStorage = MockSecureStorage();
    final passwordStore = SecurePasswordStore(storage: mockStorage);
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: passwordStore,
    );
    final now = DateTime(2026, 5, 16);
    final host = HostConfig(
      id: 'host-1',
      name: 'Dev Mac',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.privateKey,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      privateKeyPath: '~/.ssh/id_ed25519',
    );

    await store.saveHost(host);
    final reloaded = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: passwordStore,
    );

    final hosts = await reloaded.loadHosts();
    expect(hosts.any((item) => item.id == 'host-1'), true);
    expect(hosts.firstWhere((item) => item.id == 'host-1').privateKeyPath,
        '~/.ssh/id_ed25519');
  });

  test('JsonTaskHistoryStore persists password securely', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final mockStorage = MockSecureStorage();
    final passwordStore = SecurePasswordStore(storage: mockStorage);
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: passwordStore,
    );
    final now = DateTime(2026, 5, 17);
    final host = HostConfig(
      id: 'host-2',
      name: 'Dev Server',
      host: '192.168.1.100',
      port: 22,
      username: 'deploy',
      authType: HostAuthType.password,
      projectPath: '/var/www/app',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'super-secret-password',
    );

    await store.saveHost(host);

    // Verify password is stored in secure storage
    final savedPassword = await passwordStore.loadPassword('host-2');
    expect(savedPassword, 'super-secret-password');

    // Reload and verify password is restored
    final reloaded = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: passwordStore,
    );
    final hosts = await reloaded.loadHosts();
    final reloadedHost = hosts.firstWhere((item) => item.id == 'host-2');
    expect(reloadedHost.password, 'super-secret-password');
  });

  test('JsonTaskHistoryStore persists project paths', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );
    final now = DateTime(2026, 5, 18);
    final projectPath = ProjectPathConfig(
      id: 'project-1',
      name: 'Armin',
      path: '/Users/ironion/workspace/armin',
      createdAt: now,
      updatedAt: now,
      isDefault: true,
    );

    await store.saveProjectPath(projectPath);
    final reloaded = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );

    final projectPaths = await reloaded.loadProjectPaths();
    expect(projectPaths.single.name, 'Armin');
    expect(projectPaths.single.path, '/Users/ironion/workspace/armin');
    expect(projectPaths.single.isDefault, isTrue);
  });

  test('JsonTaskHistoryStore persists native output turns', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );
    final now = DateTime(2026, 5, 20);
    final task = _task(now).copyWith(
      turns: [
        NativeOutputTurn(
          id: 'turn-task-1-1',
          taskId: 'task-1',
          turnIndex: 1,
          userInput: '输出 hello',
          rawOutput: 'hello',
          cleanedOutput: 'hello',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.turnIdle,
          idleDetectedAt: now,
        ),
      ],
    );

    await store.saveTask(task);
    final reloaded = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );

    final tasks = await reloaded.loadTasks();
    expect(tasks.single.turns, hasLength(1));
    expect(tasks.single.turns.single.status, NativeOutputTurnStatus.turnIdle);
    expect(tasks.single.turns.single.userInput, '输出 hello');
  });

  test('JsonTaskHistoryStore persists pending terminal prompts', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );
    final task = _task(DateTime(2026, 5, 26)).copyWith(
      terminalPrompt: const TerminalPrompt(
        question: 'Allow execution of [ls]?',
        options: [TerminalPromptOption(key: '1', label: 'Allow once')],
      ),
    );

    await store.saveTask(task);
    final reloaded = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );

    final savedTask = (await reloaded.loadTasks()).single;
    expect(savedTask.terminalPrompt?.question, 'Allow execution of [ls]?');
    expect(savedTask.terminalPrompt?.options.single.key, '1');
  });

  test('JsonTaskHistoryStore reads old tasks without turns', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/history.json');
    final taskJson = Map<String, Object?>.from(
      _task(DateTime(2026, 5, 20)).toJson(),
    )..remove('turns');
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'hosts': [],
      'projectPaths': [],
      'tasks': [taskJson],
    }));
    final store = JsonTaskHistoryStore(
      file: file,
      passwordStore: SecurePasswordStore(storage: MockSecureStorage()),
    );

    final tasks = await store.loadTasks();

    expect(tasks.single.id, 'task-1');
    expect(tasks.single.turns, isEmpty);
  });
}

TaskSession _task(DateTime now) {
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
      tmuxSessionName: 'armin-12345678',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
    ),
    title: 'Task',
    status: TaskStatus.running,
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: '输出 hello',
    userText: '输出 hello',
    context: '',
    constraints: const {},
    finalPrompt: '输出 hello',
    secretRecords: const [],
    rawLog: '',
  );
}
