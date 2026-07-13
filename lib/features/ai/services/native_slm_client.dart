import 'dart:async';

import 'package:flutter/services.dart';

import 'slm_client.dart';

class NativeSlmClient implements SlmClient {
  const NativeSlmClient({
    MethodChannel channel = const MethodChannel(_channelName),
    this.modelDistributionUrl = distributionUrl,
    this.modelDistributionSha256 = distributionSha256,
  }) : _channel = channel;

  static const _channelName = 'com.ironion.armin/native_slm';
  static const defaultModelPath = 'managed://default';
  static const distributionUrl = String.fromEnvironment('ARMIN_SLM_MODEL_URL');
  static const distributionSha256 =
      String.fromEnvironment('ARMIN_SLM_MODEL_SHA256');
  static const _platformTimeout = Duration(milliseconds: 500);

  final MethodChannel _channel;
  final String modelDistributionUrl;
  final String modelDistributionSha256;

  @override
  Future<SlmCapability> capability({String? modelPath}) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'capability',
        {'modelPath': modelPath ?? defaultModelPath},
      ).timeout(_platformTimeout);
      return _capabilityFromMap(result);
    } on TimeoutException {
      return SlmCapability(
        available: false,
        message: '端侧模型检测超时。',
        backend: 'llama.cpp',
        modelPath: modelPath ?? defaultModelPath,
      );
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

  Future<bool> deleteModel({String? modelPath}) async {
    return await _channel.invokeMethod<bool>(
          'deleteModel',
          {'modelPath': modelPath ?? defaultModelPath},
        ) ??
        false;
  }

  bool get canInstallManagedModel =>
      modelDistributionUrl.startsWith('https://') &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(modelDistributionSha256);

  Future<SlmCapability> installManagedModel() async {
    if (!canInstallManagedModel) {
      throw StateError('未配置可信模型地址或 SHA-256。');
    }
    final result = await _channel.invokeMapMethod<String, Object?>(
      'installModel',
      {
        'url': modelDistributionUrl,
        'sha256': modelDistributionSha256.toLowerCase(),
      },
    ).timeout(const Duration(minutes: 15));
    return _capabilityFromMap(result);
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
      modelSizeBytes: map['modelSizeBytes'] as int? ?? 0,
    );
  }
}
