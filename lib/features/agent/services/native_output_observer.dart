import 'agent_output_cleaner.dart';
import 'agent_runtime_config.dart';

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
    AgentOutputCleaner cleaner = const AgentOutputCleaner(),
    this.idleThreshold = AgentRuntimeConfig.turnIdleThreshold,
    this.reconnectThreshold = AgentRuntimeConfig.reconnectThreshold,
  }) : _cleaner = cleaner;

  final AgentOutputCleaner _cleaner;
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
    final workSignalLines = _recentStatusLines(cleaned, limit: 30);
    final rawWorkSignalLines = _recentStatusLines(output, limit: 30);
    final terminalSignalLines = _recentStatusLines(cleaned, limit: 30);
    final rawTerminalSignalLines = _recentStatusLines(output, limit: 30);
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

    if (_containsQuotaExhausted(
      [...terminalSignalLines, ...rawTerminalSignalLines],
    )) {
      if (_hasDeliverableBeforeQuota(cleaned) ||
          _hasDeliverableBeforeQuota(output)) {
        return NativeOutputSnapshot(
          rawOutput: output,
          cleanedOutput: cleaned,
          state: NativeOutputObserverState.turnIdle,
          turnIdle: true,
          runtimeLost: false,
          needsAttention: false,
        );
      }
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

    if (_containsActiveWork([...workSignalLines, ...rawWorkSignalLines])) {
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

  List<String> _recentStatusLines(String cleaned, {int limit = 5}) {
    final lines = cleaned
        .split('\n')
        .map((line) => line.trim().toLowerCase())
        .map((line) => line.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), ''))
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final start = lines.length > limit ? lines.length - limit : 0;
    return lines.sublist(start);
  }

  bool _containsActiveWork(List<String> lines) {
    final lastDeliverableIndex = lines.lastIndexWhere((line) =>
        _looksLikeDeliverableLine(line) && !_isBackgroundTaskLine(line));
    final activeWindow =
        lastDeliverableIndex < 0 ? lines : lines.skip(lastDeliverableIndex + 1);
    return activeWindow.any((line) {
      // Terminal chrome lines (status bar with spinners, esc-to-cancel,
      // YOLO/Shift+Tab hints, auto model context) are never genuine work output.
      final lower = line.toLowerCase();
      if (lower.contains('esc to cancel')) {
        // When qodercli shows "Thinking... (esc to cancel, Ns)" with a
        // countdown timer, the agent is actively waiting for a tool
        // (e.g. Bash) to complete — unless the turn is already finished
        // (credits exhausted or high-confidence deliverable present).
        if (lower.contains('thinking') || lower.contains('working')) {
          if (!_hasHighConfidenceDeliverable(lines) &&
              (_hasRecentWorkContext(lines) || _hasPromptEchoContext(lines))) {
            return true;
          }
        }
        return !_hasHighConfidenceDeliverable(lines) &&
            _hasRecentWorkContext(lines);
      }
      if (lower.contains('shift+tab to auto') || lower.contains('auto model')) {
        return false;
      }
      final normalized = _statusWord(line);
      final withoutBullet =
          normalized.replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
      if (_looksLikeActiveWorkLine(withoutBullet)) {
        return true;
      }
      final active = normalized == 'working' ||
          normalized == 'running' ||
          (normalized.contains('thinking') && normalized != 'thinking') ||
          normalized.contains('yolo') ||
          normalized.contains('auto mode') ||
          normalized.contains('bash(');
      return active;
    });
  }

  bool _hasHighConfidenceDeliverable(List<String> lines) {
    return lines.any((line) {
      final normalized =
          _statusWord(line).replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
      final lower = normalized.toLowerCase();
      final hasBullet = line.trimLeft().startsWith(RegExp('[▪▫■●]'));
      final hasStructuredMarker =
          RegExp(r'\barmin_[a-z0-9_]+_begin\b').hasMatch(lower);
      final hasStandaloneBulletMarker =
          hasBullet && RegExp(r'\barmin[a-z0-9_]*\b').hasMatch(lower);
      return hasStructuredMarker ||
          hasStandaloneBulletMarker ||
          lower.startsWith('done.') ||
          lower.startsWith("i've created ") ||
          lower.contains('completed successfully') ||
          lower.contains('tests passed') ||
          lower.contains('all tests passed') ||
          normalized.contains('已完成') ||
          normalized.contains('已创建') ||
          normalized.contains('全部通过') ||
          normalized.contains('测试通过');
    });
  }

  bool _hasRecentWorkContext(List<String> lines) {
    return lines.any((line) {
      final normalized =
          _statusWord(line).replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
      final lower = normalized.toLowerCase();
      if (lower.isEmpty ||
          lower == '*' ||
          lower.contains('esc to cancel') ||
          lower.contains('shift+tab') ||
          lower.contains('auto mode') ||
          lower.contains('model · ctx') ||
          lower.contains('credits exhausted') ||
          lower.contains('update successful') ||
          lower.contains('type your message or @path/to/file')) {
        return false;
      }
      return line.trimLeft().startsWith(RegExp('[▪▫■●]')) ||
          _looksLikeActiveWorkLine(normalized);
    });
  }

  bool _hasPromptEchoContext(List<String> lines) {
    return lines.any((line) {
      final normalized =
          _statusWord(line).replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
      final lower = normalized.toLowerCase();
      return lower.startsWith('constraints:') ||
          lower.startsWith('final answer') ||
          lower.startsWith('sections:') ||
          lower.contains('exact marker') ||
          RegExp(r'\barmin[a-z0-9_]*\b').hasMatch(lower);
    });
  }

  bool _looksLikeActiveWorkLine(String line) {
    final lower = line.toLowerCase();
    return RegExp(
          r'^(?:bash|glob|grep|read|write|edit|multiedit|list|ls|cat)\s*\(',
          caseSensitive: false,
        ).hasMatch(line) ||
        _looksLikePlanningLine(lower) ||
        line.startsWith('让我') ||
        line.startsWith('我先') ||
        line.startsWith('我会') ||
        line.startsWith('我将');
  }

  bool _looksLikePlanningLine(String lower) {
    return lower.startsWith('let me ') ||
        lower.startsWith('first, ') ||
        lower.startsWith('next, ') ||
        lower.startsWith('now ') ||
        lower.startsWith('i will ') ||
        lower.startsWith("i'll ") ||
        lower.startsWith('i am going to ') ||
        lower.startsWith("i'm going to ") ||
        lower.startsWith('i need to ') ||
        lower.contains(" i'll ") ||
        lower.contains(' i will ') ||
        lower.contains(' let me ');
  }

  bool _containsQuotaExhausted(List<String> lines) {
    return lines.any((line) {
      // Qoder/Codex TUI can leave "Credits exhausted. Use /usage..." as
      // persistent chrome even while the turn is still running. Treat only
      // explicit usage/quota limit messages as blocking attention signals.
      return line.contains('usage limit') ||
          line.contains('quota exhausted') ||
          line.contains('额度已用完');
    });
  }

  bool _hasDeliverableBeforeQuota(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (_containsQuotaExhausted([lower])) {
        return false;
      }
      if (_looksLikeDeliverableLine(line)) {
        return true;
      }
    }
    return false;
  }

  bool _looksLikeDeliverableLine(String line) {
    if (!line.startsWith('▪')) {
      return false;
    }
    final text = line.replaceFirst(RegExp(r'^▪\s*'), '').trim();
    if (text.isEmpty) {
      return false;
    }
    final lower = text.toLowerCase();
    if (_looksLikePlanningLine(lower)) {
      return false;
    }
    return !RegExp(
      r'^(?:Read|Write|Edit|MultiEdit|Glob|Grep|Bash|List)\(',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Returns true for agent lines that describe a background task still
  /// running (e.g. "▪ The long task has been started in the background...").
  /// These should not be treated as deliverables that truncate the active
  /// work window in [_containsActiveWork].
  bool _isBackgroundTaskLine(String line) {
    if (!line.startsWith('▪')) {
      return false;
    }
    final lower = line.toLowerCase();
    return lower.contains('background') &&
        (lower.contains('will complete') || lower.contains('is now running'));
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
