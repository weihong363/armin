import 'package:armin/features/agent/services/agent_runtime_config.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/runtime_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime policy defaults use shared runtime config', () {
    const policy = RuntimePolicy();

    expect(policy.idleThreshold, AgentRuntimeConfig.turnIdleThreshold);
    expect(policy.reconnectThreshold, AgentRuntimeConfig.reconnectThreshold);
    expect(policy.maxRuntime, AgentRuntimeConfig.maxRuntime);
    expect(policy.monitorCaptureLines, AgentRuntimeConfig.monitorCaptureLines);
    expect(policy.finalCaptureLines, AgentRuntimeConfig.finalCaptureLines);
    expect(
      policy.stablePollCount(AgentRuntimeConfig.pollInterval),
      4,
    );
  });

  test('runtime policy converts durations to polling bounds', () {
    const policy = RuntimePolicy(
      idleThreshold: Duration(milliseconds: 2500),
      maxRuntime: Duration(milliseconds: 5100),
    );

    expect(policy.stablePollCount(const Duration(seconds: 1)), 3);
    expect(policy.maxPollCount(const Duration(seconds: 1)), 6);
  });

  test('runtime policy maps approval modes to idle thresholds', () {
    const policy = RuntimePolicy();

    expect(
      policy.forApprovalMode(AgentApprovalMode.safe).idleThreshold,
      AgentRuntimeConfig.turnIdleThreshold,
    );
    expect(
      policy.forApprovalMode(AgentApprovalMode.balanced).idleThreshold,
      AgentRuntimeConfig.balancedTurnIdleThreshold,
    );
    expect(
      policy.forApprovalMode(AgentApprovalMode.aggressive).idleThreshold,
      AgentRuntimeConfig.aggressiveTurnIdleThreshold,
    );
  });

  test('runtime policy rejects an invalid polling interval', () {
    expect(
      () => const RuntimePolicy().stablePollCount(Duration.zero),
      throwsArgumentError,
    );
  });
}
