import '../models/secret_entry.dart';
import '../models/task_constraint.dart';
import 'prompt_context_chunker.dart';
import 'prompt_governor.dart';
import 'secret_redactor.dart';

class PromptTemplateBuilder {
  PromptTemplateBuilder({
    SecretRedactor? redactor,
    PromptGovernor? governor,
    PromptContextChunker? chunker,
  })  : _redactor = redactor ?? const SecretRedactor(),
        _governor = governor ?? const PromptGovernor(),
        _chunker = chunker ?? const PromptContextChunker();

  static const templateVersion = 'armin-task-v1';

  final SecretRedactor _redactor;
  final PromptGovernor _governor;
  final PromptContextChunker _chunker;

  String build({
    required String taskDescription,
    required String context,
    required Set<TaskConstraint> constraints,
    required List<SecretEntry> secrets,
  }) {
    final safeTask = _redactor.redactInlineSecrets(taskDescription.trim());
    final safeContext = _redactor.redactInlineSecrets(context.trim());
    final secretsText =
        secrets.isEmpty ? '' : _redactor.placeholdersOnly(secrets);
    final chunkedPrompt = _chunker.build(
      taskDescription: safeTask,
      context: safeContext,
      constraints: constraints,
      secretsText: secretsText,
    );

    return _governor.apply(chunkedPrompt, constraints: constraints);
  }
}
