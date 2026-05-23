import 'package:armin/features/voice/services/device_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speech summary skips code and command details', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
已修复登录按钮无法点击的问题。

```dart
final enabled = state.isReady;
return Button(onPressed: enabled ? submit : null);
```

flutter test test/login_test.dart
/Users/ironion/workspace/armin/lib/login.dart
Explored
Search pet.json in .
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
可以重新打开页面验证。
''');

    expect(cleaned, contains('已修复登录按钮无法点击的问题。'));
    expect(cleaned, contains('可以重新打开页面验证。'));
    expect(cleaned, isNot(contains('final enabled')));
    expect(cleaned, isNot(contains('flutter test')));
    expect(cleaned, isNot(contains('/Users/ironion')));
    expect(cleaned, isNot(contains('Explored')));
    expect(cleaned, isNot(contains('Search pet')));
    expect(cleaned, isNot(contains('Ran jq')));
  });

  test('speech summary uses English voice for English output', () {
    final segments = DeviceVoiceService.buildSpeechSegmentsForTest('hello');

    expect(segments, hasLength(1));
    expect(segments.single.text, 'hello');
    expect(segments.single.languageCode, 'en-US');
  });

  test('speech summary keeps Chinese voice for Chinese output', () {
    final segments = DeviceVoiceService.buildSpeechSegmentsForTest('已完成，可以验证。');

    expect(segments, hasLength(1));
    expect(segments.single.languageCode, 'zh-CN');
  });

  test('speech summary joins short lines into natural expression', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
已完成修复
可以重新验证
''');

    expect(cleaned, '已完成修复。可以重新验证');
  });

  test('speech profile is slightly faster and steady', () {
    final zhProfile = DeviceVoiceService.speechProfileForTest('zh-CN');
    final enProfile = DeviceVoiceService.speechProfileForTest('en-US');

    expect(zhProfile.speechRate, inInclusiveRange(0.62, 0.68));
    expect(zhProfile.pitch, inInclusiveRange(1.03, 1.08));
    expect(enProfile.speechRate, greaterThan(0.55));
    expect(enProfile.pitch, greaterThan(1.0));
  });

  test('fast female style increases speech pace', () {
    final base = DeviceVoiceService.speechProfileForTest('zh-CN');
    final fast = base.forStyle(SpeechVoiceStyle.fastFemale);

    expect(fast.speechRate, greaterThan(base.speechRate));
    expect(fast.pitch, greaterThan(base.pitch));
  });

  test('preferred voice favors Chinese female clear voices', () {
    final voice = DeviceVoiceService.preferredVoiceForTest(
      const [
        {'name': 'System Male', 'locale': 'zh-CN', 'gender': 'male'},
        {'name': 'XiaoXiao Neural', 'locale': 'zh_CN', 'gender': 'female'},
      ],
      'zh-CN',
    );

    expect(voice?['name'], 'XiaoXiao Neural');
  });
}
