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
  final Map<String, int> _lastOffsets = {};

  TaskWatcherUpdate observe({
    required String taskId,
    required String capturedOutput,
  }) {
    final previousOffset = _lastOffsets[taskId] ?? 0;
    final safeOffset =
        previousOffset <= capturedOutput.length ? previousOffset : 0;
    final incrementalOutput = capturedOutput.substring(safeOffset);
    final nextOffset = capturedOutput.length;
    _lastOffsets[taskId] = nextOffset;
    return TaskWatcherUpdate(
      taskId: taskId,
      incrementalOutput: incrementalOutput,
      lastOffset: nextOffset,
      action: _extractAction(incrementalOutput),
      progress: _extractProgress(incrementalOutput),
      checkpoint: _extractCheckpoint(incrementalOutput),
    );
  }

  void reset(String taskId) {
    _lastOffsets.remove(taskId);
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
    this.action = '',
    this.progress,
    this.checkpoint = '',
  });

  final String taskId;
  final String incrementalOutput;
  final int lastOffset;
  final String action;
  final int? progress;
  final String checkpoint;

  bool get hasUsefulUpdate {
    return incrementalOutput.trim().isNotEmpty ||
        action.trim().isNotEmpty ||
        progress != null ||
        checkpoint.trim().isNotEmpty;
  }
}
