import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/agent/parsers/task_result_parser.dart';

void main() {
  test('parses TASK_RESULT block', () {
    final result = TaskResultParser().parse('''
noise
TASK_RESULT_START
status: success
summary: done
changed_files:
- lib/main.dart
validation:
- flutter test
risks:
- none
next_actions:
- ship
TASK_RESULT_END
''');

    expect(result, isNotNull);
    expect(result!.status, 'success');
    expect(result.summary, 'done');
    expect(result.changedFiles, ['lib/main.dart']);
    expect(result.validation, ['flutter test']);
    expect(result.risks, ['none']);
    expect(result.nextActions, ['ship']);
  });
}
