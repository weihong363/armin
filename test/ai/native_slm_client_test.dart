import 'package:armin/features/ai/services/native_slm_client.dart';
import 'package:armin/features/ai/services/slm_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ironion.armin/native_slm');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reports native llama capability from Android channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'capability');
      expect(call.arguments, {'modelPath': NativeSlmClient.defaultModelPath});
      return {
        'available': true,
        'message': 'ready',
        'backend': 'llama.cpp',
        'modelPath': '/data/local/tmp/armin/slm/model.gguf',
        'modelSizeBytes': 396361728,
      };
    });

    final capability = await const NativeSlmClient().capability();

    expect(capability.available, isTrue);
    expect(capability.message, 'ready');
    expect(capability.backend, 'llama.cpp');
    expect(capability.modelPath, '/data/local/tmp/armin/slm/model.gguf');
    expect(capability.modelSizeBytes, 396361728);
  });

  test('deletes only through the native model management channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'deleteModel');
      expect(call.arguments, {'modelPath': NativeSlmClient.defaultModelPath});
      return true;
    });

    expect(await const NativeSlmClient().deleteModel(), isTrue);
  });

  test('installs only a trusted HTTPS model with matching SHA configuration',
      () async {
    const checksum =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installModel');
      expect(call.arguments, {
        'url': 'https://models.example/armin.gguf',
        'sha256': checksum,
      });
      return {
        'available': true,
        'message': 'ready',
        'backend': 'llama.cpp',
        'modelPath': '/private/slm/model.gguf',
        'modelSizeBytes': 42,
      };
    });

    const client = NativeSlmClient(
      modelDistributionUrl: 'https://models.example/armin.gguf',
      modelDistributionSha256: checksum,
    );
    expect(client.canInstallManagedModel, isTrue);
    expect((await client.installManagedModel()).available, isTrue);
  });

  test('rejects incomplete model distribution config before native work',
      () async {
    const client = NativeSlmClient(
      modelDistributionUrl: 'http://models.example/armin.gguf',
      modelDistributionSha256: 'bad',
    );
    expect(client.canInstallManagedModel, isFalse);
    expect(client.installManagedModel, throwsStateError);
  });

  test('generates text through native llama channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'generate');
      expect(call.arguments, {
        'prompt': 'Summarize this result.',
        'modelPath': NativeSlmClient.defaultModelPath,
        'maxTokens': 128,
        'temperature': 0.1,
        'allowUnsafeDecode': false,
      });
      return {
        'text': '摘要完成。',
        'backend': 'llama.cpp',
        'modelPath': NativeSlmClient.defaultModelPath,
      };
    });

    final response = await const NativeSlmClient().generate(
      const SlmGenerationRequest(
        prompt: 'Summarize this result.',
        maxTokens: 128,
        temperature: 0.1,
      ),
    );

    expect(response.text, '摘要完成。');
    expect(response.backend, 'llama.cpp');
  });

  test('can explicitly opt into native llama decode', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'generate');
      expect((call.arguments as Map<Object?, Object?>)['allowUnsafeDecode'],
          isTrue);
      return {
        'text': 'ARMIN_NATIVE_SLM_SMOKE status=PASS',
        'backend': 'llama.cpp',
        'modelPath': NativeSlmClient.defaultModelPath,
      };
    });

    final response = await const NativeSlmClient().generate(
      const SlmGenerationRequest(
        prompt: 'smoke',
        allowUnsafeDecode: true,
      ),
    );

    expect(response.text, contains('ARMIN_NATIVE_SLM_SMOKE'));
  });

  test('missing plugin is reported as unavailable capability', () async {
    final capability = await const NativeSlmClient().capability();

    expect(capability.available, isFalse);
    expect(capability.message, contains('当前平台未提供端侧模型运行时'));
    expect(capability.backend, 'llama.cpp');
  });
}
