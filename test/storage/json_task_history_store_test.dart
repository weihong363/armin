import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:armin/core/storage/json_task_history_store.dart';
import 'package:armin/features/hosts/models/host_config.dart';

void main() {
  test('JsonTaskHistoryStore persists hosts', () async {
    final tempDir = await Directory.systemTemp.createTemp('armin-store-test');
    addTearDown(() => tempDir.delete(recursive: true));
    final store = JsonTaskHistoryStore(
      file: File('${tempDir.path}/history.json'),
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
    );

    final hosts = await reloaded.loadHosts();
    expect(hosts.any((item) => item.id == 'host-1'), true);
    expect(hosts.firstWhere((item) => item.id == 'host-1').privateKeyPath,
        '~/.ssh/id_ed25519');
  });
}
