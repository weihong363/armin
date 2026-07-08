import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/runtime/models/approval_state.dart';
import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:armin/features/voice/services/task_speech_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = TaskSpeechPolicy();
  const settings = TaskSpeechSettings();

  test('completed task speaks cleaned final result summary', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      turns: [
        _turn(1).copyWith(rawOutput: '''
已修复登录失败。

```dart
final token = await login();
```

flutter test
/Users/ironion/workspace/armin/lib/login.dart
可以验证。
''', cleanedOutput: '', deliverable: _deliverable('已修复登录失败。可以验证。')),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      currentStatus: TaskStatus.completed,
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
      turns: [_turn(1).copyWith(rawOutput: '已完成第一轮检查。')],
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
      turns: [
        _turnWithInput(1, '检查当前项目'),
        _turnWithInput(2, '输出 hello world').copyWith(clearDeliverable: true),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isFalse);
  });

  test('turn idle speech uses the full current turn output', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
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
          deliverable: _deliverable(
            'runbook-copilot 是面向工程团队的 RAG 事故排障助手。可以继续查看引用和日志。',
          ),
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

  test('auto speech uses the latest turn card output source', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      turns: [
        _turnWithInput(1, '输出 hello'),
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: 'hello world',
          rawOutput: 'hello world',
          deliverable: _deliverable('hello world'),
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

  test('auto speech uses latest turn deliverable before stale notes',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
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
          deliverable: _deliverable('GET /stats/{code} 已经实现了，3 个相关测试全部通过。'),
        ),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.text, contains('GET /stats/{code}'));
  });

  test('auto speech does not fallback to stale previous turn summary',
      () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [
        _turnWithInput(1, '输出旧结果').copyWith(
          cleanedOutput: 'Turn 1 result',
          rawOutput: 'Turn 1 result',
        ),
      ],
    );
    final current = previous.copyWith(
      turns: [
        ...previous.turns,
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: '',
          rawOutput: '',
          clearDeliverable: true,
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

  test('auto speech does not fallback to a new task summary', () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [_turnWithInput(1, '输出旧结果')],
    );
    final current = previous.copyWith(
      turns: [
        ...previous.turns,
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: '',
          rawOutput: '',
          clearDeliverable: true,
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

  test('auto speech uses persisted deliverable speech summary', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      turns: [
        _turnWithInput(1, '输出 hello'),
        _turnWithInput(2, '继续').copyWith(
          cleanedOutput: 'hello world',
          rawOutput: 'hello world',
          deliverable: _deliverable(
            '页面展示文本 hello world',
            speech: '语音文本 hello world',
          ),
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

  test('auto speech hash is stable when only evidence fingerprint changes',
      () async {
    final previous = _task(status: TaskStatus.running);
    final first = previous.copyWith(
      turns: [
        _turnWithInput(1, '输出项目名').copyWith(
          deliverable: const TurnDeliverable(
            displaySummary: 'countdown_widgets',
            speechSummary: 'countdown_widgets',
            evidenceFingerprint: 'pane-a',
          ),
        ),
      ],
    );
    final second = first.copyWith(
      turns: [
        first.turns.single.copyWith(
          deliverable: const TurnDeliverable(
            displaySummary: 'countdown_widgets',
            speechSummary: 'countdown_widgets',
            evidenceFingerprint: 'pane-b',
          ),
        ),
      ],
    );

    final firstDecision = await policy.decide(
      previous: previous,
      current: first,
      settings: settings,
    );
    final secondDecision = await policy.decide(
      previous: first,
      current: second,
      settings: settings,
    );

    expect(firstDecision.shouldSpeak, isTrue);
    expect(secondDecision.shouldSpeak, isTrue);
    expect(secondDecision.hash, firstDecision.hash);
  });

  test('auto speech reads all displayed card text without compacting',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      turns: [
        _turnWithInput(1, '生成长结果').copyWith(
          cleanedOutput: 'long result',
          rawOutput: 'long result',
          deliverable: _deliverable(
            '第一段说明当前任务已经完成并保留了关键背景。第二段说明验证步骤已经执行并且结果正常。第三段说明后续建议是观察真实设备上的语音播报完整性。',
          ),
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

  test('turn idle with prompt echo only stays silent', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      turns: [
        _turnWithInput(1, '输出 hello world').copyWith(
          rawOutput: '',
          cleanedOutput: '',
          clearDeliverable: true,
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

  test('need approval task speaks confirmation prompt without command detail',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      nativeApproval: _approval('删除临时构建产物，风险中等。'),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      currentStatus: TaskStatus.needApproval,
      settings: settings,
      approval: current.nativeApproval,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('need approval on a later turn does not speak previous turn result',
      () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      nativeApproval:
          _approval('Turn 2 needs permission to inspect build output.'),
      turns: [
        _turnWithInput(1, '输出旧结果').copyWith(
          rawOutput: 'Turn 1 old result',
          cleanedOutput: 'Turn 1 old result',
        ),
        _turnWithInput(2, '继续检查').copyWith(
          rawOutput: '',
          cleanedOutput: '',
          clearDeliverable: true,
        ),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      currentStatus: TaskStatus.needApproval,
      settings: settings,
      approval: current.nativeApproval,
    );

    expect(decision.shouldSpeak, isTrue);
  });

  test('need approval speech can be disabled separately', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith(
      nativeApproval: _approval('请确认删除临时文件。'),
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
      turns: [
        _turn(1).copyWith(deliverable: _deliverable('已完成')),
      ],
    );
    final attention = previous.copyWith();

    expect(
      (await policy.decide(
        previous: previous,
        current: completed,
        currentStatus: TaskStatus.completed,
        settings: const TaskSpeechSettings(speakResults: false),
      ))
          .shouldSpeak,
      isFalse,
    );
    expect(
      (await policy.decide(
        previous: previous,
        current: attention,
        currentStatus: TaskStatus.needAttention,
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
      turns: [
        _turnWithInput(1, '初始任务').copyWith(
          rawOutput: '旧结果',
          cleanedOutput: '旧结果',
        ),
        _turnWithInput(2, '继续').copyWith(
          rawOutput: '',
          cleanedOutput: '',
          status: NativeOutputTurnStatus.needAttention,
          clearDeliverable: true,
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
      nativeApproval: _approval('Apply this change?'),
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      currentStatus: TaskStatus.needAttention,
      settings: settings,
      approval: current.nativeApproval,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.text, contains('Apply this change?'));
    expect(decision.text, isNot(contains('旧摘要')));
  });

  test('runtime lost with deliverable still speaks latest result', () async {
    final previous = _task(status: TaskStatus.running);
    final current = _task(status: TaskStatus.runtimeLost).copyWith(
      turns: [
        _turn(1).copyWith(
          status: NativeOutputTurnStatus.runtimeLost,
          deliverable: _deliverable('ARMIN_LOOP_LONG_D1 status=PASS'),
        ),
      ],
    );

    final decision = await policy.decide(
      previous: previous,
      current: current,
      currentStatus: TaskStatus.runtimeLost,
      settings: settings,
    );

    expect(decision.shouldSpeak, isTrue);
    expect(decision.text, contains('ARMIN_LOOP_LONG_D1'));
  });

  test('stale text in a new turn is not replayed as latest speech', () async {
    final previous = _task(status: TaskStatus.turnIdle).copyWith(
      turns: [_turn(1)],
    );
    final current = previous.copyWith(
      turns: [
        _turn(1),
        _turn(2).copyWith(
          rawOutput: '',
          cleanedOutput: '',
          clearDeliverable: true,
        ),
      ],
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
    expect(second.shouldSpeak, isFalse);
  });

  test('speech policy ignores task summary without turn evidence', () async {
    final previous = _task(status: TaskStatus.running);
    final current = previous.copyWith();
    final decision = await policy.decide(
      previous: previous,
      current: current,
      settings: settings,
    );

    expect(decision.shouldSpeak, isFalse);
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
  );
}

NativeTerminalApproval _approval(String question) {
  return NativeTerminalApproval(
    id: 'approval-1',
    taskId: 'task-1',
    question: question,
    options: const [
      NativeApprovalOption(key: '1', label: 'Allow once'),
      NativeApprovalOption(key: '2', label: 'Reject'),
    ],
    state: ApprovalState.pending,
    createdAt: DateTime(2026, 5, 24),
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
    deliverable: _deliverable('hello'),
  );
}

NativeOutputTurn _turnWithInput(int index, String input) {
  final turn = _turn(index);
  return turn.copyWith(userInput: input);
}

TurnDeliverable _deliverable(String display, {String? speech}) {
  return TurnDeliverable(
    displaySummary: display,
    speechSummary: speech ?? display,
    evidenceFingerprint: display.hashCode.toString(),
  );
}
