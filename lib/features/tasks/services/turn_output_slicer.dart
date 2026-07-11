import '../models/native_output_turn.dart';

class TurnOutputSlicer {
  const TurnOutputSlicer();

  String outputForTurn(
    List<NativeOutputTurn> turns,
    int index, {
    List<String> extraFilterTexts = const [],
    int? maxOutputChars,
  }) {
    return _outputForTurn(
      turns,
      index,
      outputOf: (turn) => turn.cleanedOutput,
      previousOutputOf: (turn) => turn.cleanedOutput,
      extraFilterTexts: extraFilterTexts,
      maxOutputChars: maxOutputChars,
    );
  }

  String _outputForTurn(
    List<NativeOutputTurn> turns,
    int index, {
    required String Function(NativeOutputTurn turn) outputOf,
    required String Function(NativeOutputTurn turn) previousOutputOf,
    List<String> extraFilterTexts = const [],
    int? maxOutputChars,
  }) {
    if (index < 0 || index >= turns.length) {
      return '';
    }
    var output =
        _normalize(_tailWindow(outputOf(turns[index]), maxOutputChars));
    if (output.isEmpty) {
      return '';
    }

    output = _sliceByPromptBoundaries(output, turns, index);
    if (index > 0) {
      output = _removeImmediatePreviousSnapshot(
        output,
        _tailWindow(previousOutputOf(turns[index - 1]), maxOutputChars),
      );
    }
    output = _removePromptEchoLines(output, turns.take(index + 1));
    return _normalize(output);
  }

  String _tailWindow(String output, int? maxChars) {
    if (maxChars == null || maxChars <= 0 || output.length <= maxChars) {
      return output;
    }
    return output.substring(output.length - maxChars);
  }

  String _sliceByPromptBoundaries(
    String output,
    List<NativeOutputTurn> turns,
    int index,
  ) {
    final prompt = turns[index].userInput.trim();
    if (prompt.isEmpty) {
      return output;
    }
    final promptStart = output.lastIndexOf(prompt);
    if (promptStart < 0) {
      return output;
    }
    var scoped = output.substring(promptStart + prompt.length);
    for (var next = index + 1; next < turns.length; next++) {
      final nextPrompt = turns[next].userInput.trim();
      if (nextPrompt.isEmpty) {
        continue;
      }
      final nextStart = scoped.indexOf(nextPrompt);
      if (nextStart >= 0) {
        scoped = scoped.substring(0, nextStart);
        break;
      }
    }
    return scoped;
  }

  String _removeImmediatePreviousSnapshot(
    String output,
    String previous,
  ) {
    final previousOutput = _normalize(previous);
    if (previousOutput.isEmpty) {
      return output;
    }
    final lineSliced = _removeCommonLinePrefix(output, previousOutput);
    if (lineSliced.trim().isNotEmpty && lineSliced != output) {
      return lineSliced;
    }
    if (output.startsWith(previousOutput)) {
      return output.substring(previousOutput.length);
    }
    return output;
  }

  String _removeCommonLinePrefix(String output, String previousOutput) {
    final outputLines = output.split('\n');
    final previousLines = previousOutput.split('\n');
    var prefixLength = 0;
    while (prefixLength < outputLines.length &&
        prefixLength < previousLines.length &&
        outputLines[prefixLength].trim() ==
            previousLines[prefixLength].trim()) {
      prefixLength += 1;
    }
    if (prefixLength == 0) {
      return output;
    }
    return outputLines.skip(prefixLength).join('\n');
  }

  String _removePromptEchoLines(
    String output,
    Iterable<NativeOutputTurn> turns,
  ) {
    final prompts = turns
        .map((turn) => turn.userInput.trim())
        .where((prompt) => prompt.isNotEmpty)
        .toSet();
    if (prompts.isEmpty) {
      return output;
    }
    return output
        .split('\n')
        .where((line) => !prompts.contains(line.trim()))
        .join('\n');
  }

  String _normalize(String output) {
    return output
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .join('\n')
        .trim();
  }
}
