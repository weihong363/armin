import 'dart:io';

import 'package:armin/features/agent/services/agent_session_service.dart';
import 'package:armin/features/agent/services/ssh_agent_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pre-deploy integration tests for _PooledControlConnection state machine.
///
/// These tests require a real SSH server. Provide credentials via
/// environment variables:
///
///   ARMINTEST_SSH_HOST=myhost
///   ARMINTEST_SSH_USER=myuser
///   ARMINTEST_SSH_PASSWORD=mypassword
///   ARMINTEST_SSH_PORT=22          (optional, default 22)
///
/// Run with:
///
///   flutter test --tags real_ssh test/integration/
///
/// Skip slow idle-timeout tests:
///
///   flutter test --tags real_ssh --exclude-tags slow test/integration/
///

AgentControlRequest _buildRequest() {
  final host = Platform.environment['ARMINTEST_SSH_HOST'];
  final user = Platform.environment['ARMINTEST_SSH_USER'];
  final password = Platform.environment['ARMINTEST_SSH_PASSWORD'];
  final port = int.tryParse(
        Platform.environment['ARMINTEST_SSH_PORT'] ?? '22',
      ) ??
      22;

  if (host == null || host.isEmpty) {
    fail(
      'ARMINTEST_SSH_HOST is not set. '
      'Set SSH credentials via environment variables to run real-ssh tests.',
    );
  }
  if (user == null || user.isEmpty) {
    fail('ARMINTEST_SSH_USER is not set.');
  }
  if (password == null || password.isEmpty) {
    fail('ARMINTEST_SSH_PASSWORD is not set.');
  }

  return AgentControlRequest(
    host: host,
    port: port,
    username: user,
    password: password,
    tmuxSessionName: 'armin_integration_test_'
        '${DateTime.now().millisecondsSinceEpoch}',
  );
}

String? _realSshSkipReason() {
  final host = Platform.environment['ARMINTEST_SSH_HOST'];
  final user = Platform.environment['ARMINTEST_SSH_USER'];
  final password = Platform.environment['ARMINTEST_SSH_PASSWORD'];
  if (host == null || host.isEmpty) {
    return 'ARMINTEST_SSH_HOST is not set.';
  }
  if (user == null || user.isEmpty) {
    return 'ARMINTEST_SSH_USER is not set.';
  }
  if (password == null || password.isEmpty) {
    return 'ARMINTEST_SSH_PASSWORD is not set.';
  }
  return null;
}

void main() {
  final realSshSkipReason = _realSshSkipReason();
  late SSHAgentSessionService service;
  late AgentControlRequest request;

  setUp(() {
    service = SSHAgentSessionService();
    request = _buildRequest();
  });

  tearDown(() async {
    // Best-effort cleanup: kill any test tmux session we may have created.
    try {
      await service.cleanup(request);
    } catch (_) {
      // Session may not exist — ignore.
    }
  });

  group('Connection pool — reuse', () {
    test(
      'rapid captureLog calls reuse the same connection',
      () async {
        // First call: creates SSH connection + _PooledControlConnection.
        final result1 = await service.captureLog(request);
        expect(result1, isA<String>());

        // Second call: should reuse the existing connection via
        // _controlConnections[key] without creating a new SSHClient.
        final result2 = await service.captureLog(request);
        expect(result2, isA<String>());
      },
      tags: ['real_ssh'],
      skip: realSshSkipReason,
    );

    test(
      'three rapid captureLog calls all succeed',
      () async {
        final results = <String>[];
        for (var i = 0; i < 3; i++) {
          results.add(await service.captureLog(request));
        }

        expect(results, hasLength(3));
        for (final r in results) {
          expect(r, isA<String>());
        }
      },
      tags: ['real_ssh'],
      skip: realSshSkipReason,
    );
  });

  group('Connection pool — idle timeout', () {
    test(
      'connection is recreated after 25s idle period',
      () async {
        // First command: establishes connection.
        final result1 = await service.captureLog(request);
        expect(result1, isA<String>());

        // Wait past the 20s idle timeout so _idleTimer fires
        // → _dropControlConnection → connection.close().
        // Use 25s to leave margin for timer scheduling jitter.
        await Future<void>.delayed(const Duration(seconds: 25));

        // Second command: should transparently create a new connection
        // because _controlConnections[key] was dropped.
        final result2 = await service.captureLog(request);
        expect(result2, isA<String>());
      },
      tags: ['real_ssh', 'slow'],
      skip: realSshSkipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'rapid follow-up before idle timeout keeps connection alive',
      () async {
        // First command.
        await service.captureLog(request);

        // Wait less than the 20s idle timeout.
        await Future<void>.delayed(const Duration(seconds: 5));

        // Second command: _beginCommand cancels the idle timer, so the
        // connection should still be alive and reused.
        final result = await service.captureLog(request);
        expect(result, isA<String>());
      },
      tags: ['real_ssh'],
      skip: realSshSkipReason,
    );
  });

  group('Connection pool — error recovery', () {
    test(
      'captureLog still works after a failed connection attempt',
      () async {
        // Use a deliberately invalid host to trigger a connection error
        // that goes through _dropControlConnection.
        const badRequest = AgentControlRequest(
          host: '255.255.255.255',
          port: 22,
          username: 'nobody',
          password: 'bad',
          tmuxSessionName: 'does_not_matter',
        );

        // This should fail (connection timeout / unreachable).
        try {
          await service.captureLog(badRequest);
        } catch (_) {
          // Expected: connection error.
        }

        // The real connection to the valid host should still work
        // — error on one key must not poison the pool for other keys.
        final result = await service.captureLog(request);
        expect(result, isA<String>());
      },
      tags: ['real_ssh'],
      skip: realSshSkipReason,
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
