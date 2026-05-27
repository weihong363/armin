import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/tasks/services/secret_redactor.dart';

void main() {
  test('redacts token password private key and cookie values', () {
    final redacted = const SecretRedactor().redactInlineSecrets(
      'token=abc password=hunter2 private_key=key cookie=session secret=value api_key=api access_key=access',
    );

    expect(redacted, contains('token=[REDACTED]'));
    expect(redacted, contains('password=[REDACTED]'));
    expect(redacted, contains('private_key=[REDACTED]'));
    expect(redacted, contains('cookie=[REDACTED]'));
    expect(redacted, contains('secret=[REDACTED]'));
    expect(redacted, contains('api_key=[REDACTED]'));
    expect(redacted, contains('access_key=[REDACTED]'));
    expect(redacted, isNot(contains('hunter2')));
  });

  test('redacts private key blocks', () {
    final redacted = const SecretRedactor().redactInlineSecrets('''
-----BEGIN PRIVATE KEY-----
super-secret
-----END PRIVATE KEY-----
''');

    expect(redacted, contains('[REDACTED_PRIVATE_KEY]'));
    expect(redacted, isNot(contains('super-secret')));
  });
}
