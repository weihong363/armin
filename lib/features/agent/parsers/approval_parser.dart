import 'approval_request.dart';

class ApprovalParser {
  ApprovalRequest? parse(String output) {
    final blocks = RegExp(
      r'NEED_APPROVAL_START([\s\S]*?)NEED_APPROVAL_END',
    ).allMatches(output).toList().reversed;

    for (final match in blocks) {
      final block = match.group(1)?.trim() ?? '';
      final reason = _singleLine(block, 'reason') ?? '';
      final command = _singleLine(block, 'command') ?? '';
      final risk = _singleLine(block, 'risk') ?? 'medium';
      if (!_isRealApproval(reason: reason, command: command, risk: risk)) {
        continue;
      }

      return ApprovalRequest(
        reason: reason,
        command: command,
        risk: risk,
      );
    }

    return null;
  }

  String? _singleLine(String block, String key) {
    final match = RegExp(
      '^${RegExp.escape(key)}:\\s*(.*)\$',
      multiLine: true,
    ).firstMatch(block);
    return match?.group(1)?.trim();
  }

  bool _isRealApproval({
    required String reason,
    required String command,
    required String risk,
  }) {
    final normalizedRisk = risk.trim().toLowerCase();
    return !_isPlaceholder(reason) &&
        !_isPlaceholder(command) &&
        const {'low', 'medium', 'high'}.contains(normalizedRisk);
  }

  bool _isPlaceholder(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ||
        trimmed == '...' ||
        trimmed == '<...>' ||
        trimmed.contains('|');
  }
}
