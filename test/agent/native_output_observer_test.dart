import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/agent/services/agent_runtime_adapter.dart';
import 'package:armin/features/agent/services/agent_runtime_config.dart';
import 'package:armin/features/agent/services/native_output_observer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default observer idle threshold uses shared runtime config', () {
    final observer = NativeOutputObserver();

    expect(observer.idleThreshold, AgentRuntimeConfig.turnIdleThreshold);
    expect(observer.reconnectThreshold, AgentRuntimeConfig.reconnectThreshold);
  });

  test('enters turn idle after semantic output is stable', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 2),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('hello', now: now);
    final snapshot = observer.observe(
      'hello',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('does not enter idle while Codex is working', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('Working...', now: now);
    final snapshot = observer.observe(
      'Working...',
      now: now.add(const Duration(seconds: 5)),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('does not settle yolo thinking spinner as turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ 测试文件已创建，运行 pytest。

▫ Bash(cd /Users/ironion/workspace/armin-test/file-renamer && python -m pytest test_renamer.py -v 2>&1)

⠸ Thinking... (esc to cancel, 1m 2s)
──────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, isNot(NativeOutputObserverState.turnIdle));
    expect(snapshot.turnIdle, isFalse);
  });

  test('qoder adapter ignores infinite spinner after final output', () {
    final observer = NativeOutputObserver(
      runtimeAdapter: const AgentRuntimeAdapter(AgentType.qoder),
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ ARMIN_REAL_SESSION_CHECK status=PASS project=countdown_widgets files_changed=0
  Result: ARMIN_REAL_SESSION_CHECK
  All checks passed.
 ⠴ Thinking... (esc to cancel)  Auto Model · ctx 25%
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 7, 6, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('qoder adapter settles completed checks before infinite spinner', () {
    final observer = NativeOutputObserver(
      runtimeAdapter: const AgentRuntimeAdapter(AgentType.qoder),
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ P26-B01-D1-AUTO
  Result: P26-B01-D1-AUTO
  All checks passed.
  Verification step 1: OK
 ⠴ Thinking... (esc to cancel)  Auto Model · ctx 25%
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 7, 10, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('codex adapter keeps active bash work running', () {
    final observer = NativeOutputObserver(
      runtimeAdapter: const AgentRuntimeAdapter(AgentType.codex),
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me run the requested command.

▫ Bash(sleep 180 && echo LONGTASK_DONE)

⠹ Thinking... (esc to cancel, 48s)
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 7, 6, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('credits exhausted after deliverable settles as turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ 12 个测试全部通过（含竞态检测）。代码无问题，可正常使用。

Credits exhausted. Use /usage for details or /upgrade for more.
⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isTrue);
  });

  test('qoder prompt echo and thinking chrome stay running without result', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
██████
██    ██  Not Login Please Auth
● Initializing... Prompts will be queued.

> Phase 2.7 real qodercli long task verification.
  Constraints:
  - Do not modify files.
  - Final answer must include the exact marker
  ARMIN_P27_REAL_TURN1_123.
  Final answer must include these sections:
  1. 项目定位
  2. 技术栈
  6. 下一步建议
Credits exhausted. Use /usage for details or /upgrade for more.
⠸ Thinking... (esc to cancel, 4s)
YOLO Shift+Tab to Auto Mode
Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 7, 2, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('settled final answer is not kept running by trailing thinking chrome',
      () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
Thinking
 │ File read successfully. No modifications needed.
 ▪ ARMIN_VERIFY_BEGIN case_id=P26-D2 status=PASS next_action=COMPLETE ARMIN_VERIFY_END

──────────────────────────────────────────────────────────────────────────
 Auto Model · ctx ░░░░░░░░░░ 0% · ~/workspace/armin
 ⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isTrue);
  });

  test('settled candidate stays running while recent tool work is visible', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me summarize the project information by exploring its structure and key files.

▪ Glob('**/*.{js,jsx,ts,tsx,css,html,json}')
  └ Found 1 matching file(s) (Ctrl+O to expand)

▪ Let me read the Qoder settings file to understand the project configuration.

▪ Read(/Users/.../settings.local.json)
  └ Read 8 lines

▪ Let me check the current directory structure and look for key project files.

▪ Bash(ls -la)
  └ total 16
    drwxr-xr-x  11 ironion  staff  352 Jun 20 23:21 .

▪ Let me examine the pubspec.yaml file to understand the project's Dart/Flutter configuration.

▪ Read(/Users/.../pubspec.yaml)
  └ Read 20 lines

▪ Let me check the lib directory structure to understand the project's source code organization.
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 27, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('settled final answer wins over earlier tool work in the same pane', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me summarize the project information by exploring its structure and key files.

▪ Glob('**/*.{js,jsx,ts,tsx,css,html,json}')
  └ Found 1 matching file(s) (Ctrl+O to expand)

▪ Read(/Users/.../pubspec.yaml)
  └ Read 20 lines

▪ P26-B02R-ACTIVE-FINAL
  Project inspection completed.
  Unique identifier: P26-B02R-ACTIVE-FINAL
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 27, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('planning bullet before tool execution is not a deliverable', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me help you create a project description for your coding practice
  (leetcode-style) project.

  First, I'll explore the current codebase to understand its structure and
  identify where to add the project description.

▪ Glob('**/*.{js,jsx,ts,tsx,md}')
  └ No files found

▪ The repository appears to be empty or contains only deleted files. Since
  there's no existing codebase structure to work with, I'll create a standard
  project description for a coding practice/leetcode-style project.

  Let me create a README.md file with a comprehensive project description:

⠸ Thinking... (esc to cancel, 20s)
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 28),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('real qoder mid-task output is not treated as turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
██████                            ╭─ What's new (v1.0.32) ────────────────╮
██    ██  Qoder CLI v1.0.32
████  ██  Not Login Please Auth
● Initializing... Prompts will be queued.

> Armin context governance (aggressive):
  LONG RUNNING TASK TEST CASE 4 P1. In the current countdown_widgets Flutter
  project create or complete a package of countdown widgets.

> The user sent a new message while you were working:
  IMPORTANT: After completing your current task, you MUST address the user's
  message above. Do not ignore it.

▪ Let me start by exploring the current Flutter project structure to understand
  what's already implemented for countdown widgets.

▪ Glob('**/*.dart')
  └ No files found

▪ Bash(ls -la)
  └ total 0

▪ Write(/Users/.../pubspec.yaml)
  └ Accepted pubspec.yaml (Ctrl+O to expand)

▪ Now I'll create the main library file that will export all the countdown
  widgets:

▪ Write(/Users/.../countdown_widgets.dart)
  └ Accepted countdown_widgets.dart (Ctrl+O to expand)

✓ Update successful! The new version will be used on your next run.
Credits exhausted. Use /usage for details or /upgrade for more.
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 30),
    );

    expect(snapshot.state, isNot(NativeOutputObserverState.turnIdle));
    expect(snapshot.turnIdle, isFalse);
  });

  test('qoder idle input prompt after unfinished work needs attention', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me read the pubspec.yaml file first to understand the project configuration.

▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines

▪ Let me check the lib/ directory structure to understand the key widgets.

▪ Glob('**/*' within lib/)
  └ Found 2 matching file(s) (Ctrl+O to expand)

▪ Let me check the src/ directory structure to find the actual widget files.

────────────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode                                  Try /model to switch models
*   Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 7, 7, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.needAttention);
    expect(snapshot.needsAttention, isTrue);
    expect(snapshot.turnIdle, isFalse);
  });

  test('real qoder thinking after interim summary stays running', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
██████                            ╭─ What's new (v1.0.33) ────────────────╮
██    ██  Not Login Please Auth
● Initializing... Prompts will be queued.

> Armin context governance (aggressive):
  LONGTASKA. Do not modify files. First run sleep 180. Then inspect
  pubspec.yaml lib and test.

▪ The current project is a countdown widgets application, but the user's task
  references Flutter files that are not immediately visible.

  Let me inspect the current directory structure and key files to provide an
  accurate project review.

▪ Bash(ls -la)
  └ total 8
    drwxr-xr-x   7 ironion  staff  224 Jun 30 00:00 .

▪ Glob('**/*.js')
  └ No files found

✓ Update successful! The new version will be used on your next run.
Credits exhausted. Use /usage for details or /upgrade for more.
⠹ Thinking... (esc to cancel, 30s)
YOLO Shift+Tab to Auto Mode
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 30, 22, 15),
    );

    expect(snapshot.state, NativeOutputObserverState.running);
    expect(snapshot.turnIdle, isFalse);
  });

  test('final created summary settles after earlier planning and tools', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me help you create a project description for your coding practice
  (leetcode-style) project.

▪ Glob('**/*.{js,jsx,ts,tsx,md}')
  └ No files found

▪ The repository appears to be empty or contains only deleted files. Since
  there's no existing codebase structure to work with, I'll create a standard
  project description for a coding practice/leetcode-style project.

▪ Write(/Users/.../README.md)
  └ Accepted README.md (Ctrl+O to expand)

▪ I've created a README.md file with a comprehensive project description for
  your coding practice project. The description includes:

  - Project overview and purpose
  - Key features like problem categorization, difficulty levels, and progress
    tracking
  - Technology stack information
  - Getting started instructions
  - Contribution guidelines

  Would you like me to make any specific modifications to the README content?
Credits exhausted. Use /usage for details or /upgrade for more.
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 6, 28),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('natural qoder final answer settles without a marker', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
▪ Let me check the project metadata.
▪ Read(/Users/.../pubspec.yaml)
  └ Read 21 lines
▪ The project is named countdown_widgets and its description is: "A package containing
  various countdown widgets for Flutter applications."

  This is a Flutter package that provides countdown-related UI widgets for Flutter
  applications.
Shift+Tab to Accept Edits      Try /effort or /context-window to adjust model settings
* Type your message or @path/to/file
Model · ctx ░░░░░░░░░░ 2% · ~/workspace/armin-test/countdown_widgets
''';

    final snapshot = observer.observeSettled(output);

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
    expect(observer.hasSettledTurnEvidence(snapshot.cleanedOutput), isTrue);
  });

  test('credits exhausted is not hidden by trailing yolo status chrome', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
Thinking
 │ Everything looks clean. FlipCountdown is fully removed.
 ▪ Done. FlipCountdown 已完全移除。当前 package 只包含：

   - CircularCountdown - 圆形进度环倒计时
   - LinearCountdown - 线性进度条倒计时

   请确认后我再继续下一步。
 Credits exhausted. Use /usage for details or /upgrade for more.

──────────────────────────────────────────────────────────────────────────
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isTrue);
  });

  test(
      'credits exhausted footer without deliverable does not require attention',
      () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    const output = '''
Credits exhausted. Use /usage for details or /upgrade for more.
⠸ Thinking... (esc to cancel, 1m 2s)
 YOLO Shift+Tab to Auto Mode
''';

    final snapshot = observer.observeSettled(
      output,
      now: DateTime(2026, 5, 23, 12),
    );

    expect(snapshot.state, NativeOutputObserverState.outputQuieting);
    expect(snapshot.needsAttention, isFalse);
    expect(snapshot.turnIdle, isFalse);
  });

  test('marks runtime lost after reconnect threshold', () {
    final observer = NativeOutputObserver(
      reconnectThreshold: const Duration(seconds: 2),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('Reconnecting...', now: now);
    final snapshot = observer.observe(
      'Reconnecting...',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(snapshot.state, NativeOutputObserverState.runtimeLost);
    expect(snapshot.runtimeLost, isTrue);
  });

  test('finished running tests does not block turn idle', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('I finished running tests.', now: now);
    final snapshot = observer.observe(
      'I finished running tests.',
      now: now.add(const Duration(seconds: 2)),
    );

    expect(snapshot.state, NativeOutputObserverState.turnIdle);
    expect(snapshot.turnIdle, isTrue);
  });

  test('only short status lines are active work signals', () {
    final observer = NativeOutputObserver(
      idleThreshold: const Duration(seconds: 1),
    );
    final now = DateTime(2026, 5, 23, 12);

    observer.observe('The task is running well after the fix.', now: now);
    final narrative = observer.observe(
      'The task is running well after the fix.',
      now: now.add(const Duration(seconds: 2)),
    );
    final active = observer.observe(
      'The task is running well after the fix.\nRunning...',
      now: now.add(const Duration(seconds: 3)),
    );

    expect(narrative.state, NativeOutputObserverState.turnIdle);
    expect(active.state, NativeOutputObserverState.running);
  });
}
