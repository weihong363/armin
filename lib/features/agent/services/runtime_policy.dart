class RuntimePolicy {
  const RuntimePolicy({
    this.idleThreshold = const Duration(seconds: 20),
    this.reconnectThreshold = const Duration(seconds: 60),
    this.maxRuntime = const Duration(minutes: 20),
    this.monitorCaptureLines = 80,
    this.finalCaptureLines = 200,
  })  : assert(monitorCaptureLines > 0),
        assert(finalCaptureLines > 0);

  final Duration idleThreshold;
  final Duration reconnectThreshold;
  final Duration maxRuntime;
  final int monitorCaptureLines;
  final int finalCaptureLines;

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
