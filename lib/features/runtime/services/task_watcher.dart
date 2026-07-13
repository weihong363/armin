import '../../../shared/governance_rules.dart';
import '../../../shared/line_noise_filter.dart';
import '../../agent/services/agent_output_cleaner.dart';

/// Observes incremental terminal output and extracts progress/action hints.
///
/// **Role**: Secondary compatibility layer.
///
/// RuntimeEventBus is the primary source of runtime state.
/// TaskWatcher remains for:
/// - Progress extraction (percentage patterns)
/// - Action extraction (last meaningful line)
/// - Summary/checkpoint extraction
/// - Legacy output parsing compatibility
/// - Audit-friendly output observation
///
/// This watcher must not infer lifecycle status. RuntimeEventBus events are the
/// primary source of runtime state.
class TaskWatcher {
  final Map<String, _WatcherCursor> _cursors = {};

  /// Restores an observation checkpoint without treating an offset as a
  /// durable terminal-log cursor. tmux captures may roll or redraw, so the
  /// first changed snapshot after a restart is intentionally re-read whole.
  void restoreCheckpoint({
    required String taskId,
    required int lastOffset,
    required String outputFingerprint,
  }) {
    _cursors[taskId] = _WatcherCursor(
      lastOffset: lastOffset,
      outputFingerprint: outputFingerprint,
    );
  }

  TaskWatcherUpdate observe({
    required String taskId,
    required String capturedOutput,
  }) {
    final fingerprint = _fingerprint(capturedOutput);
    final previous = _cursors[taskId];
    if (previous?.outputFingerprint == fingerprint) {
      return TaskWatcherUpdate(
        taskId: taskId,
        incrementalOutput: '',
        lastOffset: previous?.lastOffset ?? capturedOutput.length,
        outputFingerprint: fingerprint,
        isDuplicate: true,
      );
    }
    final previousOutput = previous?.capturedOutput;
    final incrementalOutput = previousOutput != null &&
            capturedOutput.startsWith(previousOutput)
        ? capturedOutput.substring(previousOutput.length)
        : capturedOutput;
    final nextOffset = capturedOutput.length;
    _cursors[taskId] = _WatcherCursor(
      capturedOutput: capturedOutput,
      lastOffset: nextOffset,
      outputFingerprint: fingerprint,
    );
    return TaskWatcherUpdate(
      taskId: taskId,
      incrementalOutput: incrementalOutput,
      lastOffset: nextOffset,
      outputFingerprint: fingerprint,
      action: _extractAction(incrementalOutput),
      progress: _extractProgress(incrementalOutput),
      checkpoint: _extractCheckpoint(incrementalOutput),
    );
  }

  void reset(String taskId) {
    _cursors.remove(taskId);
  }

  String _fingerprint(String output) {
    var hash = 0x811C9DC5;
    for (final codeUnit in output.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _extractAction(String output) {
    final cleaned = const AgentOutputCleaner().clean(output);
    final lines = cleaned
        .split('\n')
        .map(_normalizeActionLine)
        .where((line) => line.isNotEmpty)
        .where((line) => !_isNoiseLine(line))
        .toList(growable: false);
    if (lines.isEmpty) {
      return '';
    }
    return _truncate(lines.last, 120);
  }

  int? _extractProgress(String output) {
    final matches = RegExp(r'(\d{1,3})\s*%').allMatches(output).toList();
    if (matches.isEmpty) {
      return null;
    }
    final value = int.tryParse(matches.last.group(1) ?? '');
    if (value == null) {
      return null;
    }
    return value.clamp(0, 100);
  }

  String _extractCheckpoint(String output) {
    final match = RegExp(
      r'(?:checkpoint|阶段|步骤)\s*[:：]\s*(.+)',
      caseSensitive: false,
    ).firstMatch(output);
    if (match == null) {
      return '';
    }
    return _truncate(match.group(1)?.trim() ?? '', 120);
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    return lower.startsWith('tmux ') ||
        lower.startsWith('ssh ') ||
        lower.startsWith('thinking') ||
        lower.startsWith('bash(') ||
        lower.startsWith('read(') ||
        lower.startsWith('write(') ||
        lower.startsWith('edit(') ||
        lower.startsWith('glob(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('accepted ') ||
        const LineNoiseFilter().isUnreadable(line) ||
        lower.startsWith('│') ||
        lower.startsWith('>_') ||
        lower.startsWith('armin context governance') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('turn ') ||
        GovernanceRules.isGovernanceRuleEndsWith(lower);
  }

  String _normalizeActionLine(String line) {
    return line
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .trim()
        .replaceFirst(RegExp(r'^[>❯▸›▪▫•*-]\s*'), '')
        .trim();
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}...';
  }
}

class TaskWatcherUpdate {
  const TaskWatcherUpdate({
    required this.taskId,
    required this.incrementalOutput,
    required this.lastOffset,
    required this.outputFingerprint,
    this.isDuplicate = false,
    this.action = '',
    this.progress,
    this.checkpoint = '',
  });

  final String taskId;
  final String incrementalOutput;
  final int lastOffset;
  final String outputFingerprint;
  final bool isDuplicate;
  final String action;
  final int? progress;
  final String checkpoint;

  bool get hasUsefulUpdate {
    return action.trim().isNotEmpty ||
        progress != null ||
        checkpoint.trim().isNotEmpty;
  }
}

class _WatcherCursor {
  const _WatcherCursor({
    this.capturedOutput,
    required this.lastOffset,
    required this.outputFingerprint,
  });

  final String? capturedOutput;
  final int lastOffset;
  final String outputFingerprint;
}
