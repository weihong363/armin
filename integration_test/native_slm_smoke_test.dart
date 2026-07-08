import 'package:armin/features/ai/services/native_slm_client.dart';
import 'package:armin/features/ai/services/slm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native llama SLM generates text on device', (tester) async {
    const client = NativeSlmClient();
    final capability = await client.capability();

    expect(
      capability.available,
      isTrue,
      reason: capability.message,
    );

    final response = await client.generate(
      const SlmGenerationRequest(
        prompt: '''
<|im_start|>system
You are a strict copier. Output only the requested text.
<|im_end|>
<|im_start|>user
Output exactly: ARMIN_NATIVE_SLM_SMOKE status=PASS
<|im_end|>
<|im_start|>assistant
        ''',
        maxTokens: 32,
        temperature: 0,
        allowUnsafeDecode: true,
      ),
    );

    expect(response.text, contains('ARMIN_NATIVE_SLM_SMOKE'));
    expect(response.text, contains('PASS'));
  });
}
