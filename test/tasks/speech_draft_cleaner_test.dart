import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/tasks/services/speech_draft_cleaner.dart';

void main() {
  test('removes filler words but preserves uncertainty', () {
    final cleaned = SpeechDraftCleaner().clean(
      '嗯 就是 帮我看看这个问题，可能是缓存，好像也可能是接口，然后先别大改',
    );

    expect(cleaned, isNot(contains('嗯')));
    expect(cleaned, isNot(contains('就是')));
    expect(cleaned, isNot(contains('然后')));
    expect(cleaned, contains('可能'));
    expect(cleaned, contains('好像'));
  });
}
