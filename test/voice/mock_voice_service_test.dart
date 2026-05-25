import '../features/voice/services/mock_voice_service.dart';
import 'package:armin/features/voice/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MockVoiceService supports start and stop flow', () async {
    final service = MockVoiceService(recognizedText: '修复登录失败');
    var partial = '';

    await service.startListening(onPartial: (value) => partial = value);
    final result = await service.stopListening();

    expect(service.isAvailable, isTrue);
    expect(partial, '修复登录失败');
    expect(result, '修复登录失败');
  });

  test('MockVoiceService fails fast when voice is unavailable', () async {
    final service = MockVoiceService(available: false);

    expect(service.isAvailable, isFalse);
    expect(
      () => service.startListening(),
      throwsA(isA<VoiceUnavailableException>()),
    );
  });
}
