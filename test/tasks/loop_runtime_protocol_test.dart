import 'package:armin/features/tasks/services/loop_runtime_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses explicit continue outcome and next action', () {
    final outcome = LoopRuntimeProtocol.parse('''
已完成当前检查。
ARMIN_LOOP_OUTCOME_BEGIN
state=CONTINUE
next_action=运行最小测试并汇总结果
acceptance=UNKNOWN
ARMIN_LOOP_OUTCOME_END
''');

    expect(outcome?.state, LoopRuntimeOutcomeState.continueWork);
    expect(outcome?.nextAction, '运行最小测试并汇总结果');
  });

  test('does not parse an incomplete outcome block', () {
    expect(
      LoopRuntimeProtocol.parse('state=DONE\nnext_action=NONE'),
      isNull,
    );
  });
}
