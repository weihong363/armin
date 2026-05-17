import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../tasks/models/task_session.dart';

class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = state.tasks.firstWhere((item) => item.id == taskId);

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('任务详情'),
          actions: [
            IconButton(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: () {},
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: _SummaryBanner(task: task),
            ),
            const SizedBox(height: 8),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: ArminTheme.ink,
              indicatorColor: ArminTheme.primary,
              tabs: [
                Tab(text: '时间线'),
                Tab(text: '结果'),
                Tab(text: 'Prompt'),
                Tab(text: '日志'),
                Tab(text: '指标'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _TimelinePanel(task: task),
                  _ResultPanel(task: task),
                  _PromptPanel(task: task),
                  _LogPanel(task: task),
                  _MetricsPanel(task: task),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F8F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDCECE6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusBadge(status: task.status),
                const Spacer(),
                Text(
                  _finishedLabel(task),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(task.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              task.shortSummary.isEmpty ? task.userText : task.shortSummary,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Text(
              '总耗时 ${_durationLabel(task)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final items = [
      _TimelineItem(
        icon: Icons.mic_none_outlined,
        time: _timeLabel(task.createdAt),
        title: '语音输入',
        subtitle: _fallback(task.rawSttText, '原始语音已转写'),
      ),
      _TimelineItem(
        icon: Icons.edit_outlined,
        time: _timeLabel(task.updatedAt),
        title: '任务确认',
        subtitle: '用户确认并发送任务',
      ),
      _TimelineItem(
        icon: Icons.send_outlined,
        time: _timeLabel(task.startedAt ?? task.createdAt),
        title: '发送到 Codex',
        subtitle: '通过 SSH/tmux 发送任务',
      ),
      _TimelineItem(
        icon: Icons.check_circle_outline,
        time:
            task.completedAt == null ? '--:--' : _timeLabel(task.completedAt!),
        title: task.status == TaskStatus.needApproval ? '等待确认' : '接收结果',
        subtitle: task.shortSummary.isEmpty ? '任务执行中' : task.shortSummary,
      ),
    ];

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => items[index],
    );
  }
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.icon,
    required this.time,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String time;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(time, style: Theme.of(context).textTheme.bodySmall),
        ),
        Icon(icon, size: 20, color: ArminTheme.ink),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final result = task.result;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '结果摘要',
          child: Text(result?.summary ?? '暂无结果'),
        ),
        _InfoCard(
          title: '变更文件 (${result?.changedFiles.length ?? 0})',
          child: _BulletList(values: result?.changedFiles ?? const []),
        ),
        _InfoCard(
          title: '验证结果',
          trailing: _MiniBadge(label: '通过', color: Colors.green.shade700),
          child: _BulletList(values: result?.validation ?? const []),
        ),
        _InfoCard(
          title: '潜在风险',
          trailing: _MiniBadge(label: '低', color: Colors.orange.shade800),
          child: _BulletList(values: result?.risks ?? const []),
        ),
      ],
    );
  }
}

class _PromptPanel extends StatelessWidget {
  const _PromptPanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '任务草稿',
          child: SelectableText(_fallback(task.cleanedDraft, '无')),
        ),
        _InfoCard(
          title: '用户确认文本',
          child: SelectableText(_fallback(task.userText, '无')),
        ),
        _InfoCard(
          title: '发送 Prompt',
          child: SelectableText(_fallback(task.finalPrompt, '无')),
        ),
        _InfoCard(
          title: 'Secret Redacted Records',
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
      ],
    );
  }
}

class _LogPanel extends StatefulWidget {
  const _LogPanel({required this.task});

  final TaskSession task;

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final controlState = _controlStateFromTask(task.status);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '运行控制',
          trailing: _MiniBadge(
            label: controlState.label,
            color: controlState.color,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '通过 SSH/tmux 控制远端 Codex 会话。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _ControlButton(
                    icon: Icons.add_comment_outlined,
                    label: '追加指令',
                    tone: ControlTone.neutral,
                    onPressed: controlState == RuntimeControlState.stopped
                        ? null
                        : () => _showFollowUpSheet(context),
                  ),
                  _ControlButton(
                    icon: controlState == RuntimeControlState.paused
                        ? Icons.play_arrow_outlined
                        : Icons.pause_outlined,
                    label: controlState == RuntimeControlState.paused
                        ? '恢复'
                        : '暂停',
                    tone: ControlTone.neutral,
                    onPressed: controlState == RuntimeControlState.stopped
                        ? null
                        : () async {
                            if (controlState == RuntimeControlState.paused) {
                              await AppStateScope.of(context).resumeTask(task);
                            } else {
                              await AppStateScope.of(context).pauseTask(task);
                            }
                          },
                  ),
                  _ControlButton(
                    icon: Icons.stop_rounded,
                    label: '停止',
                    tone: ControlTone.danger,
                    onPressed: controlState == RuntimeControlState.stopped
                        ? null
                        : () async {
                            await AppStateScope.of(context).stopTask(task);
                          },
                  ),
                  _ControlButton(
                    icon: Icons.description_outlined,
                    label: '查看日志',
                    tone: ControlTone.neutral,
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
        _InfoCard(
          title: 'Raw Log',
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('展开 terminal output'),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(_fallback(task.rawLog, '无')),
              ),
            ],
          ),
        ),
        _InfoCard(
          title: 'Approval Requests',
          child: task.approvalRequests.isEmpty && task.approval == null
              ? const Text('无')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final approval in task.approvalRequests.isEmpty
                        ? [task.approval!]
                        : task.approvalRequests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              'reason: ${approval.reason}\n'
                              'command: ${approval.command}\n'
                              'risk: ${approval.risk}\n'
                              'status: ${approval.status}',
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: () => AppStateScope.of(context)
                                      .resolveApproval(task, approved: true),
                                  icon: const Icon(Icons.check_outlined),
                                  label: const Text('允许'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => AppStateScope.of(context)
                                      .resolveApproval(task, approved: false),
                                  icon: const Icon(Icons.close_outlined),
                                  label: const Text('拒绝'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  RuntimeControlState _controlStateFromTask(TaskStatus status) {
    return switch (status) {
      TaskStatus.paused => RuntimeControlState.paused,
      TaskStatus.stopped ||
      TaskStatus.completed ||
      TaskStatus.failed => RuntimeControlState.stopped,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.running ||
      TaskStatus.needApproval => RuntimeControlState.active,
    };
  }

  void _showFollowUpSheet(BuildContext context) {
    final controller = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('追加指令', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: '例如：先别查接口，优先看前端事件绑定。',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    final instruction = controller.text.trim();
                    if (instruction.isNotEmpty) {
                      await AppStateScope.of(context)
                          .sendFollowUp(widget.task, instruction);
                    }
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('记录为 Phase 1 占位'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MetricsPanel extends StatelessWidget {
  const _MetricsPanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _MetricsSummary(task: task),
        _InfoCard(
          title: '指标时间线',
          child: task.metricEvents.isEmpty
              ? const Text('暂无 metrics events')
              : _MetricsTimeline(task: task),
        ),
      ],
    );
  }
}

class _MetricsSummary extends StatelessWidget {
  const _MetricsSummary({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final duration = task.completedAt?.difference(
      task.startedAt ?? task.createdAt,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: '事件',
                value: '${task.metricEvents.length}',
              ),
            ),
            Expanded(
              child: _MetricTile(
                label: '确认',
                value: '${task.approvalRequests.length}',
              ),
            ),
            Expanded(
              child: _MetricTile(
                label: '日志',
                value: '${task.rawLog.length}',
              ),
            ),
            Expanded(
              child: _MetricTile(
                label: '耗时',
                value: duration == null ? '--' : _shortDuration(duration),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: ArminTheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _MetricsTimeline extends StatelessWidget {
  const _MetricsTimeline({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < task.metricEvents.length; index++)
          _MetricTimelineRow(
            eventType: task.metricEvents[index].eventType,
            payloadJson: task.metricEvents[index].payloadJson,
            createdAt: task.metricEvents[index].createdAt,
            isFirst: index == 0,
            isLast: index == task.metricEvents.length - 1,
          ),
      ],
    );
  }
}

class _MetricTimelineRow extends StatelessWidget {
  const _MetricTimelineRow({
    required this.eventType,
    required this.payloadJson,
    required this.createdAt,
    required this.isFirst,
    required this.isLast,
  });

  final String eventType;
  final String payloadJson;
  final DateTime createdAt;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final color = _eventColor(eventType);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 46,
          child: Text(_timeLabel(createdAt),
              style: Theme.of(context).textTheme.bodySmall),
        ),
        Column(
          children: [
            if (!isFirst)
              Container(
                width: 2,
                height: 10,
                color: ArminTheme.border,
              ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(_eventIcon(eventType), color: color, size: 14),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 32,
                color: ArminTheme.border,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_eventLabel(eventType),
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                _MetricPayloadDisplay(payloadJson: payloadJson),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricPayloadDisplay extends StatelessWidget {
  const _MetricPayloadDisplay({required this.payloadJson});

  final String payloadJson;

  @override
  Widget build(BuildContext context) {
    final structured = _parsePayload(payloadJson);

    if (structured.isEmpty) {
      return Text('无数据', style: Theme.of(context).textTheme.bodySmall);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in structured.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.key}: ',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: ArminTheme.ink.withValues(alpha: 0.7),
                      ),
                ),
                Expanded(
                  child: Text(
                    _formatValue(entry.value),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Map<String, dynamic> _parsePayload(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  String _formatValue(dynamic value) {
    if (value == null) return '--';
    if (value is num) {
      if (value is int) return value.toString();
      return value.toStringAsFixed(2);
    }
    if (value is bool) return value ? '是' : '否';
    if (value is List) {
      if (value.isEmpty) return '无';
      return value.map((e) => e.toString()).join(', ');
    }
    return value.toString();
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Text('无');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('- $value'),
          ),
      ],
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(label, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}

enum RuntimeControlState {
  active,
  paused,
  stopped,
}

extension RuntimeControlStateLabel on RuntimeControlState {
  String get label {
    return switch (this) {
      RuntimeControlState.active => '运行中',
      RuntimeControlState.paused => '已暂停',
      RuntimeControlState.stopped => '已停止',
    };
  }

  Color get color {
    return switch (this) {
      RuntimeControlState.active => ArminTheme.primary,
      RuntimeControlState.paused => Colors.orange,
      RuntimeControlState.stopped => Colors.red,
    };
  }
}

enum ControlTone {
  neutral,
  danger,
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final ControlTone tone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = tone == ControlTone.danger ? Colors.red : ArminTheme.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.26)),
      ),
    );
  }
}

String _fallback(String value, String fallback) {
  return value.trim().isEmpty ? fallback : value;
}

String _timeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _finishedLabel(TaskSession task) {
  if (task.status == TaskStatus.paused) {
    return '已暂停';
  }
  if (task.status == TaskStatus.stopped) {
    return task.completedAt == null ? '已停止' : '${_timeLabel(task.completedAt!)} 停止';
  }
  if (task.completedAt == null) {
    return '进行中';
  }
  return '${_timeLabel(task.completedAt!)} 完成';
}

String _durationLabel(TaskSession task) {
  final startedAt = task.startedAt ?? task.createdAt;
  final endedAt = task.completedAt ?? DateTime.now();
  final duration = endedAt.difference(startedAt);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (minutes <= 0) {
    return '${duration.inSeconds}s';
  }
  return '${minutes}m ${seconds}s';
}

String _shortDuration(Duration duration) {
  if (duration.inMinutes <= 0) {
    return '${duration.inSeconds}s';
  }
  return '${duration.inMinutes}m';
}

String _eventLabel(String eventType) {
  return switch (eventType) {
    'task_created' => '任务创建',
    'task_started' => '任务开始',
    'agent_output' => '收到输出',
    'approval_requested' => '请求确认',
    'task_completed' => '任务完成',
    _ => eventType,
  };
}

IconData _eventIcon(String eventType) {
  return switch (eventType) {
    'task_created' => Icons.add_task_outlined,
    'task_started' => Icons.play_arrow_outlined,
    'agent_output' => Icons.terminal_outlined,
    'approval_requested' => Icons.verified_user_outlined,
    'task_completed' => Icons.check_circle_outline,
    _ => Icons.circle_outlined,
  };
}

Color _eventColor(String eventType) {
  return switch (eventType) {
    'approval_requested' => Colors.orange.shade800,
    'task_completed' => Colors.green.shade700,
    'agent_output' => Colors.blueGrey.shade700,
    _ => ArminTheme.primary,
  };
}
