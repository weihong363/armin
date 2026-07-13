import '../../../core/models/task_status.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../../agent/services/agent_runtime_adapter.dart';
import '../models/native_output_turn.dart';
import 'loop_runtime_protocol.dart';
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
    required this.loopState,
    required this.loopNextAction,
  });

  final String displaySummary;
  final String speechSummary;
  final DeliverableProvenance provenance;
  final String loopState;
  final String loopNextAction;
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
    AgentRuntimeAdapter runtimeAdapter = AgentRuntimeAdapter.defaultAdapter,
  })  : _turnOutputSlicer = turnOutputSlicer,
        _runtimeAdapter = runtimeAdapter;

  final TurnOutputSlicer _turnOutputSlicer;
  final AgentRuntimeAdapter _runtimeAdapter;

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
    final turnOutput = candidate.turn.cleanedOutput.trim();
    final outcome = LoopRuntimeProtocol.parse(turnOutput) ??
        LoopRuntimeProtocol.parse(evidence.text) ??
        LoopRuntimeProtocol.parse(candidate.turn.rawOutput);
    final strippedEvidence = LoopRuntimeProtocol.strip(evidence.text);
    final userVisibleEvidence = strippedEvidence.isNotEmpty
        ? strippedEvidence
        : LoopRuntimeProtocol.strip(turnOutput);
    final summary = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: userVisibleEvidence,
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
      loopState: outcome?.state.name ?? '',
      loopNextAction: outcome?.nextAction ?? '',
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
    final turn = turns[index];
    final cleanedOutput = _turnOutputSlicer.outputForTurn(
      turns,
      index,
      maxOutputChars: maxOutputChars,
    );
    return _runtimeAdapter.finalEvidenceFor(
      const AgentOutputCleaner().clean(cleanedOutput),
      prompt: turn.userInput,
      allowPlainText: isDeliverableStatus(turn.status),
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

  bool _isDeliverableCandidate(List<NativeOutputTurn> turns, int index) {
    final turn = turns[index];
    if (isDeliverableStatus(turn.status)) {
      return true;
    }
    if (turn.status != NativeOutputTurnStatus.needAttention) {
      return false;
    }
    final evidence = _runtimeAdapter.finalEvidenceFor(
      const AgentOutputCleaner().clean(
        _turnOutputSlicer.outputForTurn(turns, index),
      ),
      prompt: turn.userInput,
    );
    return evidence.isNotEmpty;
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
