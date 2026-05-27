import '../models/secret_entry.dart';
import '../models/task_constraint.dart';
import 'prompt_governor.dart';
import 'secret_redactor.dart';

class PromptTemplateBuilder {
  PromptTemplateBuilder({SecretRedactor? redactor, PromptGovernor? governor})
      : _redactor = redactor ?? const SecretRedactor(),
        _governor = governor ?? const PromptGovernor();

  static const templateVersion = 'armin-task-v1';

  final SecretRedactor _redactor;
  final PromptGovernor _governor;

  String build({
    required String taskDescription,
    required String context,
    required Set<TaskConstraint> constraints,
    required List<SecretEntry> secrets,
  }) {
    final safeTask = _redactor.redactInlineSecrets(taskDescription.trim());
    final safeContext = _redactor.redactInlineSecrets(context.trim());
    final secretsText = _redactor.placeholdersOnly(secrets);
    final parts = [
      safeTask,
      if (safeContext.isNotEmpty) safeContext,
      if (secrets.isNotEmpty) secretsText,
    ];

    return _governor.apply(parts.join('\n\n'));
  }
}
