import '../models/agent_approval_config.dart';
import 'agent_runtime_config.dart';

class RuntimePolicy {
  const RuntimePolicy({
    this.idleThreshold = AgentRuntimeConfig.turnIdleThreshold,
    this.reconnectThreshold = AgentRuntimeConfig.reconnectThreshold,
    this.maxRuntime = AgentRuntimeConfig.maxRuntime,
    this.monitorCaptureLines = AgentRuntimeConfig.monitorCaptureLines,
    this.finalCaptureLines = AgentRuntimeConfig.finalCaptureLines,
  })  : assert(monitorCaptureLines > 0),
        assert(finalCaptureLines > 0);

  final Duration idleThreshold;
  final Duration reconnectThreshold;
  final Duration maxRuntime;
  final int monitorCaptureLines;
  final int finalCaptureLines;

  RuntimePolicy forApprovalMode(AgentApprovalMode? mode) {
    if (mode == null) {
      return this;
    }
    return copyWith(
      idleThreshold: switch (mode) {
        AgentApprovalMode.balanced =>
          AgentRuntimeConfig.balancedTurnIdleThreshold,
        AgentApprovalMode.aggressive =>
          AgentRuntimeConfig.aggressiveTurnIdleThreshold,
      },
    );
  }

  RuntimePolicy copyWith({
    Duration? idleThreshold,
    Duration? reconnectThreshold,
    Duration? maxRuntime,
    int? monitorCaptureLines,
    int? finalCaptureLines,
  }) {
    return RuntimePolicy(
      idleThreshold: idleThreshold ?? this.idleThreshold,
      reconnectThreshold: reconnectThreshold ?? this.reconnectThreshold,
      maxRuntime: maxRuntime ?? this.maxRuntime,
      monitorCaptureLines: monitorCaptureLines ?? this.monitorCaptureLines,
      finalCaptureLines: finalCaptureLines ?? this.finalCaptureLines,
    );
  }

  int stablePollCount(Duration pollInterval) {
    return _pollCount(idleThreshold, pollInterval);
  }

  int maxPollCount(Duration pollInterval) {
    return _pollCount(maxRuntime, pollInterval);
  }

  int _pollCount(Duration duration, Duration pollInterval) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Runtime duration must be greater than zero.',
      );
    }
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'Poll interval must be greater than zero.',
      );
    }
    final durationMicros = duration.inMicroseconds;
    final intervalMicros = pollInterval.inMicroseconds;
    return (durationMicros + intervalMicros - 1) ~/ intervalMicros;
  }
}
