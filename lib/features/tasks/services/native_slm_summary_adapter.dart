import '../../ai/services/native_slm_client.dart';
import '../../ai/services/slm_client.dart';
import 'output_summary_provider.dart';

class NativeSlmSummaryAdapter {
  const NativeSlmSummaryAdapter({
    SlmClient client = const NativeSlmClient(),
    this.maxPromptChars = 4000,
  }) : _client = client;

  final SlmClient _client;
  final int maxPromptChars;

  Future<bool> isAvailable() async {
    final capability = await _client.capability();
    return capability.available;
  }

  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final response = await _client.generate(
      SlmGenerationRequest(
        prompt: _promptFor(request),
        maxTokens: 512,
        temperature: 0.2,
      ),
    );
    final text = response.text.trim();
    return OutputSummary(
      displaySummary: text,
      speechSummary: text,
      importantLines: text.isEmpty ? const [] : text.split('\n'),
    );
  }

  String _promptFor(OutputSummaryRequest request) {
    final task = request.taskTitle.trim();
    final output = _truncate(request.cleanedOutput.trim(), maxPromptChars);
    return '''
你是 Armin 的端侧小模型摘要器。请只基于“任务输出”生成中文摘要。

要求：
- 不要补充未在输出中出现的事实。
- 不要复述用户 prompt。
- 不要输出 thinking、工具调用或终端 UI。
- 最多 5 行。

任务标题：
$task

任务输出：
$output
''';
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return value.substring(value.length - maxChars);
  }
}
