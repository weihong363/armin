import '../models/task_constraint.dart';

enum PromptChunkType {
  task,
  constraints,
  context,
  secrets,
}

class PromptChunk {
  const PromptChunk({
    required this.type,
    required this.title,
    required this.text,
    required this.priority,
    this.required = false,
  });

  final PromptChunkType type;
  final String title;
  final String text;
  final int priority;
  final bool required;
}

class PromptContextChunker {
  const PromptContextChunker({
    this.maxPromptChars = 3600,
    this.maxContextChunkChars = 900,
  });

  final int maxPromptChars;
  final int maxContextChunkChars;

  String build({
    required String taskDescription,
    required String context,
    required Set<TaskConstraint> constraints,
    required String secretsText,
  }) {
    final requiredChunks = _requiredChunks(
      taskDescription: taskDescription,
      constraints: constraints,
      secretsText: secretsText,
    );
    final optionalChunks = _contextChunks(context);
    return _compose(requiredChunks, optionalChunks);
  }

  List<PromptChunk> _requiredChunks({
    required String taskDescription,
    required Set<TaskConstraint> constraints,
    required String secretsText,
  }) {
    return [
      PromptChunk(
        type: PromptChunkType.task,
        title: 'User task',
        text: taskDescription.trim(),
        priority: 100,
        required: true,
      ),
      if (constraints.isNotEmpty)
        PromptChunk(
          type: PromptChunkType.constraints,
          title: 'User constraints',
          text: constraints.map((item) => '- ${item.label}').join('\n'),
          priority: 95,
          required: true,
        ),
      if (secretsText.trim().isNotEmpty)
        PromptChunk(
          type: PromptChunkType.secrets,
          title: 'Secret placeholders',
          text: secretsText.trim(),
          priority: 90,
          required: true,
        ),
    ].where((chunk) => chunk.text.trim().isNotEmpty).toList(growable: false);
  }

  List<PromptChunk> _contextChunks(String context) {
    final sections = context
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n\s*\n'))
        .map((section) => section.trim())
        .where((section) => section.isNotEmpty)
        .toList(growable: false);

    final chunks = <PromptChunk>[];
    var index = 1;
    for (final section in sections) {
      for (final part in _splitSection(section)) {
        chunks.add(
          PromptChunk(
            type: PromptChunkType.context,
            title: 'Context chunk $index',
            text: part,
            priority: _contextPriority(part),
          ),
        );
        index += 1;
      }
    }
    chunks.sort((a, b) => b.priority.compareTo(a.priority));
    return chunks;
  }

  List<String> _splitSection(String section) {
    if (section.length <= maxContextChunkChars) {
      return [section];
    }

    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final line in section.split('\n')) {
      final nextLength = buffer.length + line.length + 1;
      if (buffer.isNotEmpty && nextLength > maxContextChunkChars) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      buffer.writeln(line);
    }
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
    }
    return chunks;
  }

  int _contextPriority(String text) {
    final lower = text.toLowerCase();
    var score = 40;
    if (lower.contains('error') ||
        lower.contains('exception') ||
        lower.contains('failed') ||
        lower.contains('failure') ||
        text.contains('错误') ||
        text.contains('失败')) {
      score += 25;
    }
    if (lower.contains('.dart') ||
        lower.contains('.kt') ||
        lower.contains('.swift') ||
        lower.contains('lib/') ||
        lower.contains('test/')) {
      score += 15;
    }
    if (lower.contains('expected') ||
        lower.contains('actual') ||
        lower.contains('result') ||
        text.contains('结果') ||
        text.contains('期望') ||
        text.contains('实际')) {
      score += 10;
    }
    return score;
  }

  String _compose(
    List<PromptChunk> requiredChunks,
    List<PromptChunk> optionalChunks,
  ) {
    final buffer = StringBuffer();
    for (final chunk in requiredChunks) {
      _writeChunk(buffer, chunk);
    }

    var remaining = maxPromptChars - buffer.length;
    if (remaining <= 0) {
      return buffer.toString().trim();
    }

    for (final chunk in optionalChunks) {
      final section = _formatChunk(chunk);
      if (section.length <= remaining) {
        buffer.writeln();
        buffer.writeln(section);
        remaining = maxPromptChars - buffer.length;
        continue;
      }
      if (remaining > 160 && chunk.priority >= 60) {
        final clipped = _clip(chunk.text, remaining - chunk.title.length - 16);
        _writeChunk(buffer, chunk, textOverride: clipped);
      }
      break;
    }

    return buffer.toString().trim();
  }

  void _writeChunk(
    StringBuffer buffer,
    PromptChunk chunk, {
    String? textOverride,
  }) {
    if (buffer.isNotEmpty) {
      buffer.writeln();
    }
    buffer.writeln(_formatChunk(chunk, textOverride: textOverride));
  }

  String _formatChunk(PromptChunk chunk, {String? textOverride}) {
    return '## ${chunk.title}\n${textOverride ?? chunk.text.trim()}';
  }

  String _clip(String text, int maxChars) {
    if (text.length <= maxChars) {
      return text;
    }
    final safeMax = maxChars < 32 ? 32 : maxChars;
    return '${text.substring(0, safeMax).trimRight()}\n[Context truncated]';
  }
}
