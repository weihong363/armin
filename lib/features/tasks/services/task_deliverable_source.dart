import '../../../core/models/task_status.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../models/native_output_turn.dart';
import 'output_summary_provider.dart';
import 'turn_output_slicer.dart';

enum DeliverableEvidenceKind { turnOutput }

class DeliverableCandidate {
  const DeliverableCandidate({
    required this.index,
    required this.turn,
    this.kind = DeliverableEvidenceKind.turnOutput,
  });

  final int index;
  final NativeOutputTurn turn;
  final DeliverableEvidenceKind kind;
}

class DeliverableEvidence {
  const DeliverableEvidence({
    required this.candidate,
    required this.text,
    required this.fingerprint,
  });

  final DeliverableCandidate candidate;
  final String text;
  final String fingerprint;
}

class ResolvedDeliverable {
  const ResolvedDeliverable({
    required this.displaySummary,
    required this.speechSummary,
    required this.provenance,
  });

  final String displaySummary;
  final String speechSummary;
  final DeliverableProvenance provenance;
}

class DeliverableProvenance {
  const DeliverableProvenance({
    required this.turnId,
    required this.turnIndex,
    required this.evidenceKind,
    required this.evidenceFingerprint,
    required this.evidenceLength,
  });

  final String turnId;
  final int turnIndex;
  final DeliverableEvidenceKind evidenceKind;
  final String evidenceFingerprint;
  final int evidenceLength;
}

class DeliverableResolveContext {
  const DeliverableResolveContext({
    required this.status,
    required this.taskTitle,
    required this.agentCommand,
  });

  final TaskStatus status;
  final String taskTitle;
  final String agentCommand;
}

class TaskDeliverableSource {
  const TaskDeliverableSource({
    TurnOutputSlicer turnOutputSlicer = const TurnOutputSlicer(),
  }) : _turnOutputSlicer = turnOutputSlicer;

  final TurnOutputSlicer _turnOutputSlicer;

  List<DeliverableCandidate> candidates(
    List<NativeOutputTurn> turns, {
    required int limit,
  }) {
    final candidates = <DeliverableCandidate>[];
    for (var index = turns.length - 1; index >= 0; index--) {
      final turn = turns[index];
      if (!_isDeliverableCandidate(turns, index)) {
        continue;
      }
      candidates.add(DeliverableCandidate(index: index, turn: turn));
      if (candidates.length >= limit) {
        break;
      }
    }
    return candidates;
  }

  DeliverableCandidate? latestCandidate(List<NativeOutputTurn> turns) {
    for (var index = turns.length - 1; index >= 0; index--) {
      final turn = turns[index];
      if (_isDeliverableCandidate(turns, index)) {
        return DeliverableCandidate(index: index, turn: turn);
      }
    }
    return null;
  }

  int candidateCount(List<NativeOutputTurn> turns) {
    var count = 0;
    for (var index = 0; index < turns.length; index += 1) {
      if (_isDeliverableCandidate(turns, index)) {
        count += 1;
      }
    }
    return count;
  }

  Future<ResolvedDeliverable?> resolve(
    List<NativeOutputTurn> turns,
    DeliverableCandidate candidate, {
    required OutputSummaryProvider provider,
    required DeliverableResolveContext context,
    int? maxOutputChars,
  }) async {
    final evidence = evidenceFor(
      turns,
      candidate,
      maxOutputChars: maxOutputChars,
    );
    if (evidence == null) {
      return null;
    }
    final summary = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: evidence.text,
        status: context.status,
        taskTitle: context.taskTitle,
        promptInputs: [candidate.turn.userInput],
        agentCommand: context.agentCommand,
      ),
    );
    final displaySummary = summary.displaySummary.trim();
    if (displaySummary.isEmpty) {
      return null;
    }
    return ResolvedDeliverable(
      displaySummary: displaySummary,
      speechSummary: summary.speechSummary.trim(),
      provenance: DeliverableProvenance(
        turnId: candidate.turn.id,
        turnIndex: candidate.turn.turnIndex,
        evidenceKind: candidate.kind,
        evidenceFingerprint: evidence.fingerprint,
        evidenceLength: evidence.text.length,
      ),
    );
  }

  DeliverableEvidence? evidenceFor(
    List<NativeOutputTurn> turns,
    DeliverableCandidate candidate, {
    int? maxOutputChars,
  }) {
    final text = evidenceTextForTurn(
      turns,
      candidate.index,
      maxOutputChars: maxOutputChars,
    );
    if (text.trim().isEmpty) {
      return null;
    }
    return DeliverableEvidence(
      candidate: candidate,
      text: text,
      fingerprint: _fingerprint(text),
    );
  }

  String evidenceTextForTurn(
    List<NativeOutputTurn> turns,
    int index, {
    int? maxOutputChars,
  }) {
    final cleanedOutput = _turnOutputSlicer.outputForTurn(
      turns,
      index,
      maxOutputChars: maxOutputChars,
    );
    if (_looksLikeUsableEvidence(cleanedOutput)) {
      return cleanedOutput;
    }
    return '';
  }

  bool _looksLikeUsableEvidence(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    if (RegExp(r'\barmin[a-z0-9_]*\b').hasMatch(lower)) {
      return true;
    }
    if (lower.contains('status=pass') ||
        lower.contains('completed successfully') ||
        lower.contains('all tests passed') ||
        lower.contains('tests passed') ||
        trimmed.contains('已完成') ||
        trimmed.contains('全部通过') ||
        trimmed.contains('测试通过')) {
      return true;
    }
    if (lower.startsWith('let me ') ||
        lower.startsWith("i'll ") ||
        lower.startsWith('i will ') ||
        lower.startsWith('i need to ') ||
        lower.contains('让我确认') ||
        lower.contains('我先') ||
        lower.contains('我会')) {
      return false;
    }
    return trimmed.length >= 2;
  }

  bool isDeliverableStatus(NativeOutputTurnStatus status) {
    return switch (status) {
      NativeOutputTurnStatus.needAttention ||
      NativeOutputTurnStatus.running =>
        false,
      NativeOutputTurnStatus.turnIdle ||
      NativeOutputTurnStatus.runtimeLost ||
      NativeOutputTurnStatus.failed ||
      NativeOutputTurnStatus.completedByUser ||
      NativeOutputTurnStatus.failedByUser ||
      NativeOutputTurnStatus.stopped =>
        true,
    };
  }

  bool _isDeliverableCandidate(List<NativeOutputTurn> turns, int index) {
    final turn = turns[index];
    if (isDeliverableStatus(turn.status)) {
      return true;
    }
    if (turn.status != NativeOutputTurnStatus.needAttention) {
      return false;
    }
    return _looksLikeFinalEvidence(
      _turnOutputSlicer.outputForTurn(turns, index),
      turn.userInput,
    );
  }

  bool _looksLikeFinalEvidence(String text, String prompt) {
    final trimmed = const AgentOutputCleaner().clean(text).trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final semantic = _withoutPromptEchoLines(trimmed, prompt).trim();
    if (semantic.isEmpty) {
      return false;
    }
    final lower = semantic.toLowerCase();
    return _hasFinalMarkerLine(trimmed, prompt) ||
        lower.contains('status=pass') ||
        lower.contains('completed successfully') ||
        lower.contains('all tests passed') ||
        lower.contains('tests passed') ||
        semantic.contains('已完成') ||
        semantic.contains('全部通过') ||
        semantic.contains('测试通过');
  }

  bool _hasFinalMarkerLine(String text, String prompt) {
    final compactPrompt = _compactForEcho(prompt);
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (!RegExp(r'^(?:[▪■●]\s*)?ARMIN[A-Z0-9_]*\b').hasMatch(trimmed)) {
        continue;
      }
      final compactLine = _compactForEcho(trimmed);
      final isPromptEcho = compactPrompt.length >= compactLine.length &&
          compactLine.length >= 8 &&
          compactPrompt.contains(compactLine);
      final isAgentBullet =
          RegExp(r'^[▪■●]\s*ARMIN[A-Z0-9_]*\b').hasMatch(trimmed);
      if (!isPromptEcho || isAgentBullet) {
        return true;
      }
    }
    return false;
  }

  String _compactForEcho(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  String _withoutPromptEchoLines(String text, String prompt) {
    final compactPrompt = _compactForEcho(prompt);
    if (compactPrompt.length < 8) {
      return text;
    }
    return text.split('\n').where((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        return false;
      }
      if (RegExp(r'^[▪■●]\s*ARMIN[A-Z0-9_]*\b').hasMatch(trimmed)) {
        return true;
      }
      final compactLine = _compactForEcho(trimmed);
      return compactLine.length < 8 || !compactPrompt.contains(compactLine);
    }).join('\n');
  }

  String _fingerprint(String text) {
    var hash = 0x811c9dc5;
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
