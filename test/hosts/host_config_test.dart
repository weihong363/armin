import 'package:armin/features/hosts/models/host_config.dart';
import 'package:flutter_test/flutter_test.dart';

HostConfig _mockHost() {
  final now = DateTime.now();
  return HostConfig(
    id: 'host-local-mac',
    name: 'Local Mac',
    host: '192.168.1.10',
    port: 22,
    username: 'ironion',
    authType: HostAuthType.password,
    projectPath: '',
    tmuxSessionName: 'armin-codex',
    agentCommand: 'codex',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  test('mock host defaults to password auth without private key path', () {
    final host = _mockHost();

    expect(host.authType, HostAuthType.password);
    expect(host.projectPath, isEmpty);
    expect(host.privateKeyPath, isEmpty);
    expect(host.tmuxCommand, 'tmux');
    expect(host.pathPrepend, isEmpty);
    expect(host.shellWrapper, ShellWrapper.none);
    expect(host.machineType, HostMachineType.generic);
  });

  test('unknown auth type falls back to password', () {
    final host = HostConfig.fromJson({
      'id': 'host-1',
      'name': 'Dev',
      'host': '127.0.0.1',
      'username': 'ironion',
      'authType': 'legacy',
      'projectPath': '/tmp/armin',
    });

    expect(host.authType, HostAuthType.password);
  });

  test('password is held in memory and omitted from JSON history', () {
    final now = DateTime(2026, 5, 17);
    final host = HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret-password',
    );

    expect(host.password, 'secret-password');
    expect(host.toJson().containsKey('password'), isFalse);
  });

  test('tmux command environment round trips through JSON', () {
    final now = DateTime(2026, 5, 17);
    final host = HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      tmuxCommand: '/opt/homebrew/bin/tmux',
      pathPrepend: '/opt/homebrew/bin:/usr/local/bin',
      shellWrapper: ShellWrapper.zshLogin,
      machineType: HostMachineType.macAppleSilicon,
    );

    final reloaded = HostConfig.fromJson(host.toJson());

    expect(reloaded.tmuxCommand, '/opt/homebrew/bin/tmux');
    expect(reloaded.pathPrepend, '/opt/homebrew/bin:/usr/local/bin');
    expect(reloaded.shellWrapper, ShellWrapper.zshLogin);
    expect(reloaded.machineType, HostMachineType.macAppleSilicon);
  });

  test('host machine types document default tmux command paths', () {
    expect(
      HostMachineType.macAppleSilicon.defaultTmuxCommand,
      '/opt/homebrew/bin/tmux',
    );
    expect(
      HostMachineType.macAppleSilicon.defaultPathPrepend,
      '/opt/homebrew/bin:/usr/local/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
    );
    expect(
      HostMachineType.macAppleSilicon.defaultAgentCommand,
      r'$HOME/.npm-global/bin/codex',
    );
    expect(HostMachineType.macIntel.defaultTmuxCommand, '/usr/local/bin/tmux');
    expect(
      HostMachineType.macIntel.defaultPathPrepend,
      '/usr/local/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
    );
    expect(HostMachineType.linux.defaultTmuxCommand, '/usr/bin/tmux');
    expect(
      HostMachineType.linux.defaultPathPrepend,
      '/usr/bin:\$HOME/.npm-global/bin:\$HOME/.npm-packages/bin',
    );
    expect(HostMachineType.generic.defaultTmuxCommand, 'tmux');
    expect(HostMachineType.generic.defaultPathPrepend, isEmpty);
    expect(HostMachineType.generic.defaultAgentCommand, 'codex');
  });
}
