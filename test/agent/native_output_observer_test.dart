import 'package:armin/features/agent/services/native_output_observer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
