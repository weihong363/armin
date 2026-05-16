import '../models/secret_entry.dart';
import '../models/task_constraint.dart';
import 'secret_redactor.dart';

class PromptTemplateBuilder {
  PromptTemplateBuilder({SecretRedactor? redactor})
      : _redactor = redactor ?? SecretRedactor();

  static const templateVersion = 'armin-task-v1';

  final SecretRedactor _redactor;

  String build({
    required String taskDescription,
    required String context,
    required Set<TaskConstraint> constraints,
    required List<SecretEntry> secrets,
  }) {
    final safeTask = _redactor.redactInlineSecrets(taskDescription.trim());
    final safeContext = _redactor.redactInlineSecrets(context.trim());
    final constraintText = constraints.isEmpty
        ? '- 优先最小改动'
        : constraints.map((constraint) => '- ${constraint.label}').join('\n');
    final secretsText = _redactor.placeholdersOnly(secrets);

    return '''
请完成以下任务。执行过程中自行读取文件、修改代码、运行必要测试。
不要频繁询问我，除非遇到高风险操作、信息不足或需要用户决策。

任务：
$safeTask

补充上下文：
${safeContext.isEmpty ? '无' : safeContext}

执行约束：
$constraintText

敏感信息：
$secretsText

要求：
- 优先最小改动。
- 不要进行无关重构。
- 不要自动 git commit / git push，除非用户明确要求。
- 遇到高风险命令必须暂停并请求确认。
- 完成后必须输出结构化结果，格式如下：

TASK_RESULT_START
status: success | failed | need_user_input
summary: ...
changed_files:
- ...
validation:
- ...
risks:
- ...
next_actions:
- ...
TASK_RESULT_END

如果需要用户确认，输出：

NEED_APPROVAL_START
reason: ...
command: ...
risk: low | medium | high
NEED_APPROVAL_END''';
  }
}
