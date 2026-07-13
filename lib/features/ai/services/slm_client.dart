class SlmCapability {
  const SlmCapability({
    required this.available,
    required this.message,
    this.backend = 'unknown',
    this.modelPath,
    this.modelSizeBytes = 0,
  });

  final bool available;
  final String message;
  final String backend;
  final String? modelPath;
  final int modelSizeBytes;
}

class SlmGenerationRequest {
  const SlmGenerationRequest({
    required this.prompt,
    this.modelPath,
    this.maxTokens = 512,
    this.temperature = 0.2,
    this.allowUnsafeDecode = false,
  });

  final String prompt;
  final String? modelPath;
  final int maxTokens;
  final double temperature;
  final bool allowUnsafeDecode;
}

class SlmGenerationResponse {
  const SlmGenerationResponse({
    required this.text,
    this.backend = 'unknown',
    this.modelPath,
  });

  final String text;
  final String backend;
  final String? modelPath;
}

abstract class SlmClient {
  Future<SlmCapability> capability({String? modelPath});

  Future<SlmGenerationResponse> generate(SlmGenerationRequest request);
}
