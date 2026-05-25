import 'codex_output_cleaner.dart';

enum NativeOutputObserverState {
  running,
  outputQuieting,
  turnIdle,
  needAttention,
  reconnecting,
  runtimeLost,
}

class NativeOutputSnapshot {
  const NativeOutputSnapshot({
    required this.rawOutput,
    required this.cleanedOutput,
    required this.state,
    required this.turnIdle,
    required this.runtimeLost,
    required this.needsAttention,
  });

  final String rawOutput;
  final String cleanedOutput;
  final NativeOutputObserverState state;
  final bool turnIdle;
  final bool runtimeLost;
  final bool needsAttention;
}

class NativeOutputObserver {
  NativeOutputObserver({
    CodexOutputCleaner cleaner = const CodexOutputCleaner(),
    this.idleThreshold = const Duration(seconds: 20),
    this.reconnectThreshold = const Duration(seconds: 60),
  }) : _cleaner = cleaner;

  final CodexOutputCleaner _cleaner;
  final Duration idleThreshold;
  final Duration reconnectThreshold;
  String? _lastSemanticHash;
  DateTime? _lastMeaningfulOutputAt;
  DateTime? _reconnectStartedAt;

  NativeOutputSnapshot observe(String output, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    final cleaned = _cleaner.clean(output);
    final semanticHash = _cleaner.semanticHashInput(output);
    if (semanticHash.isNotEmpty && semanticHash != _lastSemanticHash) {
      _lastSemanticHash = semanticHash;
      _lastMeaningfulOutputAt = observedAt;
    }

    final lower = cleaned.toLowerCase();
    if (_containsAttention(lower)) {
      return NativeOutputSnapshot(
        rawOutput: output,
        cleanedOutput: cleaned,
        state: NativeOutputObserverState.needAttention,
        turnIdle: false,
        runtimeLost: false,
        needsAttention: true,
      );
    }

    if (_containsReconnect(lower)) {
      _reconnectStartedAt ??= observedAt;
      final reconnectingFor = observedAt.difference(_reconnectStartedAt!);
      final lost = reconnectingFor >= reconnectThreshold;
      return NativeOutputSnapshot(
        rawOutput: output,
        cleanedOutput: cleaned,
        state: lost
            ? NativeOutputObserverState.runtimeLost
            : NativeOutputObserverState.reconnecting,
        turnIdle: false,
        runtimeLost: lost,
        needsAttention: false,
      );
    }
    _reconnectStartedAt = null;

    if (_containsActiveWork(lower)) {
      return NativeOutputSnapshot(
        rawOutput: output,
        cleanedOutput: cleaned,
        state: NativeOutputObserverState.running,
        turnIdle: false,
        runtimeLost: false,
        needsAttention: false,
      );
    }

    final lastMeaningful = _lastMeaningfulOutputAt ?? observedAt;
    final quietFor = observedAt.difference(lastMeaningful);
    final isIdle = semanticHash.isNotEmpty && quietFor >= idleThreshold;
    return NativeOutputSnapshot(
      rawOutput: output,
      cleanedOutput: cleaned,
      state: isIdle
          ? NativeOutputObserverState.turnIdle
          : NativeOutputObserverState.outputQuieting,
      turnIdle: isIdle,
      runtimeLost: false,
      needsAttention: false,
    );
  }

  NativeOutputSnapshot observeSettled(String output, {DateTime? now}) {
    final observedAt = now ?? DateTime.now();
    observe(output, now: observedAt);
    return observe(output, now: observedAt.add(idleThreshold));
  }

  bool _containsActiveWork(String lower) {
    return lower.contains('working') ||
        lower.contains('thinking') ||
        lower.contains('running');
  }

  bool _containsReconnect(String lower) {
    return lower.contains('reconnecting') || lower.contains('connection lost');
  }

  bool _containsAttention(String lower) {
    return lower.contains('approval') ||
        lower.contains('confirm') ||
        lower.contains('permission');
  }
}
