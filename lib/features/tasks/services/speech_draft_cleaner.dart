class SpeechDraftCleaner {
  static final RegExp _fillerPattern = RegExp(
    r'(嗯+|啊+|就是|那个|然后|怎么说呢|呃+|额+)',
    caseSensitive: false,
  );

  String clean(String rawText) {
    final input = rawText.trim();
    if (input.isEmpty) {
      return '';
    }

    return input
        .replaceAll(_fillerPattern, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[，,]\s*[，,]+'), '，')
        .trim();
  }
}
