import 'package:armin/features/tasks/models/native_output_turn.dart';
import 'package:armin/features/tasks/services/turn_output_slicer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('splits cumulative turn snapshots into per-turn output', () {
    final now = DateTime(2026, 5, 31);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '列出所有宠物',
        rawOutput: '',
        cleanedOutput: '列出所有宠物\n实际宠物：momo、Summer。',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
      NativeOutputTurn(
        id: 'turn-2',
        taskId: 'task-1',
        turnIndex: 2,
        userInput: '继续输出 Summer',
        rawOutput: '',
        cleanedOutput: '''
列出所有宠物
实际宠物：momo、Summer。
继续输出 Summer
Summer：一位迷人的美国沙滩女孩 Codex 宠物。
''',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
      NativeOutputTurn(
        id: 'turn-3',
        taskId: 'task-1',
        turnIndex: 3,
        userInput: '补充尺寸',
        rawOutput: '',
        cleanedOutput: '''
列出所有宠物
实际宠物：momo、Summer。
继续输出 Summer
Summer：一位迷人的美国沙滩女孩 Codex 宠物。
补充尺寸
精灵图集尺寸为 1536×1872，192×208 像素格。
''',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];
    const slicer = TurnOutputSlicer();

    expect(slicer.outputForTurn(turns, 0), '实际宠物：momo、Summer。');
    expect(
      slicer.outputForTurn(turns, 1),
      'Summer：一位迷人的美国沙滩女孩 Codex 宠物。',
    );
    expect(
      slicer.outputForTurn(turns, 2),
      '精灵图集尺寸为 1536×1872，192×208 像素格。',
    );
  });

  test('returns empty output when latest cumulative snapshot has no new turn',
      () {
    final now = DateTime(2026, 5, 31);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '输出 hello',
        rawOutput: '',
        cleanedOutput: 'hello',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
      NativeOutputTurn(
        id: 'turn-2',
        taskId: 'task-1',
        turnIndex: 2,
        userInput: '继续',
        rawOutput: '',
        cleanedOutput: 'hello',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.running,
      ),
    ];

    expect(const TurnOutputSlicer().outputForTurn(turns, 1), isEmpty);
  });

  test('uses current prompt boundary when previous turn stores only summary',
      () {
    final now = DateTime(2026, 5, 31);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '输出 Taro',
        rawOutput: '',
        cleanedOutput: 'Taro 是一只小型宠物。',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
      NativeOutputTurn(
        id: 'turn-2',
        taskId: 'task-1',
        turnIndex: 2,
        userInput: '继续输出 Summer',
        rawOutput: '',
        cleanedOutput: '''
输出 Taro
Glob('output/hatch-pet/taro/**/*.json')
Read(/Users/ironion/workspace/momo/output/hatch-pet/taro/pet_request.json)
TARO 是 一 只 小型疲惫兔子开发者桌面宠物。
继续输出 Summer
Summer：海滩风格 Codex 宠物。
''',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];

    expect(
      const TurnOutputSlicer().outputForTurn(turns, 1),
      'Summer：海滩风格 Codex 宠物。',
    );
  });

  test('slices cumulative raw output per turn', () {
    final now = DateTime(2026, 5, 31);
    final turns = [
      NativeOutputTurn(
        id: 'turn-1',
        taskId: 'task-1',
        turnIndex: 1,
        userInput: '输出 Taro',
        rawOutput: '''
输出 Taro
Thinking
Taro 是一只小型疲惫兔子开发者桌面宠物。
''',
        cleanedOutput: 'Taro 是一只小型疲惫兔子开发者桌面宠物。',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
      NativeOutputTurn(
        id: 'turn-2',
        taskId: 'task-1',
        turnIndex: 2,
        userInput: '继续输出 Summer',
        rawOutput: '''
输出 Taro
Thinking
Taro 是一只小型疲惫兔子开发者桌面宠物。
继续输出 Summer
Thinking
Summer 是一个海滩风格 Codex 宠物。
''',
        cleanedOutput: 'Summer 是一个海滩风格 Codex 宠物。',
        startedAt: now,
        lastOutputAt: now,
        status: NativeOutputTurnStatus.turnIdle,
      ),
    ];

    expect(
      const TurnOutputSlicer().rawOutputForTurn(turns, 1),
      'Thinking\nSummer 是一个海滩风格 Codex 宠物。',
    );
  });
}
