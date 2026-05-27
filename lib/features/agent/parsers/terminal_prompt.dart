class TerminalPromptOption {
  const TerminalPromptOption({
    required this.key,
    required this.label,
  });

  final String key;
  final String label;

  factory TerminalPromptOption.fromJson(Map<String, Object?> json) {
    return TerminalPromptOption(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
        'key': key,
        'label': label,
      };
}

class TerminalPrompt {
  const TerminalPrompt({
    required this.question,
    required this.options,
  });

  final String question;
  final List<TerminalPromptOption> options;

  factory TerminalPrompt.fromJson(Map<String, Object?> json) {
    final options = json['options'];
    return TerminalPrompt(
      question: json['question'] as String? ?? '',
      options: options is List
          ? options
              .whereType<Map<String, Object?>>()
              .map(TerminalPromptOption.fromJson)
              .toList(growable: false)
          : const [],
    );
  }

  Map<String, Object?> toJson() => {
        'question': question,
        'options': options.map((option) => option.toJson()).toList(),
      };
}
