import 'approval_request.dart';

class ApprovalParser {
  ApprovalRequest? parse(String output) {
    final startIndex = output.indexOf('NEED_APPROVAL_START');
    final endIndex = output.indexOf('NEED_APPROVAL_END');
    if (startIndex < 0 || endIndex < 0 || endIndex <= startIndex) {
      return null;
    }

    final block = output
        .substring(startIndex + 'NEED_APPROVAL_START'.length, endIndex)
        .trim();

    return ApprovalRequest(
      reason: _singleLine(block, 'reason') ?? '',
      command: _singleLine(block, 'command') ?? '',
      risk: _singleLine(block, 'risk') ?? 'medium',
    );
  }

  String? _singleLine(String block, String key) {
    final match = RegExp(
      '^${RegExp.escape(key)}:\\s*(.*)\$',
      multiLine: true,
    ).firstMatch(block);
    return match?.group(1)?.trim();
  }
}
