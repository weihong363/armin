import '../models/normalization_result.dart';
import 'terminology_dictionary.dart';

/// 开发者上下文信息，用于提升归一化质量
class DeveloperContext {
  const DeveloperContext({
    this.projectName,
    this.taskTitle,
    this.recentInstructions = const [],
    this.terminologyDictionary,
  });

  /// 当前项目名称
  final String? projectName;

  /// 当前任务标题
  final String? taskTitle;

  /// 最近的指令历史
  final List<String> recentInstructions;

  /// 自定义术语词典（可运行时扩展）
  final TerminologyDictionary? terminologyDictionary;

  /// 获取合并后的术语词典
  TerminologyDictionary get effectiveDictionary =>
      terminologyDictionary ?? TerminologyDictionary.defaultDictionary();
}

/// 语音转录归一化器
///
/// 位于 ASR 之后、任务提交之前。
/// 职责：
/// 1. ASR 错误修正（音近词 → 正确术语）
/// 2. 技术词汇恢复
/// 3. 指令归一化（模糊指令 → 清晰指令）
/// 4. 置信度估算
///
/// 当前实现为纯规则引擎。
/// SLM 接口已预留，可在未来替换为模型调用。
class TranscriptNormalizer {
  const TranscriptNormalizer();

  /// 归一化语音转录文本
  ///
  /// [rawText] 为 ASR 原始输出。
  /// [context] 为可选的开发者上下文。
  /// 返回 [NormalizationResult] 包含修正后的文本和置信度。
  NormalizationResult normalize(
    String rawText, {
    DeveloperContext? context,
  }) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return NormalizationResult.unchanged(trimmed);
    }

    final dictionary =
        context?.effectiveDictionary ?? TerminologyDictionary.defaultDictionary();
    final changes = <NormalizationChange>[];

    // ---- 阶段 1: 术语词典修正 ----
    var text = _applyDictionary(trimmed, dictionary, changes);

    // ---- 阶段 2: 格式清理 ----
    text = _cleanPunctuation(text);

    // ---- 阶段 3: 指令归一化 ----
    final expandedChanges = _normalizeInstruction(text, trimmed);
    if (expandedChanges != null) {
      text = expandedChanges.correctedText;
      changes.addAll(expandedChanges.changes);
    }

    // ---- 阶段 4: 置信度估算 ----
    final confidence = _estimateConfidence(trimmed, text, changes);
    final needsConfirmation = confidence < NormalizationResult.highConfidence;

    return NormalizationResult(
      correctedText: text,
      confidence: confidence,
      changes: changes,
      needsConfirmation: needsConfirmation,
    );
  }

  /// ---- 阶段 1: 术语词典修正 ----
  String _applyDictionary(
    String text,
    TerminologyDictionary dictionary,
    List<NormalizationChange> changes,
  ) {
    var result = text;
    final matches = dictionary.findMatches(result);

    for (final entry in matches) {
      for (final misspelling in entry.asrMisspellings) {
        final lowerResult = result.toLowerCase();
        final lowerMisspelling = misspelling.toLowerCase();
        final index = lowerResult.indexOf(lowerMisspelling);
        if (index >= 0) {
          final original = result.substring(index, index + misspelling.length);
          // 仅当原始文本与正确术语不同时才记录变更
          if (original.toLowerCase() != entry.correctTerm.toLowerCase()) {
            changes.add(
              NormalizationChange(
                original: original,
                corrected: entry.correctTerm,
                reason: '术语修正：$original → ${entry.correctTerm}'
                    '${entry.description.isNotEmpty ? '（${entry.description}）' : ''}',
                isDictionaryMatch: true,
              ),
            );
          }
          result = result.replaceRange(
            index,
            index + misspelling.length,
            entry.correctTerm,
          );
          break; // 每条术语只替换一处（贪心匹配第一个）
        }
      }
    }

    return result;
  }

  /// ---- 阶段 2: 标点与格式清理 ----
  String _cleanPunctuation(String text) {
    return text
        // 移除口语填充词
        .replaceAll(RegExp(r'[嗯啊呃额呐哪这个那个就是然后怎么说呢]+'), ' ')
        // 合并多余空格
        .replaceAll(RegExp(r'\s+'), ' ')
        // 中英文标点统一
        .replaceAll('?', '？')
        .replaceAll('!', '！')
        .trim();
  }

  /// ---- 阶段 3: 指令归一化 ----
  ///
  /// 将模糊的语音指令扩展为更清晰的形式。
  /// 注意：不改变用户意图，仅扩展表达。
  NormalizationResult? _normalizeInstruction(
    String text,
    String originalText,
  ) {
    final expanded = _tryExpandInstruction(text);
    if (expanded == null || expanded == text) {
      return null;
    }

    return NormalizationResult(
      correctedText: expanded,
      confidence: 0.85, // 指令扩展降低置信度
      changes: [
        NormalizationChange(
          original: originalText,
          corrected: expanded,
          reason: '指令归一化',
          isDictionaryMatch: false,
        ),
      ],
      needsConfirmation: false,
    );
  }

  /// 尝试将模糊指令扩展为更清晰的形式
  String? _tryExpandInstruction(String text) {
    final lower = text.toLowerCase().trim();

    // 模式 1: "输出这个项目" / "看看这个项目"
    if (_matchPattern(lower, const ['输出这个项目', '看看这个项目', '看一下这个项目', '分析这个项目'])) {
      return '请分析当前项目结构并输出项目概览';
    }
    if (_matchPattern(lower, const ['输出项目', '看项目', '看下项目'])) {
      return '请分析当前项目结构并输出项目概览';
    }

    // 模式 2: "看看登录模块" / "检查登录"
    if (_matchPattern(
      lower,
      const ['看看登录模块', '看登录模块', '检查登录', '看下登录', '看登录'],
    )) {
      return '请检查登录模块并总结其主要逻辑';
    }
    if (_matchPattern(
      lower,
      const [
        '看看登录',
        '看登录',
        '登录模块',
        '检查登录模块',
        '看下登录模块',
      ],
    )) {
      return '请检查登录模块并总结其主要逻辑';
    }

    // 通用模式: "看看 + [模块名]"
    final lookAtMatch =
        RegExp(r'^(看看|看下|看一下|看)\s*(.+)').firstMatch(text);
    if (lookAtMatch != null && lookAtMatch.group(2) != null) {
      final target = lookAtMatch.group(2)!.trim();
      if (target.length >= 2 && target.length <= 20) {
        return '请检查$target 并总结其核心逻辑';
      }
    }

    // 模式 3: "修一下" / "修复bug"
    if (_matchPattern(lower, const ['修一下', '修复一下', '修bug', '修复bug'])) {
      return '请检查当前问题并尝试修复';
    }
    final fixMatch =
        RegExp(r'^(修一下|修复一下|修|修复)\s*(.+)').firstMatch(text);
    if (fixMatch != null && fixMatch.group(2) != null) {
      final target = fixMatch.group(2)!.trim();
      if (target.length >= 2) {
        return '请修复$target';
      }
    }

    // 模式 4: "生成总结"
    if (_matchPattern(
      lower,
      const ['生成总结', '生成一份总结', '做总结', '写总结', '总结一下'],
    )) {
      return '请生成一份项目总结';
    }
    if (_matchPattern(
      lower,
      const ['生成项目总结', '写项目总结', '做项目总结'],
    )) {
      return '请生成一份项目总结，包括项目结构、核心模块和主要功能';
    }

    // 模式 5: "检查代码"
    if (_matchPattern(lower, const ['检查代码', '检查下代码', '审查代码'])) {
      return '请审查当前代码变更并指出潜在问题';
    }

    // 模式 6: "添加测试"
    if (_matchPattern(lower, const ['添加测试', '写测试', '加上测试', '加测试'])) {
      return '请为当前模块编写单元测试';
    }

    // 模式 7: "运行测试"
    if (_matchPattern(lower, const ['运行测试', '跑测试', '跑下测试', '执行测试'])) {
      return '请运行相关测试并报告结果';
    }

    // 模式 8: "提交"
    if (_matchPattern(lower, const ['提交', 'commit', '提交代码', 'commit代码'])) {
      return '请审查变更并准备提交信息';
    }

    return null; // 无法识别，保持原样
  }

  bool _matchPattern(String text, List<String> patterns) {
    final lower = text.toLowerCase().trim();
    return patterns.any(
      (pattern) => lower == pattern.toLowerCase(),
    );
  }

  /// ---- 阶段 4: 置信度估算 ----
  double _estimateConfidence(
    String original,
    String corrected,
    List<NormalizationChange> changes,
  ) {
    if (changes.isEmpty) {
      return 1.0; // 无变更，完全置信
    }

    // 仅词典修正的置信度
    final onlyDictionary =
        changes.every((item) => item.isDictionaryMatch);
    if (onlyDictionary && changes.length <= 2) {
      return 0.95; // 少量词典修正，高置信
    }
    if (onlyDictionary) {
      return 0.88; // 多项词典修正，略低
    }

    // 包含指令扩展
    final hasExpansion =
        changes.any((item) => !item.isDictionaryMatch);
    final editDistance = _relativeEditDistance(original, corrected);

    if (hasExpansion && editDistance < 0.3) {
      return 0.85; // 轻度扩展
    }
    if (hasExpansion && editDistance < 0.6) {
      return 0.75; // 中度扩展
    }
    if (hasExpansion) {
      return 0.65; // 重度扩展，低置信
    }

    return 0.92; // 兜底高置信
  }

  /// 相对编辑距离（归一化到 0~1）
  double _relativeEditDistance(String a, String b) {
    if (a.isEmpty && b.isEmpty) {
      return 0.0;
    }
    if (a.isEmpty || b.isEmpty) {
      return 1.0;
    }

    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));

    for (var i = 0; i <= m; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= n; j++) {
      dp[0][j] = j;
    }

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
    }

    return dp[m][n] / (m > n ? m : n);
  }

  /// 仅执行词典修正（不扩展指令），用于需要保留原始语意的场景
  NormalizationResult correctOnly(
    String rawText, {
    DeveloperContext? context,
  }) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return NormalizationResult.unchanged(trimmed);
    }

    final dictionary =
        context?.effectiveDictionary ?? TerminologyDictionary.defaultDictionary();
    final changes = <NormalizationChange>[];
    final text = _applyDictionary(trimmed, dictionary, changes);

    if (changes.isEmpty) {
      return NormalizationResult.unchanged(text);
    }

    return NormalizationResult(
      correctedText: text,
      confidence: 0.95,
      changes: changes,
      needsConfirmation: false,
    );
  }
}
