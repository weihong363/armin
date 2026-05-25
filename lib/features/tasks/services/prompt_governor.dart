class PromptGovernor {
  const PromptGovernor();

  static const templateVersion = 'armin-governance-v1';

  String apply(String userPrompt) {
    final trimmed = userPrompt.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return '${rules.join('\n')}\n\n$trimmed';
  }

  List<String> get rules {
    return const [
      'Armin context governance:',
      '- Only inspect files directly related to the task.',
      '- Never scan the entire repository.',
      '- Avoid reading docs/ and README unless necessary.',
      '- Keep edits minimal and focused.',
      '- Do not analyze unrelated architecture.',
      '- Run only targeted tests.',
      '- Keep command output short.',
    ];
  }
}
