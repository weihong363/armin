import 'package:armin/features/agent/services/agent_runtime_config.dart';
import 'package:armin/features/agent/services/native_output_observer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default observer idle threshold uses shared runtime config', () {
    final observer = NativeOutputObserver();

    expect(observer.idleThreshold, AgentRuntimeConfig.turnIdleThreshold);
    expect(observer.reconnectThreshold, AgentRuntimeConfig.reconnectThreshold);
  });

  test('enters turn idle after semantic output is stable', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 2),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('hello', now: now);
    final snapshot = observer.observe(
      'hello',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('does not enter idle while Codex is working', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('Working...', now: now);
    final snapshot = observer.observe(
      'Working...',
      now: now.add(const Duration(seconds: 5)),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('does not settle yolo thinking spinner as turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ 测试文件已创建，运行 pytest。

▫ Bash(cd /Users/ironion/workspace/armin-test/file-renamer && python -m pytest test_renamer.py -v 2>&1)

⠸ Thinking... (esc to cancel, 1m 2s)
──────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('credits exhausted requires attention instead of result idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ 测试文件已创建，运行 pytest。

Credits exhausted. Use /usage for details or /upgrade for more.
⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.needAttention);
    expect(snapshot.needsAttention, isTrue);
    expect(snapshot.turnIdle, isFalse);
  });

  test('marks runtime lost after reconnect threshold', () {
    final observer = NativeOutputObserver(
      reconnectThreshold: const Duration(seconds: 2),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('Reconnecting...', now: now);
    final snapshot = observer.observe(
      'Reconnecting...',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(snapshot.state, NativeOutputObserverState.runtimeLost);
    expect(snapshot.runtimeLost, isTrue);
  });

  test('finished running tests does not block turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('I finished running tests.', now: now);
    final snapshot = observer.observe(
      'I finished running tests.',
      now: now.add(const Duration(seconds: 2)),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('only short status lines are active work signals', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('The task is running well after the fix.', now: now);
    final narrative = observer.observe(
      'The task is running well after the fix.',
      now: now.add(const Duration(seconds: 2)),
    );
    final active = observer.observe(
      'The task is running well after the fix.\nRunning...',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(narrative.state, NativeOutputObserverState.turnIdle);
    expect(active.state, NativeOutputObserverState.running);
  });
}
