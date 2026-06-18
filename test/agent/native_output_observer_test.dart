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

  test('credits exhausted after deliverable settles as turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ 12 个测试全部通过（含竞态检测）。代码无问题，可正常使用。

Credits exhausted. Use /usage for details or /upgrade for more.
⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isTrue);
  });

  test('credits exhausted is not hidden by trailing yolo status chrome', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
Thinking
 │ Everything looks clean. FlipCountdown is fully removed.
 ▪ Done. FlipCountdown 已完全移除。当前 package 只包含：

   - CircularCountdown - 圆形进度环倒计时
   - LinearCountdown - 线性进度条倒计时

   请确认后我再继续下一步。
 Credits exhausted. Use /usage for details or /upgrade for more.

──────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isTrue);
  });

  test('credits exhausted without deliverable still requires attention', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
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
