import '../../../core/models/task_status.dart';
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
      if (!isDeliverableStatus(turn.status)) {
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
      if (isDeliverableStatus(turn.status)) {
        return DeliverableCandidate(index: index, turn: turn);
      }
    }
    return null;
  }

  int candidateCount(List<NativeOutputTurn> turns) {
    return turns.where((turn) => isDeliverableStatus(turn.status)).length;
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
    final rawOutput = _turnOutputSlicer.rawOutputForTurn(
      turns,
      index,
      maxOutputChars: maxOutputChars,
    );
    if (rawOutput.trim().isNotEmpty) {
      return rawOutput;
    }
    return _turnOutputSlicer.outputForTurn(
      turns,
      index,
      maxOutputChars: maxOutputChars,
    );
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

  String _fingerprint(String text) {
    var hash = 0x811c9dc5;
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
