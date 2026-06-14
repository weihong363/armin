import 'approval_request.dart';
import 'terminal_prompt_parser.dart';

/// Detects approval requests from CLI output by recognising interactive
/// terminal prompts and converting them to [ApprovalRequest].
///
/// Relies on [TerminalPromptParser] for structural detection of the
/// prompt block — no CLI-specific keywords or NEED_APPROVAL markers
/// are required.
class ApprovalParser {
  const ApprovalParser();

  ApprovalRequest? parse(String output) {
    final prompt = _promptParser.parse(output);
    if (prompt == null) return null;
    return ApprovalRequest(
      reason: prompt.question,
      command:
          prompt.command.trim().isEmpty ? 'plan_approval' : prompt.command,
      risk: 'medium',
    );
  }

  static const _promptParser = TerminalPromptParser();
}
