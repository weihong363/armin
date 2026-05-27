import 'package:armin/features/agent/services/runtime_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime policy converts durations to polling bounds', () {
    const policy = RuntimePolicy(
      idleThreshold: Duration(milliseconds: 2500),
      maxRuntime: Duration(milliseconds: 5100),
    );

    expect(policy.stablePollCount(const Duration(seconds: 1)), 3);
    expect(policy.maxPollCount(const Duration(seconds: 1)), 6);
  });

  test('runtime policy rejects an invalid polling interval', () {
    expect(
      () => const RuntimePolicy().stablePollCount(Duration.zero),
      throwsArgumentError,
    );
  });
}
