import 'package:armin/features/tasks/services/semantic_snippet_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const summer = 'Summer：一位迷人的美国沙滩女孩 Codex 宠物，棕发波浪、暖棕肤色、'
      '海军蓝比基尼、自信活力的 pin-up 风格，含 9 个动画状态'
      '（idle/running/waving/jumping/failed/waiting/review 等），'
      '1536×1872 精灵图集，192×208 像素格。';

  test('task description snippet keeps subject and tail facts', () {
    final snippet = const SemanticSnippetBuilder().build(
      summer,
      contentType: SnippetContentType.taskDescription,
      maxChars: 72,
    );

    expect(snippet.fullText, summer);
    expect(snippet.visibleText, contains('Summer'));
    expect(snippet.visibleText, contains('192×208'));
    expect(snippet.truncationMode, TruncationMode.headTail);
    expect(snippet.truncated, isTrue);
  });

  test('task description never uses tail-only truncation', () {
    final snippet = const SemanticSnippetBuilder().build(
      summer,
      contentType: SnippetContentType.taskDescription,
      maxChars: 72,
    );

    expect(snippet.truncationMode, isNot(TruncationMode.tail));
    expect(snippet.visibleText, isNot(startsWith('...个动画状态')));
  });

  test('execution log uses tail snippet', () {
    final snippet = const SemanticSnippetBuilder().build(
      'line 1\nline 2\nError: final failure reason',
      contentType: SnippetContentType.executionLog,
      maxChars: 30,
    );

    expect(snippet.truncationMode, TruncationMode.tail);
    expect(snippet.visibleText, startsWith('...'));
    expect(snippet.visibleText, contains('final failure reason'));
  });

  test('file path uses middle snippet', () {
    final snippet = const SemanticSnippetBuilder().build(
      '/Users/ironion/workspace/armin/lib/features/tasks/screens/task.dart',
      contentType: SnippetContentType.filePath,
      maxChars: 36,
    );

    expect(snippet.truncationMode, TruncationMode.middle);
    expect(snippet.visibleText, startsWith('/Users/ironion'));
    expect(snippet.visibleText, endsWith('screens/task.dart'));
  });

  test('session id uses middle snippet', () {
    final snippet = const SemanticSnippetBuilder().build(
      'armin-task-1779124728789142-long-runtime-session',
      contentType: SnippetContentType.sessionId,
      maxChars: 28,
    );

    expect(snippet.truncationMode, TruncationMode.middle);
    expect(snippet.visibleText, contains('...'));
    expect(
        snippet.fullText, 'armin-task-1779124728789142-long-runtime-session');
  });
}
