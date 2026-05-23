import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/task_speech_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = TaskSpeechPolicy();
  const settings = TaskSpeechSettings();

  test('completed task speaks cleaned final result summary', () {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.completed,
      result: const TaskResult(
        status: 'success',
        summary: '''
已修复登录失败。

```dart
final token = await login();
```

flutter test
/Users/ironion/workspace/armin/lib/login.dart
可以验证。
''',
        changedFiles: [],
        validation: [],
        risks: [],
        nextActions: [],
      ),
    );

    final decision = policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.kind, TaskSpeechKind.result);
    expect(decision.text, contains('任务已完成'));
    expect(decision.text, contains('已修复登录失败'));
    expect(decision.text, isNot(contains('final token')));
    expect(decision.text, isNot(contains('flutter test')));
    expect(decision.text, isNot(contains('/Users/ironion')));
  });

  test('turn idle task speaks current output with continue prompt', () {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '已完成第一轮检查。',
    );

    final decision = policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.text, contains('已完成第一轮检查'));
    expect(decision.text, contains('本轮输出已暂停，可以继续补充指令'));
  });

  test('need approval task speaks confirmation prompt without command detail',
      () {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needApproval,
      approval: const ApprovalRequest(
        reason: '删除临时构建产物，风险中等。',
        command: 'rm -rf build',
        risk: 'medium',
      ),
    );

    final decision = policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.kind, TaskSpeechKind.attention);
    expect(decision.text, contains('需要你确认一个操作'));
    expect(decision.text, contains('删除临时构建产物'));
    expect(decision.text, isNot(contains('rm -rf')));
  });

  test('settings can disable result and attention speech separately', () {
    final previous = _task(status: TaskStatus.running);
    final completed = previous.copyWith(
      status: TaskStatus.completed,
      shortSummary: '已完成',
    );
    final attention = previous.copyWith(
      status: TaskStatus.needAttention,
      shortSummary: '需要用户处理',
    );

    expect(
      policy
          .decide(
            previous: previous,
            current: completed,
            settings: const TaskSpeechSettings(speakResults: false),
          )
          .shouldSpeak,
      isFalse,
    );
    expect(
      policy
          .decide(
            previous: previous,
            current: attention,
            settings: const TaskSpeechSettings(speakAttention: false),
          )
          .shouldSpeak,
      isFalse,
    );
  });
}

TaskSession _task({required TaskStatus status}) {
  final now = DateTime(2026, 5, 24);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '/tmp/armin',
      tmuxSessionName: 'armin-codex',
      agentCommand: 'codex',
      createdAt: now,
      updatedAt: now,
      password: 'secret-password',
    ),
    title: 'Task',
    status: status,
    createdAt: now,
    updatedAt: now,
    startedAt: now,
    rawSttText: '',
    cleanedDraft: 'Task',
    userText: 'Task',
    context: '',
    constraints: const {},
    finalPrompt: 'Task',
    secretRecords: const [],
    rawLog: '',
  );
}
