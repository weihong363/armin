enum SnippetContentType {
  taskDescription,
  voiceTranscript,
  agentSummary,
  agentOutput,
  executionLog,
  filePath,
  sessionId,
  errorMessage,
  genericText,
}

enum TruncationMode {
  headTail,
  tail,
  middle,
}

class DisplaySnippet {
  const DisplaySnippet({
    required this.fullText,
    required this.visibleText,
    required this.contentType,
    required this.truncationMode,
    required this.truncated,
  });

  final String fullText;
  final String visibleText;
  final SnippetContentType contentType;
  final TruncationMode truncationMode;
  final bool truncated;
}

class SemanticSnippetBuilder {
  const SemanticSnippetBuilder({this.defaultMaxChars = 180});

  final int defaultMaxChars;

  DisplaySnippet build(
    String text, {
    required SnippetContentType contentType,
    int? maxChars,
  }) {
    final fullText = text;
    final normalized = text.trim();
    final limit = _safeLimit(maxChars ?? defaultMaxChars);
    final mode = _modeFor(contentType);
    if (normalized.length <= limit) {
      return DisplaySnippet(
        fullText: fullText,
        visibleText: normalized,
        contentType: contentType,
        truncationMode: mode,
        truncated: false,
      );
    }
    return DisplaySnippet(
      fullText: fullText,
      visibleText: _truncate(normalized, limit, mode),
      contentType: contentType,
      truncationMode: mode,
      truncated: true,
    );
  }

  TruncationMode _modeFor(SnippetContentType contentType) {
    return switch (contentType) {
      SnippetContentType.executionLog => TruncationMode.tail,
      SnippetContentType.filePath ||
      SnippetContentType.sessionId =>
        TruncationMode.middle,
      SnippetContentType.taskDescription ||
      SnippetContentType.voiceTranscript ||
      SnippetContentType.agentSummary ||
      SnippetContentType.agentOutput ||
      SnippetContentType.errorMessage ||
      SnippetContentType.genericText =>
        TruncationMode.headTail,
    };
  }

  String _truncate(String text, int limit, TruncationMode mode) {
    return switch (mode) {
      TruncationMode.tail => '...${text.substring(text.length - limit)}',
      TruncationMode.middle => _middle(text, limit),
      TruncationMode.headTail => _headTail(text, limit),
    };
  }

  String _headTail(String text, int limit) {
    final headSize = (limit * 0.62).round();
    final tailSize = limit - headSize;
    final head = text.substring(0, headSize).trimRight();
    final tail = text.substring(text.length - tailSize).trimLeft();
    return '$head...$tail';
  }

  String _middle(String text, int limit) {
    final headSize = (limit * 0.45).round();
    final tailSize = limit - headSize;
    final head = text.substring(0, headSize).trimRight();
    final tail = text.substring(text.length - tailSize).trimLeft();
    return '$head...$tail';
  }

  int _safeLimit(int value) {
    return value < 24 ? 24 : value;
  }
}
