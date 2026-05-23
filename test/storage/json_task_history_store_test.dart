import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:armin/core/storage/json_task_history_store.dart';
import 'package:armin/core/storage/secure_password_store.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/projects/models/project_path_config.dart';

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
}
