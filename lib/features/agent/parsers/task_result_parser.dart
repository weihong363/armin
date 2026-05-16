import 'task_result.dart';

class TaskResultParser {
  TaskResult? parse(String output) {
    final block = _extractBlock(
      output,
      start: 'TASK_RESULT_START',
      end: 'TASK_RESULT_END',
    );
    if (block == null) {
      return null;
    }

    return TaskResult(
      status: _singleLine(block, 'status') ?? 'failed',
      summary: _singleLine(block, 'summary') ?? '',
      changedFiles: _list(block, 'changed_files'),
      validation: _list(block, 'validation'),
      risks: _list(block, 'risks'),
      nextActions: _list(block, 'next_actions'),
    );
  }

  String? _extractBlock(
    String output, {
    required String start,
    required String end,
  }) {
    final startIndex = output.indexOf(start);
    final endIndex = output.indexOf(end);
    if (startIndex < 0 || endIndex < 0 || endIndex <= startIndex) {
      return null;
    }
    return output.substring(startIndex + start.length, endIndex).trim();
  }

  String? _singleLine(String block, String key) {
    final match = RegExp(
      '^${RegExp.escape(key)}:\\s*(.*)\$',
      multiLine: true,
    ).firstMatch(block);
    return match?.group(1)?.trim();
  }

  List<String> _list(String block, String key) {
    final lines = block.split('\n');
    final values = <String>[];
    var inSection = false;

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.startsWith('$key:')) {
        inSection = true;
        continue;
      }
      if (inSection && RegExp(r'^[a-z_]+:').hasMatch(line)) {
        break;
      }
      if (inSection && line.trimLeft().startsWith('-')) {
        values.add(line.trimLeft().substring(1).trim());
      }
    }

    return values;
  }
}
