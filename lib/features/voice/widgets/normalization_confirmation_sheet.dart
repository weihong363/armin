import 'package:flutter/material.dart';

import '../../../shared/theme/armin_theme.dart';
import '../models/normalization_result.dart';

/// 归一化确认 Bottom Sheet
///
/// 基于置信度展示不同级别的确认界面：
/// - 高置信度 (>=0.9)：不展示，静默使用
/// - 中等置信度 (0.7-0.9)：轻量确认 "我理解为：..."
/// - 低置信度 (<0.7)："我不太确定..." + 编辑/重新说/确认
class NormalizationConfirmationSheet extends StatelessWidget {
  const NormalizationConfirmationSheet({
    required this.result,
    required this.onConfirm,
    required this.onEdit,
    required this.onRetry,
    required this.onCancel,
    super.key,
  });

  final NormalizationResult result;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  static Future<void> show(
    BuildContext context, {
    required NormalizationResult result,
    required VoidCallback onConfirm,
    required VoidCallback onEdit,
    required VoidCallback onRetry,
    required VoidCallback onCancel,
  }) {
    final isLowConfidence = result.confidence < NormalizationResult.mediumConfidence;

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      enableDrag: isLowConfidence, // 低置信度允许拖拽关闭
      isDismissible: isLowConfidence,
      builder: (_) => NormalizationConfirmationSheet(
        result: result,
        onConfirm: onConfirm,
        onEdit: onEdit,
        onRetry: onRetry,
        onCancel: onCancel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLowConfidence = result.confidence < NormalizationResult.mediumConfidence;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 标题 ----
            Text(
              isLowConfidence ? '我不太确定你的意思：' : '我理解为：',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),

            // ---- 修正后的文本 ----
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ArminTheme.mint,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: ArminTheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                result.correctedText,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),

            // ---- 变更详情（如有） ----
            if (result.changes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ChangeDetails(changes: result.changes),
            ],

            const SizedBox(height: 20),

            // ---- 操作按钮 ----
            if (isLowConfidence)
              _buildLowConfidenceActions(context)
            else
              _buildMediumConfidenceActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildMediumConfidenceActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              onEdit();
            },
            child: const Text('编辑'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onConfirm();
            },
            icon: const Icon(Icons.send_outlined, size: 18),
            label: const Text('确认发送'),
          ),
        ),
      ],
    );
  }

  Widget _buildLowConfidenceActions(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onEdit();
                },
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('编辑'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onRetry();
                },
                icon: const Icon(Icons.mic_outlined, size: 18),
                label: const Text('重新说'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onConfirm();
            },
            icon: const Icon(Icons.send_outlined, size: 18),
            label: const Text('确认发送'),
          ),
        ),
      ],
    );
  }
}

/// 变更详情组件
class _ChangeDetails extends StatelessWidget {
  const _ChangeDetails({required this.changes});

  final List<NormalizationChange> changes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '修正明细：',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.54),
                ),
          ),
          const SizedBox(height: 6),
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    change.isDictionaryMatch
                        ? Icons.spellcheck_outlined
                        : Icons.auto_fix_high_outlined,
                    size: 15,
                    color: change.isDictionaryMatch
                        ? ArminTheme.primary
                        : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      change.reason,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: ArminTheme.ink.withValues(alpha: 0.62),
                          ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
