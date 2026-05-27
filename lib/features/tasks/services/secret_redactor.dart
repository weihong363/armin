import '../models/secret_entry.dart';

class SecretRedactor {
  const SecretRedactor();

  static final RegExp sensitiveInlinePattern = RegExp(
    r'((token|password|private[_ -]?key|cookie|api[_ -]?key|access[_ -]?key|secret)\s*[:=]\s*)([^\s,;]+)',
    caseSensitive: false,
  );

  static final RegExp privateKeyBlockPattern = RegExp(
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    caseSensitive: false,
  );

  String redactInlineSecrets(String text) {
    final withoutPrivateKeys = text.replaceAll(
      privateKeyBlockPattern,
      '[REDACTED_PRIVATE_KEY]',
    );

    return withoutPrivateKeys.replaceAllMapped(
      sensitiveInlinePattern,
      (match) => '${match.group(1)}[REDACTED]',
    );
  }

  List<SecretRedactedRecord> toRecords(List<SecretEntry> secrets) {
    return secrets
        .where((secret) => secret.name.trim().isNotEmpty)
        .map((secret) => secret.toRedactedRecord())
        .toList(growable: false);
  }

  String placeholdersOnly(List<SecretEntry> secrets) {
    final records = toRecords(secrets);
    if (records.isEmpty) {
      return '- 无';
    }

    return records
        .map((record) => '- ${record.placeholder} (${record.usage})')
        .join('\n');
  }
}
