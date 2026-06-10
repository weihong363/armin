import '../models/runtime_task_snapshot.dart';

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
      status: _extractStatus(incrementalOutput),
      checkpoint: _extractCheckpoint(incrementalOutput),
    );
  }

  void reset(String taskId) {
    _lastOffsets.remove(taskId);
  }

  String _extractAction(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
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

  RuntimeTaskStatus? _extractStatus(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('waiting for user') ||
        lower.contains('needs approval') ||
        lower.contains('need approval') ||
        lower.contains('waiting for your')) {
      return RuntimeTaskStatus.waitingUser;
    }
    if (lower.contains('task completed') ||
        lower.contains('completed successfully')) {
      return RuntimeTaskStatus.completed;
    }
    if (lower.contains('task failed') || lower.contains('fatal error')) {
      return RuntimeTaskStatus.failed;
    }
    if (output.trim().isEmpty) {
      return null;
    }
    return RuntimeTaskStatus.running;
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
        lower.startsWith('│') ||
        lower.startsWith('>_') ||
        lower.startsWith('armin context governance') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('turn ') ||
        _isWatcherGovernanceRule(lower);
  }

  static const _watcherGovernanceLines = [
    'only inspect files directly related to the task.',
    'never scan the entire repository.',
    'avoid reading docs/ and readme unless necessary.',
    'keep edits minimal and focused.',
    'do not analyze unrelated architecture.',
    'run only targeted tests.',
    'keep command output short.',
    'you have full authority to create, modify, and delete files without asking.',
    'run any commands, tests, or builds needed to complete the task.',
    'do not interrupt the user',
    'never modify any file',
    'do not run commands that alter state.',
    'ask before any potentially risky read operation.',
    '只分析不修改',
    '最小改动',
    '允许修改',
    '修改后运行测试',
    '不要提交 git',
    '高风险操作先确认',
  ];

  bool _isWatcherGovernanceRule(String lower) {
    for (final text in _watcherGovernanceLines) {
      if (lower.endsWith(text)) return true;
    }
    return false;
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
    this.status,
    this.checkpoint = '',
  });

  final String taskId;
  final String incrementalOutput;
  final int lastOffset;
  final String action;
  final int? progress;
  final RuntimeTaskStatus? status;
  final String checkpoint;

  bool get hasUsefulUpdate {
    return incrementalOutput.trim().isNotEmpty ||
        action.trim().isNotEmpty ||
        progress != null ||
        status != null ||
        checkpoint.trim().isNotEmpty;
  }
}
