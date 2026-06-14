import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/agent/parsers/approval_parser.dart';

void main() {
  test('detects approval from Codex allow-execution prompt', () {
    const output = '''
\x1B[33mAllow execution of [ls]? Redirection detected.\x1B[0m

> 1. Allow once
  2. Always allow this exact command for future sessions
  3. Reject and type something
  4. No
''';

    final approval = const ApprovalParser().parse(output);

    expect(approval, isNotNull);
    expect(approval!.reason, 'Allow execution of [ls]? Redirection detected.');
    expect(approval.command, 'ls');
    expect(approval.risk, 'medium');
  });

  test('detects approval from Qoder plan prompt', () {
    const output = '''
Qoder has written up a plan and is ready to execute. Would you like to proceed?

 \u276f 1. Yes, execute with Auto mode
   2. Yes, execute with YOLO mode
   3. Yes, continue with manual approval
   4. Yes, proceed to Goal execution
      Enter goal mode \u2014 autonomous execution with no interruptions.
   5. Refuse and say something
      Reject this plan and provide feedback to the model.
   6. Reject plan
      Reject this plan without providing feedback.
''';

    final approval = const ApprovalParser().parse(output);

    expect(approval, isNotNull);
    expect(approval!.reason,
        contains('Would you like to proceed?'));
    expect(approval.command, 'plan_approval');
    expect(approval.risk, 'medium');
  });

  test('returns null for non-interactive output', () {
    const output = 'Build succeeded. All tests passed.';

    final approval = const ApprovalParser().parse(output);

    expect(approval, isNull);
  });

  test('ignores plain numbered output without cursor prefix', () {
    const output = '''
Results:
1. test passed
2. analyze passed
3. build successful
''';

    final approval = const ApprovalParser().parse(output);

    expect(approval, isNull);
  });
}
