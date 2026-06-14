import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/agent/parsers/approval_request.dart';
import 'package:armin/features/agent/parsers/task_result.dart';
import 'package:armin/features/agent/parsers/terminal_prompt.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
import 'package:armin/features/voice/services/task_speech_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = TaskSpeechPolicy();
  const settings = TaskSpeechSettings();

  test('completed task speaks cleaned final result summary', () async {
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

    final decision = await policy.decide(
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

  test('turn idle task speaks current output with continue prompt', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '已完成第一轮检查。',
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('turn idle speech excludes follow-up input echoed in output', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '输出 hello world\nhello',
      turns: [
        _turnWithInput(1, '检查当前项目'),
        _turnWithInput(2, '输出 hello world'),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('turn idle speech uses the full current turn output', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        _turnWithInput(1, '输出 runbook-copilot'),
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: '''
completion: tls handshake eof
runbook-copilot 是面向工程团队的 RAG 事故排障助手，用于根据告警、服务名、日志和症状检索知识库并生成带引用的排障建议。
可以继续查看引用和日志。
''',
          rawOutput: '''
completion: tls handshake eof
runbook-copilot 是面向工程团队的 RAG 事故排障助手，用于根据告警、服务名、日志和症状检索知识库并生成带引用的排障建议。
可以继续查看引用和日志。
''',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'runbook-copilot 是面向工程团队的 RAG 事故排障助手。可以继续查看引用和日志。',
        speechSummary: 'runbook-copilot 是面向工程团队的 RAG 事故排障助手。可以继续查看引用和日志。',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('auto speech uses the latest turn card output source', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '旧的整任务摘要，不应直接播报',
      turns: [
        _turnWithInput(1, '输出 hello'),
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: 'hello world',
          rawOutput: 'hello world',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'hello world',
        speechSummary: 'hello world',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('auto speech uses latest raw turn output before stale cleaned output',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '旧摘要不应播报',
      turns: [
        _turnWithInput(1, '实现接口').copyWith(
          rawOutput: '旧结果',
          cleanedOutput: '旧结果',
        ),
        _turnWithInput(2, '确认 stats').copyWith(
          rawOutput: '''
旧结果
确认 stats
Thinking
 │ Checking current implementation.
▪ GET /stats/{code} 已经实现了，3 个相关测试全部通过。
''',
          cleanedOutput: '这个已经在上一轮实现了。让我确认一下当前代码状态。',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'GET /stats/{code} 已经实现了，3 个相关测试全部通过。',
        speechSummary: '',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(provider.lastRequest?.cleanedOutput, contains('GET /stats/{code}'));
    expect(
      provider.lastRequest?.cleanedOutput,
      isNot(contains('这个已经在上一轮实现了')),
    );
    expect(decision.text, contains('GET /stats/{code}'));
  });

  test('auto speech does not fallback to stale previous turn summary',
      () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      summary: 'Turn 1 result',
      turns: [
        _turnWithInput(1, '输出旧结果').copyWith(
          cleanedOutput: 'Turn 1 result',
          rawOutput: 'Turn 1 result',
        ),
      ],
    );
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: 'Turn 1 result',
      turns: [
        ...previous.turns,
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: '',
          rawOutput: '',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'Turn 1 result',
        speechSummary: 'Turn 1 result',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('auto speech can fallback to a new summary for the latest turn',
      () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      summary: '第一轮结果',
      turns: [_turnWithInput(1, '输出旧结果')],
    );
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '第二轮结果',
      turns: [
        ...previous.turns,
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: '',
          rawOutput: '',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: '第二轮结果',
        speechSummary: '第二轮结果',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('auto speech prefers display summary over provider speech summary',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        _turnWithInput(1, '输出 hello'),
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: 'hello world',
          rawOutput: 'hello world',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: '页面展示文本 hello world',
        speechSummary: '旧语音文本 should not win',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('auto speech reads all displayed card text without compacting',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      turns: [
        _turnWithInput(1, '生成长结果').copyWith(
          cleanedOutput: 'long result',
          rawOutput: 'long result',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary:
            '第一段说明当前任务已经完成并保留了关键背景。第二段说明验证步骤已经执行并且结果正常。第三段说明后续建议是观察真实设备上的语音播报完整性。',
        speechSummary: '短摘要不应该被使用',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('turn idle with prompt echo only speaks state rather than input',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '输出 hello world',
      turns: [
        _turnWithInput(1, '输出 hello world').copyWith(
          rawOutput: '',
          cleanedOutput: '',
        ),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('need approval task speaks confirmation prompt without command detail',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needApproval,
      approval: const ApprovalRequest(
        reason: '删除临时构建产物，风险中等。',
        command: 'rm -rf build',
        risk: 'medium',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('need approval on a later turn does not speak previous turn result',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needApproval,
      summary: 'Turn 1 old result should not be spoken',
      approval: const ApprovalRequest(
        reason: 'Turn 2 needs permission to inspect build output.',
        command: 'cat build.log',
        risk: 'low',
      ),
      turns: [
        _turnWithInput(1, '输出旧结果').copyWith(
          rawOutput: 'Turn 1 old result',
          cleanedOutput: 'Turn 1 old result',
        ),
        _turnWithInput(2, '继续检查').copyWith(
          rawOutput: '',
          cleanedOutput: '',
        ),
      ],
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: 'provider should not be used',
        speechSummary: 'provider should not be used',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('need approval speech can be disabled separately', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needApproval,
      approval: const ApprovalRequest(
        reason: '请确认删除临时文件。',
        command: 'rm -rf build',
        risk: 'medium',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: const TaskSpeechSettings(speakApprovalRequests: false),
    );

    expect(decision.shouldSpeak, isFalse);
  });

  test('settings can disable result and attention speech separately', () async {
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
      (await policy.decide(
        previous: previous,
        current: completed,
        settings: const TaskSpeechSettings(speakResults: false),
      ))
          .shouldSpeak,
      isFalse,
    );
    expect(
      (await policy.decide(
        previous: previous,
        current: attention,
        settings: const TaskSpeechSettings(speakAttention: false),
      ))
          .shouldSpeak,
      isFalse,
    );
  });

  test('need attention without current prompt or output does not speak summary',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needAttention,
      summary: '初始提示词不应该被播报',
      shortSummary: '任务已创建底下的内容不应该被播报',
      turns: [
        _turnWithInput(1, '初始任务').copyWith(
          rawOutput: '旧结果',
          cleanedOutput: '旧结果',
        ),
        _turnWithInput(2, '继续').copyWith(
          rawOutput: '',
          cleanedOutput: '',
          status: NativeOutputTurnStatus.needAttention,
        ),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isFalse);
  });

  test('need attention speaks current terminal prompt only', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.needAttention,
      summary: '旧摘要不应该被播报',
      terminalPrompt: const TerminalPrompt(
        question: 'Apply this change?',
        options: [
          TerminalPromptOption(key: '1', label: 'Allow once'),
          TerminalPromptOption(key: '2', label: 'Reject'),
        ],
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.text, contains('Apply this change?'));
    expect(decision.text, isNot(contains('旧摘要')));
  });

  test('stale text in a new turn is not replayed as latest speech', () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      summary: 'hello',
      turns: [_turn(1)],
    );
    final current = previous.copyWith(
      summary: 'hello',
      turns: [_turn(1), _turn(2)],
    );

    final first = await policy.decide(
      previous: _task(status: TaskStatus.running),
      current: previous,
      settings: settings,
    );
    final second = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(first.shouldSpeak, isTrue);
    expect(second.shouldSpeak, isTrue);
  });

  test('speech policy uses summary provider without raw log or status changes',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      status: TaskStatus.turnIdle,
      summary: '有用结果',
      rawLog: 'raw terminal log should not be summarized',
    );
    final provider = _CapturingSummaryProvider(
      const OutputSummary(
        displaySummary: '有用结果',
        speechSummary: '有用结果',
      ),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
      outputSummaryProvider: provider,
    );

    expect(decision.shouldSpeak, isTrue);
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

NativeOutputTurn _turn(int index) {
  final now = DateTime(2026, 5, 24, 10, index);
  return NativeOutputTurn(
    id: 'turn-task-1-$index',
    taskId: 'task-1',
    turnIndex: index,
    userInput: 'input $index',
    rawOutput: 'hello',
    cleanedOutput: 'hello',
    startedAt: now,
    lastOutputAt: now,
    status: NativeOutputTurnStatus.turnIdle,
  );
}

NativeOutputTurn _turnWithInput(int index, String input) {
  final turn = _turn(index);
  return turn.copyWith(userInput: input);
}

class _CapturingSummaryProvider implements OutputSummaryProvider {
  _CapturingSummaryProvider(this.summary);

  final OutputSummary summary;
  OutputSummaryRequest? lastRequest;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    lastRequest = request;
    return summary;
  }
}
