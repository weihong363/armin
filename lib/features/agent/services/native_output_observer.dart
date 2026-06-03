import 'agent_runtime_config.dart';
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
    this.idleThreshold = AgentRuntimeConfig.turnIdleThreshold,
    this.reconnectThreshold = AgentRuntimeConfig.reconnectThreshold,
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

    final statusLines = _recentStatusLines(cleaned);
    if (_containsAttention(statusLines)) {
      return NativeOutputSnapshot(
        rawOutput: output,
        cleanedOutput: cleaned,
        state: NativeOutputObserverState.needAttention,
        turnIdle: false,
        runtimeLost: false,
        needsAttention: true,
      );
    }

    if (_containsReconnect(statusLines)) {
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

    if (_containsActiveWork(statusLines)) {
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

  List<String> _recentStatusLines(String cleaned) {
    final lines = cleaned
        .split('\n')
        .map((line) => line.trim().toLowerCase())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final start = lines.length > 5 ? lines.length - 5 : 0;
    return lines.sublist(start);
  }

  bool _containsActiveWork(List<String> lines) {
    return lines.any((line) {
      final normalized = _statusWord(line);
      return normalized == 'working' ||
          normalized == 'thinking' ||
          normalized == 'running';
    });
  }

  bool _containsReconnect(List<String> lines) {
    return lines.any((line) {
      final normalized = _statusWord(line);
      return normalized == 'reconnecting' || normalized == 'connection lost';
    });
  }

  bool _containsAttention(List<String> lines) {
    return lines.any((line) {
      final normalized = _statusWord(line);
      return normalized == 'approval' ||
          normalized == 'confirm' ||
          normalized == 'permission';
    });
  }

  String _statusWord(String line) {
    return line
        .replaceAll(RegExp(r'^[›>\-*•\s]+'), '')
        .replaceAll(RegExp(r'[.…]+$'), '')
        .trim();
  }
}
