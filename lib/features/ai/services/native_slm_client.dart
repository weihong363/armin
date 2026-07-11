import 'dart:async';

import 'package:flutter/services.dart';

import 'slm_client.dart';

class NativeSlmClient implements SlmClient {
  const NativeSlmClient({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'com.ironion.armin/native_slm';
  static const defaultModelPath = '/data/local/tmp/armin/slm/model.gguf';
  static const _platformTimeout = Duration(milliseconds: 500);

  final MethodChannel _channel;

  @override
  Future<SlmCapability> capability({String? modelPath}) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'capability',
        {'modelPath': modelPath ?? defaultModelPath},
      ).timeout(_platformTimeout);
      return _capabilityFromMap(result);
    } on PlatformException catch (error) {
      return SlmCapability(
        available: false,
        message: error.message ?? '端侧模型不可用。',
        backend: 'llama.cpp',
        modelPath: modelPath ?? defaultModelPath,
      );
    } on MissingPluginException {
      return SlmCapability(
        available: false,
        message: '当前平台未提供端侧模型运行时。',
        backend: 'llama.cpp',
        modelPath: modelPath ?? defaultModelPath,
      );
    }
  }

  @override
  Future<SlmGenerationResponse> generate(SlmGenerationRequest request) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'generate',
      {
        'prompt': request.prompt,
        'modelPath': request.modelPath ?? defaultModelPath,
        'maxTokens': request.maxTokens,
        'temperature': request.temperature,
        'allowUnsafeDecode': request.allowUnsafeDecode,
      },
    ).timeout(const Duration(seconds: 120));
    final text = result?['text'] as String? ?? '';
    return SlmGenerationResponse(
      text: text,
      backend: result?['backend'] as String? ?? 'llama.cpp',
      modelPath: result?['modelPath'] as String? ??
          request.modelPath ??
          defaultModelPath,
    );
  }

  SlmCapability _capabilityFromMap(Map<String, Object?>? map) {
    if (map == null) {
      return const SlmCapability(
        available: false,
        message: '端侧模型运行时没有返回状态。',
        backend: 'llama.cpp',
        modelPath: defaultModelPath,
      );
    }
    return SlmCapability(
      available: map['available'] == true,
      message: map['message'] as String? ?? '',
      backend: map['backend'] as String? ?? 'llama.cpp',
      modelPath: map['modelPath'] as String? ?? defaultModelPath,
    );
  }
}
