enum LoopRuntimeOutcomeState { done, continueWork, blocked }

class LoopRuntimeOutcome {
  const LoopRuntimeOutcome({
    required this.state,
    required this.nextAction,
  });

  final LoopRuntimeOutcomeState state;
  final String nextAction;
}

class LoopRuntimeProtocol {
  const LoopRuntimeProtocol._();

  static const autoActionId = 'continue_protocol';
  static const _begin = 'ARMIN_LOOP_OUTCOME_BEGIN';
  static const _end = 'ARMIN_LOOP_OUTCOME_END';

  static const promptContract = '''
## Armin Loop Runtime Protocol
持续自主完成当前任务；不要把中间步骤交回给用户。仅当任务完成、确实需要继续执行，或遇到无法自主解决的阻塞时，才在最终输出末尾附上：
$_begin
state=DONE | CONTINUE | BLOCKED
next_action=下一步具体动作；DONE 或 BLOCKED 时填 NONE
acceptance=PASS | FAIL | UNKNOWN
$_end

state=DONE 表示当前用户目标已经完成，必须停止追加工作；CONTINUE 只用于仍有明确、必要且可自主执行的下一步；BLOCKED 只用于需要外部信息、审批或无法恢复的错误。不要仅因结果简短而使用 CONTINUE。''';

  static LoopRuntimeOutcome? parse(String value) {
    final begin = value.lastIndexOf(_begin);
    if (begin < 0) {
      return null;
    }
    final end = value.indexOf(_end, begin);
    if (end < 0) {
      return null;
    }
    final block = value.substring(begin, end + _end.length);
    final stateMatch = RegExp(
      r'^\s*state\s*[:=]\s*(DONE|CONTINUE|BLOCKED)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(block);
    if (stateMatch == null) {
      return null;
    }
    final nextMatch = RegExp(
      r'^\s*next_action\s*[:=]\s*(.+?)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(block);
    final state = switch (stateMatch.group(1)!.toUpperCase()) {
      'DONE' => LoopRuntimeOutcomeState.done,
      'CONTINUE' => LoopRuntimeOutcomeState.continueWork,
      _ => LoopRuntimeOutcomeState.blocked,
    };
    return LoopRuntimeOutcome(
      state: state,
      nextAction: nextMatch?.group(1)?.trim() ?? '',
    );
  }

  static bool isNoAction(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isEmpty || normalized == 'none' || normalized == '无';
  }

  static String strip(String value) {
    final begin = value.lastIndexOf(_begin);
    if (begin < 0) {
      return value.trim();
    }
    final end = value.indexOf(_end, begin);
    if (end < 0) {
      return value.trim();
    }
    return '${value.substring(0, begin)}${value.substring(end + _end.length)}'
        .trim();
  }
}
