import '../../../shared/governance_rules.dart';
import '../../../shared/line_noise_filter.dart';

class AgentOutputCleaner {
  const AgentOutputCleaner();

  String clean(String output) {
    final withoutAnsi = output
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '\n');

    final rawLines = withoutAnsi.split('\n');
    final withoutApprovalDecisions = _removeApprovalDecisionBlocks(rawLines);
    final withoutThinking = _removeThinkingBlocks(withoutApprovalDecisions);
    final lines = withoutThinking
        .map(_cleanLine)
        .where((line) => line.isNotEmpty && !_isNoiseLine(line))
        .toList();
    return _squashEmptyLines(lines).join('\n').trim();
  }

  List<String> _removeApprovalDecisionBlocks(List<String> lines) {
    final result = <String>[];
    var insideDecisionEcho = false;
    for (final line in lines) {
      if (_isApprovalDecisionHeader(line)) {
        insideDecisionEcho = true;
        continue;
      }
      if (insideDecisionEcho) {
        if (_isApprovalDecisionContinuation(line)) {
          continue;
        }
        insideDecisionEcho = false;
      }
      result.add(line);
    }
    return result;
  }

  bool _isApprovalDecisionHeader(String line) {
    return _controlLine(line).startsWith('approval_decision:');
  }

  bool _isApprovalDecisionContinuation(String line) {
    final normalized = _controlLine(line);
    if (normalized.isEmpty) {
      return true;
    }
    return normalized.startsWith('decision:') ||
        normalized.startsWith('reason:') ||
        normalized.startsWith('approved:') ||
        normalized.startsWith('rejected:') ||
        normalized.startsWith('apply this decision') ||
        normalized.contains('pending approval request');
  }

  String _controlLine(String line) {
    return line
        .trimLeft()
        .replaceFirst(RegExp(r'^[>❯▸›\-\s]+'), '')
        .trim()
        .toLowerCase();
  }

  List<String> _removeThinkingBlocks(List<String> lines) {
    final result = <String>[];
    var insideThinking = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isThinkingHeader(line)) {
        insideThinking = true;
        continue;
      }
      if (!insideThinking) {
        result.add(line);
        continue;
      }
      if (_isThinkingContinuation(line)) {
        continue;
      }
      insideThinking = false;
      result.add(line);
    }
    return result;
  }

  bool _isThinkingHeader(String line) {
    final trimmed = line.trim().toLowerCase();
    return trimmed == 'thinking' ||
        trimmed == 'thinking...' ||
        trimmed == 'thinking\u2026';
  }

  bool _isThinkingContinuation(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    if (_looksLikeBulletDeliverable(line)) {
      return false;
    }
    if (_looksLikeTableContent(line)) {
      return false;
    }
    if (line.startsWith(' ') || line.startsWith('\t')) {
      return true;
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('done.') || lower.startsWith('perfect,')) {
      return true;
    }
    if (_looksLikeToolTrace(trimmed) || _looksLikeCodeTrace(trimmed)) {
      return true;
    }
    return !_looksLikeDeliverableLine(trimmed);
  }

  bool _looksLikeTableContent(String line) {
    final trimmed = line.trimLeft();
    if ('│'.allMatches(trimmed).length >= 2) {
      return true;
    }
    return RegExp(r'[┬┼┴]').hasMatch(trimmed);
  }

  bool _looksLikeBulletDeliverable(String line) {
    final trimmed = line.trimLeft();
    if (!RegExp(r'^▪\s+\S+').hasMatch(trimmed)) {
      return false;
    }
    final content = trimmed.replaceFirst(RegExp(r'^▪\s+'), '').trim();
    if (content.isEmpty) {
      return false;
    }
    if (_looksLikeTableContent(content)) {
      return true;
    }
    return !_looksLikeToolTrace(content) && !_looksLikeCodeTrace(content);
  }

  bool _looksLikeToolTrace(String line) {
    if (_looksLikeTableContent(line)) {
      return false;
    }
    return RegExp(r'^[A-Z][A-Za-z]*(?:\(|\{)').hasMatch(line) ||
        RegExp(r'^(Accepted|Rejected|Read|Write|Edited|Bash|Glob|Grep)\b')
            .hasMatch(line) ||
        RegExp(r'^\d+\s+').hasMatch(line) ||
        line.startsWith('└') ||
        line.startsWith('│') ||
        line.startsWith('├') ||
        line.startsWith('┌') ||
        line.startsWith('┘');
  }

  bool _looksLikeCodeTrace(String line) {
    final lower = line.toLowerCase();
    return lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('def ') ||
        lower.startsWith('function ') ||
        lower.startsWith('const ') ||
        lower.startsWith('final ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        line.startsWith('{') ||
        line.startsWith('}') ||
        line.startsWith('//') ||
        line.startsWith('# ');
  }

  bool _looksLikeDeliverableLine(String line) {
    final lower = line.toLowerCase();
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(line)) {
      if (line.contains('：') || line.contains(':')) {
        return true;
      }
      return RegExp(
        r'(已|完成|就绪|验证|通过|结果|输出|总结|如下|包含|创建|写入|修复|实现|更新|下一步|建议|宠物)',
      ).hasMatch(line);
    }
    return lower.contains('completed') ||
        lower.contains('done') ||
        lower.contains('created') ||
        lower.contains('updated') ||
        lower.contains('written') ||
        lower.contains('fixed') ||
        lower.contains('implemented') ||
        lower.contains('ready') ||
        lower.contains('result') ||
        lower.contains('summary') ||
        lower.contains('next step');
  }

  String semanticHashInput(String output) {
    return clean(output)
        .replaceAll(RegExp(r'\b\d+(?:\.\d+)?s\b'), '')
        .replaceAll(RegExp(r'\b\d+% context left\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanLine(String line) {
    if (RegExp(r"you['’]ve hit your usage limit", caseSensitive: false)
        .hasMatch(line)) {
      return '额度已用完，请稍后重试。';
    }
    final preserveTableLine = _looksLikeDelimitedTableLine(line);
    var cleaned = line;
    if (!preserveTableLine) {
      cleaned = cleaned.replaceFirst(RegExp(r'^[│|]\s*'), '');
    }
    return cleaned
        .replaceFirst(RegExp(r'^[›]\s*'), '')
        .replaceFirst(RegExp(r'^[✨⚠]\s*'), '')
        .replaceFirst(RegExp(r'^[•*-]\s+'), '')
        .replaceAll(
          RegExp(r'\bType your message or @path/to/file\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAuto Model\b.*', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\bShift\+Tab to Auto-accept Edits\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAGENTS\.md file\b.*', caseSensitive: false), '')
        .trim();
  }

  bool _looksLikeDelimitedTableLine(String line) {
    final trimmed = line.trimLeft();
    if (!(trimmed.startsWith('│') || trimmed.startsWith('|'))) {
      return false;
    }
    final delimiter = trimmed.startsWith('│') ? '│' : '|';
    return delimiter.allMatches(trimmed).length >= 2;
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    return line == '|' ||
        const LineNoiseFilter().isTerminalGraphic(line) ||
        line.startsWith('┌') ||
        line.startsWith('└') ||
        line.startsWith('┐') ||
        line.startsWith('┘') ||
        line.startsWith('─') ||
        line.startsWith('_') ||
        line.startsWith('━') ||
        lower.contains('openai codex') ||
        lower.contains('qoder cli') ||
        lower.startsWith('model:') ||
        lower.startsWith('directory:') ||
        lower.startsWith('gpt-') ||
        lower.startsWith('tip:') ||
        lower.startsWith('use /skills ') ||
        lower.startsWith('armin context governance') ||
        lower.startsWith('## user task') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('turn ') ||
        lower.startsWith('结果为：turn ') ||
        lower.startsWith('result: turn ') ||
        GovernanceRules.isGovernanceRuleEndsWith(lower) ||
        lower.startsWith('update available!') ||
        lower.startsWith('release notes:') ||
        lower.startsWith('press enter to continue') ||
        lower.startsWith('run npm install') ||
        lower.startsWith('see full release notes') ||
        lower.contains('credits exhausted') ||
        lower.contains('use /usage for details') ||
        lower.contains('use /upgrade for more') ||
        lower.contains('usage limit') ||
        lower.contains('quota exhausted') ||
        lower == 'thinking' ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.contains('signed in browser login') ||
        lower.contains('type your message or @path/to/file') ||
        lower.contains('auto model') ||
        lower.contains('shift+tab to auto-accept edits') ||
        lower.contains('agents.md file') ||
        lower.contains(' to view transcript') ||
        lower.contains('npm install -g @openai/codex') ||
        lower.contains('github.com/openai/codex/releases') ||
        lower.contains('chatgpt.com/codex?app-landing-page=true') ||
        lower.startsWith('skipped loading') ||
        lower.startsWith('/users/') ||
        lower.contains('invalid skill.md') ||
        lower.contains('invalid yaml') ||
        lower.contains('mapping values are not allowed in this context') ||
        lower.startsWith('are not allowed in this context') ||
        lower == 'find and fix a bug in @filename' ||
        lower == 'implement {feature}' ||
        lower == 'explain this codebase';
  }

  List<String> _squashEmptyLines(List<String> lines) {
    final result = <String>[];
    var lastWasEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && lastWasEmpty) {
        continue;
      }
      result.add(line);
      lastWasEmpty = isEmpty;
    }
    return result;
  }
}
