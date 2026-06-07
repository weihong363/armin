import '../models/task_constraint.dart';

class PromptGovernor {
  const PromptGovernor();

  static const templateVersion = 'armin-governance-v1';

  String apply(String userPrompt, {Set<TaskConstraint> constraints = const {}}) {
    final trimmed = userPrompt.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final rules = _rulesForConstraints(constraints);
    if (rules.isEmpty) {
      return trimmed;
    }
    return '${rules.join('\n')}\n\n$trimmed';
  }

  List<String> _rulesForConstraints(Set<TaskConstraint> constraints) {
    if (constraints.contains(TaskConstraint.analyzeOnly)) {
      return safe;
    }
    if (constraints.contains(TaskConstraint.allowChanges)) {
      return aggressive;
    }
    return balanced;
  }

  List<String> get aggressive {
    return const [
      'Armin context governance (aggressive):',
      '- You have full authority to create, modify, and delete files without asking.',
      '- Run any commands, tests, or builds needed to complete the task.',
      '- Only inspect files directly related to the task.',
      '- Never scan the entire repository.',
      '- Avoid reading docs/ and README unless necessary.',
      '- Do not analyze unrelated architecture.',
      '- Do not interrupt the user — proceed autonomously unless you encounter a hard blocker.',
    ];
  }

  List<String> get balanced {
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

  List<String> get safe {
    return const [
      'Armin context governance (safe):',
      '- Only inspect files directly related to the task.',
      '- Never scan the entire repository.',
      '- Avoid reading docs/ and README unless necessary.',
      '- Never modify any file — analysis and reporting only.',
      '- Do not run commands that alter state.',
      '- Do not analyze unrelated architecture.',
      '- Keep command output short.',
      '- Ask before any potentially risky read operation.',
    ];
  }
}
