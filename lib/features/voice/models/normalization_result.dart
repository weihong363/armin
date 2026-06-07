/// 单个修正变更记录
class NormalizationChange {
  const NormalizationChange({
    required this.original,
    required this.corrected,
    required this.reason,
    this.isDictionaryMatch = false,
  });

  /// ASR 原始识别文本片段
  final String original;

  /// 修正后的文本
  final String corrected;

  /// 修正原因说明
  final String reason;

  /// 是否来自术语词典匹配
  final bool isDictionaryMatch;

  Map<String, Object?> toJson() {
    return {
      'original': original,
      'corrected': corrected,
      'reason': reason,
      'isDictionaryMatch': isDictionaryMatch,
    };
  }

  factory NormalizationChange.fromJson(Map<String, Object?> json) {
    return NormalizationChange(
      original: json['original'] as String? ?? '',
      corrected: json['corrected'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      isDictionaryMatch: json['isDictionaryMatch'] as bool? ?? false,
    );
  }
}

/// 语音转录归一化结果
class NormalizationResult {
  const NormalizationResult({
    required this.correctedText,
    required this.confidence,
    required this.changes,
    required this.needsConfirmation,
  });

  /// 修正后的完整文本
  final String correctedText;

  /// 置信度 0.0 ~ 1.0
  final double confidence;

  /// 所有修正变更
  final List<NormalizationChange> changes;

  /// 是否需要用户确认
  final bool needsConfirmation;

  /// 高置信度阈值：直接使用，无需确认
  static const double highConfidence = 0.9;

  /// 中等置信度阈值：轻量确认
  static const double mediumConfidence = 0.7;

  /// 没有任何修正的结果
  factory NormalizationResult.unchanged(String text) {
    return NormalizationResult(
      correctedText: text,
      confidence: 1.0,
      changes: const [],
      needsConfirmation: false,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'correctedText': correctedText,
      'confidence': confidence,
      'changes': changes.map((item) => item.toJson()).toList(),
      'needsConfirmation': needsConfirmation,
    };
  }

  factory NormalizationResult.fromJson(Map<String, Object?> json) {
    final changesRaw = json['changes'] as List<Object?>? ?? [];
    return NormalizationResult(
      correctedText: json['correctedText'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      changes: changesRaw
          .whereType<Map<String, Object?>>()
          .map(NormalizationChange.fromJson)
          .toList(),
      needsConfirmation: json['needsConfirmation'] as bool? ?? false,
    );
  }
}
