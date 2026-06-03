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
    this.command = '',
  });

  final String question;
  final List<TerminalPromptOption> options;
  final String command;

  factory TerminalPrompt.fromJson(Map<String, Object?> json) {
    final options = json['options'];
    return TerminalPrompt(
      question: json['question'] as String? ?? '',
      command: json['command'] as String? ?? '',
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
        'command': command,
        'options': options.map((option) => option.toJson()).toList(),
      };
}
