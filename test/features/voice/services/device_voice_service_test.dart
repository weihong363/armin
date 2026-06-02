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

  test('speech summary splits English words inside Chinese output', () {
    final segments = DeviceVoiceService.buildSpeechSegmentsForTest(
      '已找到 PET 和 SUMMER，输出 hello world。',
    );

    expect(
      segments.map((segment) => segment.languageCode),
      containsAllInOrder(['zh-CN', 'en-US', 'zh-CN', 'en-US']),
    );
    expect(
      segments.where((segment) => segment.languageCode == 'en-US').map(
            (segment) => segment.text,
          ),
      containsAll(['PET', 'SUMMER', 'hello world']),
    );
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

  test('speech summary removes unnatural spaces around Chinese text', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest(
      'TARO 是 一 只 小型 疲惫 兔子 开发者 桌面 宠物 ， 192 × 208 像素 格。',
    );

    expect(cleaned, 'TARO是一只小型疲惫兔子开发者桌面宠物，192 × 208像素格。');
  });

  test('speech summary adds a pronunciation hint for 一行', () {
    final cleaned = DeviceVoiceService.cleanSpeechTextForTest('输出一行代码');

    expect(cleaned, contains('一行（háng）'));
  });

  test('speech profile is slightly faster and steady', () {
    final zhProfile = DeviceVoiceService.speechProfileForTest('zh-CN');
    final enProfile = DeviceVoiceService.speechProfileForTest('en-US');

    expect(zhProfile.speechRate, inInclusiveRange(0.70, 0.74));
    expect(zhProfile.pitch, inInclusiveRange(1.03, 1.08));
    expect(enProfile.speechRate, inInclusiveRange(0.58, 0.62));
    expect(enProfile.pitch, inInclusiveRange(0.98, 1.02));
  });

  test('english segment profile reads a little slower for accuracy', () {
    final zhProfile =
        DeviceVoiceService.speechProfileForLanguageForTest('zh-CN');
    final enProfile =
        DeviceVoiceService.speechProfileForLanguageForTest('en-US');

    expect(enProfile.speechRate, lessThan(zhProfile.speechRate));
    expect(enProfile.pitch, lessThanOrEqualTo(zhProfile.pitch));
  });

  test('speech summary compacts long noisy output into readable summary', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
Armin context governance:
- Only inspect files directly related to the task.
Search pet/Pet/Pets/assets in .
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:41 AM.
我已经找到主要问题，需要稍后重试。
这是一段很长的说明，用来模拟输出结果特别长的时候，语音不应该把所有日志、命令、路径和代码细节都完整读出来，而是应该保留最核心的信息。
''');

    expect(cleaned, contains('额度已用完，请稍后重试。'));
    expect(cleaned, isNot(contains('结果较长')));
    expect(cleaned, isNot(contains('详情页')));
    expect(cleaned, isNot(contains('Search pet')));
    expect(cleaned, isNot(contains('jq -r')));
    expect(cleaned.length, lessThan(230));
  });

  test('speech summary skips real agent terminal noise', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
│ >_ OpenAI Codex (v0.130.0)
Tip: Try the Codex App. Run `codex app`
⚠ Skipped loading 1 skill(s) due to invalid SKILL.md files.
/Users/ironion/.codex/skills/work-decision-guard/SKILL.md: invalid YAML:
mapping values are not allowed in this context at line 2 column 152
Use /skills to list available skills
Armin context governance:
- Keep command output short.
Explored
Search pet/Pet/Pets/assets in .
List hatch-pet
Ran jq -r '.pet_id' output/hatch-pet/*/pet_request.json
已找到 SUMMER。
hello world
''');

    expect(cleaned, contains('已找到SUMMER。'));
    expect(cleaned, contains('hello world'));
    expect(cleaned, isNot(contains('OpenAI Codex')));
    expect(cleaned, isNot(contains('SKILL.md')));
    expect(cleaned, isNot(contains('Use /skills')));
    expect(cleaned, isNot(contains('Search pet')));
    expect(cleaned, isNot(contains('Ran jq')));
  });

  test('speech summary strips qoder input chrome after the result', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
Turn 6
hello Type your message or @path/to/file Auto Model .ctx █ 10% · ~/workspace/momo
Shift+Tab to Auto-accept Edits
AGENTS.md file · 12 skills
''');

    expect(cleaned, 'hello');
    expect(cleaned, isNot(contains('Type your message or @path/to/file')));
    expect(cleaned, isNot(contains('Auto Model')));
  });

  test('speech text keeps all readable lines without compacting', () {
    final cleaned = DeviceVoiceService.cleanSpeechTextForTest('''
completion: tls handshake eof
runbook-copilot 是面向工程团队的 RAG 事故排障助手，用于根据告警、服务名、日志和症状检索知识库并生成带引用的排障建议。
可以继续查看引用和日志。
''');

    expect(cleaned, isNot(contains('tls handshake eof')));
    expect(cleaned, contains('runbook-copilot'));
    expect(cleaned, contains('可以继续查看引用和日志'));
  });

  test('long speech text is chunked before sending to TTS', () {
    final longResult = List.filled(
      4,
      '本轮结果会展示完整卡片内容用于朗读，不能因为文本较长就提前结束或丢失后半段内容',
    ).join();
    final segments = DeviceVoiceService.buildSpeechSegmentsForTest(longResult);

    expect(segments.length, greaterThan(1));
    expect(segments.every((segment) => segment.text.length <= 90), isTrue);
    expect(segments.map((segment) => segment.text).join(), contains('后半段内容'));
  });

  test('speech timeout scales for full result card text', () {
    final longResult = List.filled(
      4,
      '本轮结果会展示完整卡片内容用于朗读，不能因为文本较长就提前结束或丢失后半段内容',
    ).join();
    final timeout = DeviceVoiceService.speakTimeoutForTest(longResult);

    expect(timeout, greaterThan(const Duration(seconds: 18)));
  });

  test('speech summary keeps result text mixed with tool traces', () {
    final cleaned = DeviceVoiceService.cleanSpeechSummaryForTest('''
> ■ Glob('.hatch-pet-runs/taro/**/*.json') ■ Read(/Users/ironion/workspace/momo/output/hatch-pet/taro/pet_request.json) ■ TARO 是一只小型疲惫兔子开发者桌面宠物，灰奶油色调像素风格，9 行精灵图。
''');

    expect(cleaned, contains('TARO是一只小型疲惫兔子开发者桌面宠物'));
    expect(cleaned, isNot(contains('Glob')));
    expect(cleaned, isNot(contains('Read')));
    expect(cleaned, isNot(contains('/Users')));
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

  test('preferred voice favors English clear voices', () {
    final voice = DeviceVoiceService.preferredVoiceForTest(
      const [
        {'name': 'Default Voice', 'locale': 'en-US', 'gender': 'male'},
        {'name': 'Samantha Enhanced', 'locale': 'en_US', 'gender': 'female'},
      ],
      'en-US',
    );

    expect(voice?['name'], 'Samantha Enhanced');
  });
}
