import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../shared/widgets/status_badge.dart';
import '../widgets/audit_section.dart';

class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = state.tasks.firstWhere((item) => item.id == taskId);

    return Scaffold(
      appBar: AppBar(title: const Text('Task Detail')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              StatusBadge(status: task.status),
            ],
          ),
          const SizedBox(height: 8),
          Text('${task.host.name} · ${task.host.projectPath}'),
          const SizedBox(height: 16),
          AuditSection(
            title: '1. 原始语音转写',
            child: SelectableText(_fallback(task.rawSttText)),
          ),
          AuditSection(
            title: '2. 规则整理后的任务草稿',
            child: SelectableText(_fallback(task.cleanedDraft)),
          ),
          AuditSection(
            title: '3. 用户编辑后的任务文本',
            child: SelectableText(_fallback(task.userText)),
          ),
          AuditSection(
            title: '4. 发送给 Codex 的最终 prompt',
            child: SelectableText(_fallback(task.finalPrompt)),
          ),
          AuditSection(
            title: '5. 敏感信息脱敏记录',
            child: task.secretRecords.isEmpty
                ? const Text('无')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final secret in task.secretRecords)
                        Text(
                          '${secret.name}: ${secret.redactedValue} · '
                          '${secret.usage} · ${secret.scope}',
                        ),
                    ],
                  ),
          ),
          AuditSection(
            title: '6. Codex 结构化结果',
            child: task.result == null
                ? const Text('暂无结果')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('status: ${task.result!.status}'),
                      Text('summary: ${task.result!.summary}'),
                      _list('changed_files', task.result!.changedFiles),
                      _list('validation', task.result!.validation),
                      _list('risks', task.result!.risks),
                      _list('next_actions', task.result!.nextActions),
                    ],
                  ),
          ),
          AuditSection(
            title: '7. Runtime controls',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('Add follow-up'),
                ),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.pause_outlined),
                  label: const Text('Pause'),
                ),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.stop_outlined),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ),
          AuditSection(
            title: '8. 原始日志',
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('展开 terminal output'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(_fallback(task.rawLog)),
                ),
              ],
            ),
          ),
          AuditSection(
            title: '9. Approval 记录',
            child: task.approvalRequests.isEmpty && task.approval == null
                ? const Text('无')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final approval in task.approvalRequests.isEmpty
                          ? [task.approval!]
                          : task.approvalRequests)
                        SelectableText(
                          'reason: ${approval.reason}\n'
                          'command: ${approval.command}\n'
                          'risk: ${approval.risk}\n'
                          'status: ${approval.status}',
                        ),
                    ],
                  ),
          ),
          AuditSection(
            title: '10. Metrics timeline',
            child: task.metricEvents.isEmpty
                ? const Text('暂无 metrics events')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final event in task.metricEvents)
                        Text(
                          '${event.createdAt.toIso8601String()} · '
                          '${event.eventType} · ${event.payloadJson}',
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _list(String title, List<String> values) {
    if (values.isEmpty) {
      return Text('$title: 无');
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title:'),
          for (final value in values) Text('- $value'),
        ],
      ),
    );
  }

  String _fallback(String value) {
    return value.trim().isEmpty ? '无' : value;
  }
}
