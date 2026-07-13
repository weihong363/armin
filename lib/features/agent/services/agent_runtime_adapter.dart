import '../models/agent_approval_config.dart';

class AgentRuntimeAdapter {
  const AgentRuntimeAdapter(this.agentType);

  factory AgentRuntimeAdapter.forCommand(String agentCommand) {
    return AgentRuntimeAdapter(AgentTypeDetection.detect(agentCommand));
  }

  static const defaultAdapter = AgentRuntimeAdapter(AgentType.qoder);

  final AgentType agentType;

  bool containsActiveWork(List<String> lines) {
    final lastDeliverableIndex = lines.lastIndexWhere(
      (line) => looksLikeDeliverableLine(line) && !isBackgroundTaskLine(line),
    );
    final activeWindow =
        lastDeliverableIndex < 0 ? lines : lines.skip(lastDeliverableIndex + 1);
    return activeWindow.any((line) => _isActiveWorkInWindow(line, lines));
  }

  bool containsIdleInputPrompt(List<String> lines) {
    return lines.any((line) {
      final lower = line.toLowerCase();
      return lower.contains('type your message or @path/to/file') ||
          lower.contains('type your message') ||
          lower.contains('press enter to continue');
    });
  }

  bool containsActiveExecutionChrome(List<String> lines) {
    return lines.any((line) {
      final lower = line.toLowerCase();
      return lower.contains('esc to cancel') ||
          lower.contains('thinking...') ||
          lower.contains('thinking…');
    });
  }

  bool hasAgentWorkEvidence(List<String> lines) {
    return lines.any((line) {
      final normalized =
          _statusWord(line).replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
      final lower = normalized.toLowerCase();
      if (lower.isEmpty || _isTerminalChromeLine(lower)) {
        return false;
      }
      return line.trimLeft().startsWith(RegExp('[▪▫■●]')) ||
          _looksLikeToolTrace(normalized) ||
          _looksLikePlanningLine(lower);
    });
  }

  bool looksLikeDeliverableLine(String line) {
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

  bool hasHighConfidenceDeliverable(List<String> lines) {
    return finalEvidenceFor(lines.join('\n')).isNotEmpty;
  }

  String finalEvidenceFor(
    String output, {
    String prompt = '',
    bool allowPlainText = false,
  }) {
    final lines = output.split('\n').map((line) => line.trimRight()).toList();
    final agentBlock = _latestAgentResultBlock(lines, prompt);
    if (agentBlock.isNotEmpty) {
      return agentBlock;
    }
    final marker = _standaloneFinalMarker(lines, prompt);
    if (marker.isNotEmpty) {
      return marker;
    }
    final explicit = _explicitCompletionBlock(lines, prompt);
    if (explicit.isNotEmpty) {
      return explicit;
    }
    return allowPlainText ? _plainSettledEvidence(lines, prompt) : '';
  }

  bool isBackgroundTaskLine(String line) {
    if (!line.startsWith('▪')) {
      return false;
    }
    final lower = line.toLowerCase();
    return lower.contains('background') &&
        (lower.contains('will complete') || lower.contains('is now running'));
  }

  bool _isActiveWorkInWindow(String line, List<String> lines) {
    final lower = line.toLowerCase();
    if (lower.contains('esc to cancel')) {
      return _isEscToCancelLine(lower, lines);
    }
    if (_isTerminalChromeLine(lower)) {
      return false;
    }
    final normalized = _statusWord(line);
    final withoutBullet =
        normalized.replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
    if (_looksLikeActiveWorkLine(withoutBullet)) {
      return true;
    }
    return normalized == 'working' ||
        normalized == 'running' ||
        (normalized.contains('thinking') && normalized != 'thinking') ||
        normalized.contains('yolo') ||
        normalized.contains('auto mode') ||
        normalized.contains('bash(');
  }

  bool _isEscToCancelLine(String lower, List<String> lines) {
    if (!lower.contains('esc to cancel')) {
      return false;
    }
    if (lower.contains('thinking') || lower.contains('working')) {
      return !hasHighConfidenceDeliverable(lines) &&
          (_hasRecentWorkContext(lines) || _hasPromptEchoContext(lines));
    }
    return !hasHighConfidenceDeliverable(lines) && _hasRecentWorkContext(lines);
  }

  bool _isTerminalChromeLine(String lower) {
    return lower.contains('shift+tab to auto') ||
        lower.contains('shift+tab to accept edits') ||
        lower.contains('auto model') ||
        lower.contains('model · ctx') ||
        lower.contains('try /effort') ||
        lower.contains('try /model to switch models') ||
        lower.contains('enjoy off-peak discount') ||
        RegExp(r'\b\d+\s+mcp servers?\s*[·|]\s*\d+\s+skills\b')
            .hasMatch(lower) ||
        lower.contains('for shortcuts') ||
        lower.contains('type your message or @path/to/file');
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
    return _looksLikeToolTrace(line) ||
        _looksLikePlanningLine(lower) ||
        line.startsWith('让我') ||
        line.startsWith('我先') ||
        line.startsWith('我会') ||
        line.startsWith('我将');
  }

  bool _looksLikePlanningLine(String lower) {
    if (agentType != AgentType.codex && agentType != AgentType.qoder) {
      return false;
    }
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
        lower.contains(' let me ') ||
        lower.startsWith('让我') ||
        lower.startsWith('我先') ||
        lower.startsWith('我会') ||
        lower.startsWith('我将') ||
        lower.contains('让我确认');
  }

  String _latestAgentResultBlock(List<String> lines, String prompt) {
    List<String>? latest;
    List<String>? current;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      final bullet = RegExp(r'^[▪▫■●]\s*(.*)$').firstMatch(line);
      if (bullet != null) {
        final content = bullet.group(1)?.trim() ?? '';
        current = _isFinalAgentContent(content) ? <String>[content] : null;
        if (current != null) latest = current;
        continue;
      }
      if (current == null || line.isEmpty) continue;
      if (_isLoopProtocolControlLine(line)) {
        continue;
      }
      if (RegExp(r'^ARMIN[A-Z0-9_]*\b').hasMatch(line)) {
        current.add(line);
        continue;
      }
      if (_isTerminalChromeLine(line.toLowerCase()) ||
          _looksLikeToolTrace(line) ||
          line.startsWith('└') ||
          _isPromptEcho(line, prompt)) {
        continue;
      }
      current.add(line);
    }
    return latest?.join('\n').trim() ?? '';
  }

  bool _isFinalAgentContent(String content) {
    if (content.isEmpty || _looksLikeToolTrace(content)) return false;
    final lower = content.toLowerCase();
    return !lower.startsWith('initializing') &&
        !_looksLikePlanningLine(lower) &&
        !isBackgroundTaskLine('▪ $content');
  }

  String _standaloneFinalMarker(List<String> lines, String prompt) {
    final markers = lines.where((line) {
      final trimmed = line.trim();
      final isAgentBullet =
          RegExp(r'^[▪▫■●]\s*ARMIN[A-Z0-9_]*\b').hasMatch(trimmed);
      final isScopedPlainMarker =
          prompt.isNotEmpty && RegExp(r'^ARMIN[A-Z0-9_]*\b').hasMatch(trimmed);
      return (isAgentBullet || isScopedPlainMarker) &&
          !_isLoopProtocolControlLine(trimmed) &&
          !_isPromptEcho(trimmed, prompt);
    });
    return markers.join('\n').trim();
  }

  bool _isLoopProtocolControlLine(String line) {
    final normalized =
        line.replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim().toUpperCase();
    return normalized == 'ARMIN_LOOP_OUTCOME_BEGIN' ||
        normalized == 'ARMIN_LOOP_OUTCOME_END';
  }

  String _explicitCompletionBlock(List<String> lines, String prompt) {
    for (var index = lines.length - 1; index >= 0; index--) {
      final line = lines[index].trim();
      if (_isPromptEcho(line, prompt) || !_isExplicitCompletion(line)) continue;
      return line.replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
    }
    return '';
  }

  bool _isExplicitCompletion(String line) {
    final normalized = line.replaceFirst(RegExp(r'^[▪▫■●]\s*'), '').trim();
    final lower = normalized.toLowerCase();
    return lower.startsWith('done.') ||
        lower.startsWith("i've created ") ||
        lower.contains('completed successfully') ||
        lower.contains('tests passed') ||
        lower.contains('all checks passed') ||
        normalized.contains('已完成') ||
        normalized.contains('已创建') ||
        normalized.contains('全部通过') ||
        normalized.contains('测试通过');
  }

  String _plainSettledEvidence(List<String> lines, String prompt) {
    final semantic = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !_isPromptEcho(line, prompt))
        .where((line) => !_isTerminalChromeLine(line.toLowerCase()))
        .where((line) => !_looksLikeToolTrace(line))
        .where((line) => !line.startsWith('└'))
        .toList(growable: false);
    if (semantic.isEmpty ||
        semantic.every((line) => _looksLikePlanningLine(line.toLowerCase()))) {
      return '';
    }
    return semantic.join('\n').trim();
  }

  bool _isPromptEcho(String line, String prompt) {
    final compactPrompt = prompt.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final compactLine = line.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return compactPrompt.length >= 8 &&
        compactLine.length >= 8 &&
        compactPrompt.contains(compactLine);
  }

  bool _looksLikeToolTrace(String line) {
    return RegExp(
      r'^(?:bash|glob|grep|read|write|edit|multiedit|list|ls|cat)\s*\(',
      caseSensitive: false,
    ).hasMatch(line);
  }

  String _statusWord(String line) {
    return line
        .replaceAll(RegExp(r'^[›>\-*•\s]+'), '')
        .replaceAll(RegExp(r'[.…]+$'), '')
        .trim();
  }
}
