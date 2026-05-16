import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/agent/parsers/approval_parser.dart';

void main() {
  test('parses NEED_APPROVAL block', () {
    final approval = ApprovalParser().parse('''
NEED_APPROVAL_START
reason: needs destructive command
command: rm -rf build
risk: high
NEED_APPROVAL_END
''');

    expect(approval, isNotNull);
    expect(approval!.reason, 'needs destructive command');
    expect(approval.command, 'rm -rf build');
    expect(approval.risk, 'high');
  });
}
