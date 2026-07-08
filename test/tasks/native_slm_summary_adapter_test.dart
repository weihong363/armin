import 'package:armin/features/ai/services/slm_client.dart';
import 'package:armin/features/tasks/services/native_slm_summary_adapter.dart';
import 'package:armin/features/tasks/services/output_summary_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adapter summarizes with native SLM client', () async {
    const adapter = NativeSlmSummaryAdapter(
      client: _FakeSlmClient(
        slmCapability: SlmCapability(
          available: true,
          message: 'ready',
          backend: 'llama.cpp',
        ),
        response: SlmGenerationResponse(text: '本轮已完成验证。'),
      ),
    );

    final summary = await adapter.summarize(
      const OutputSummaryRequest(
        cleanedOutput: 'flutter test 全部通过。',
        taskTitle: '验证测试',
      ),
    );

    expect(await adapter.isAvailable(), isTrue);
    expect(summary.displaySummary, '本轮已完成验证。');
    expect(summary.speechSummary, '本轮已完成验证。');
  });

  test('local model provider falls back when native SLM is unavailable',
      () async {
    const adapter = NativeSlmSummaryAdapter(
      client: _FakeSlmClient(
        slmCapability: SlmCapability(
          available: false,
          message: 'missing model',
          backend: 'llama.cpp',
        ),
        response: SlmGenerationResponse(text: 'should not be used'),
      ),
    );
    final provider = LocalSmallModelSummaryProvider(
      runner: adapter.summarize,
      availabilityCheck: adapter.isAvailable,
    );

    final summary = await provider.summarize(
      const OutputSummaryRequest(
        cleanedOutput: '实际结果：已完成端侧模型探测。',
        taskTitle: '验证端侧模型',
      ),
    );

    expect(summary.displaySummary, '实际结果：已完成端侧模型探测。');
    expect(summary.fallbackReason, 'local small model not supported');
  });
}

class _FakeSlmClient implements SlmClient {
  const _FakeSlmClient({
    required this.slmCapability,
    required this.response,
  });

  final SlmCapability slmCapability;
  final SlmGenerationResponse response;

  @override
  Future<SlmCapability> capability({String? modelPath}) async => slmCapability;

  @override
  Future<SlmGenerationResponse> generate(SlmGenerationRequest request) async {
    expect(request.prompt, contains('任务输出'));
    return response;
  }
}
