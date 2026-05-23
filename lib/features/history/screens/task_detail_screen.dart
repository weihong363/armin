import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/screens/task_draft_screen.dart';

enum _TaskDetailAction {
  rerun,
  forceStop,
  delete,
}

class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = _findTask(state.tasks);
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('任务详情'),
          actions: [
            PopupMenuButton<_TaskDetailAction>(
              onSelected: (action) async {
                switch (action) {
                  case _TaskDetailAction.rerun:
                    _rerunTask(context, task);
                  case _TaskDetailAction.forceStop:
                    await _forceStopTask(context, task);
                  case _TaskDetailAction.delete:
                    _confirmDelete(context, task);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _TaskDetailAction.rerun,
                  child: Text('重新执行'),
                ),
                PopupMenuItem(
                  value: _TaskDetailAction.forceStop,
                  enabled: _canForceStop(task),
                  child: const Text('强制停止'),
                ),
                PopupMenuItem(
                  value: _TaskDetailAction.delete,
                  enabled: _canDelete(task),
                  child: const Text('删除任务'),
                ),
              ],
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

  TaskSession? _findTask(List<TaskSession> tasks) {
    for (final task in tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  void _rerunTask(BuildContext context, TaskSession task) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(initialTaskText: task.userText),
      ),
    );
  }

  Future<void> _forceStopTask(BuildContext context, TaskSession task) async {
    try {
      await AppStateScope.of(context).stopTask(task);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('强制停止失败：$error')),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    TaskSession task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除任务?'),
          content: Text(task.title),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && context.mounted) {
      try {
        await AppStateScope.of(context).deleteTask(task.id);
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$error')),
        );
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  bool _canDelete(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed;
  }

  bool _canForceStop(TaskSession task) {
    return task.status == TaskStatus.running ||
        task.status == TaskStatus.paused ||
        task.status == TaskStatus.needApproval ||
        task.status == TaskStatus.turnIdle ||
        task.status == TaskStatus.needAttention ||
        task.status == TaskStatus.observerDetached ||
        task.status == TaskStatus.pending;
  }
}

class _SummaryBanner extends StatefulWidget {
  const _SummaryBanner({required this.task});

  final TaskSession task;

  @override
  State<_SummaryBanner> createState() => _SummaryBannerState();
}

class _SummaryBannerState extends State<_SummaryBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _SummaryBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.completedAt != widget.task.completedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_isLiveTask(widget.task)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
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
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
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

  bool _isLiveTask(TaskSession task) {
    return task.completedAt == null &&
        (task.status == TaskStatus.running ||
            task.status == TaskStatus.pending ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.needApproval ||
            task.status == TaskStatus.turnIdle ||
            task.status == TaskStatus.needAttention ||
            task.status == TaskStatus.observerDetached);
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
        title: _timelineResultTitle(task.status),
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
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
      children: [
        _InfoCard(
          title: '输出',
          child: SelectableText(result?.summary ?? '暂无结果'),
        ),
        _InfoCard(
          title: '执行详情',
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('展开非输出内容'),
            children: [
              _DetailList(
                title: '变更文件',
                values: result?.changedFiles ?? const [],
              ),
              _DetailList(
                title: '验证结果',
                values: result?.validation ?? const [],
              ),
              _DetailList(
                title: '潜在风险',
                values: result?.risks ?? const [],
              ),
              _DetailList(
                title: '下一步',
                values: result?.nextActions ?? const [],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailList extends StatelessWidget {
  const _DetailList({required this.title, required this.values});

  final String title;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _BulletList(values: values.isEmpty ? const ['无'] : values),
          ],
        ),
      ),
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
                    icon: Icons.check_circle_outline,
                    label: '标记完成',
                    tone: ControlTone.neutral,
                    onPressed: controlState == RuntimeControlState.stopped ||
                            controlState == RuntimeControlState.detached
                        ? null
                        : () async {
                            await _runControlAction(
                              context,
                              () => AppStateScope.of(context)
                                  .markTaskCompleted(task),
                            );
                          },
                  ),
                  _ControlButton(
                    icon: Icons.report_gmailerrorred_outlined,
                    label: '标记失败',
                    tone: ControlTone.danger,
                    onPressed: controlState == RuntimeControlState.stopped
                        ? null
                        : () async {
                            await _runControlAction(
                              context,
                              () => AppStateScope.of(context)
                                  .markTaskFailed(task),
                            );
                          },
                  ),
                  _ControlButton(
                    icon: controlState == RuntimeControlState.paused
                        ? Icons.play_arrow_outlined
                        : Icons.pause_outlined,
                    label: controlState == RuntimeControlState.paused
                        ? '恢复'
                        : '暂停',
                    tone: ControlTone.neutral,
                    onPressed: controlState == RuntimeControlState.stopped ||
                            controlState == RuntimeControlState.detached
                        ? null
                        : () async {
                            await _runControlAction(
                              context,
                              () => controlState == RuntimeControlState.paused
                                  ? AppStateScope.of(context).resumeTask(task)
                                  : AppStateScope.of(context).pauseTask(task),
                            );
                          },
                  ),
                  _ControlButton(
                    icon: Icons.stop_rounded,
                    label: '停止',
                    tone: ControlTone.danger,
                    onPressed: controlState == RuntimeControlState.stopped
                        ? null
                        : () async {
                            await _runControlAction(
                              context,
                              () => AppStateScope.of(context).stopTask(task),
                            );
                          },
                  ),
                  _ControlButton(
                    icon: Icons.sensors_outlined,
                    label: '重新监听',
                    tone: ControlTone.neutral,
                    onPressed: controlState == RuntimeControlState.detached
                        ? () async {
                            await _runControlAction(
                              context,
                              () =>
                                  AppStateScope.of(context).reconnectTask(task),
                            );
                          }
                        : null,
                  ),
                  _ControlButton(
                    icon: Icons.link_off_outlined,
                    label: '断开监听',
                    tone: ControlTone.danger,
                    onPressed: controlState == RuntimeControlState.stopped ||
                            controlState == RuntimeControlState.detached
                        ? null
                        : () async {
                            await _runControlAction(
                              context,
                              () => AppStateScope.of(context)
                                  .disconnectTask(task),
                            );
                          },
                  ),
                  _ControlButton(
                    icon: Icons.description_outlined,
                    label: '查看日志',
                    tone: ControlTone.neutral,
                    onPressed: () => _showRawLogDialog(context, task),
                  ),
                ],
              ),
            ],
          ),
        ),
        _InfoCard(
          title: '电脑端调试',
          child: SelectableText(
            'tmux attach -t ${task.host.tmuxSessionName}\n'
            'tmux capture-pane -p -t ${task.host.tmuxSessionName} -S -200',
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
                            if (_isPendingApproval(approval.status))
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.of(context)
                                              .resolveApproval(task,
                                                  approved: true);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已允许，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.check_outlined),
                                    label: const Text('允许'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.of(context)
                                              .resolveApproval(task,
                                                  approved: false);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已拒绝，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.close_outlined),
                                    label: const Text('拒绝'),
                                  ),
                                ],
                              )
                            else
                              _MiniBadge(
                                label: _approvalStatusLabel(approval.status),
                                color: _approvalStatusColor(approval.status),
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
      TaskStatus.runtimeLost ||
      TaskStatus.userCompleted ||
      TaskStatus.userFailed ||
      TaskStatus.completed ||
      TaskStatus.failed =>
        RuntimeControlState.stopped,
      TaskStatus.observerDetached => RuntimeControlState.detached,
      TaskStatus.draft ||
      TaskStatus.pending ||
      TaskStatus.running ||
      TaskStatus.needApproval ||
      TaskStatus.turnIdle ||
      TaskStatus.needAttention =>
        RuntimeControlState.active,
    };
  }

  bool _isPendingApproval(String status) {
    return status.trim().toLowerCase() == 'pending';
  }

  String _approvalStatusLabel(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => '已允许',
      'rejected' => '已拒绝',
      final value when value.isNotEmpty => value,
      _ => '已处理',
    };
  }

  Color _approvalStatusColor(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => Colors.green.shade700,
      'rejected' => Colors.red.shade700,
      _ => Colors.grey.shade700,
    };
  }

  Future<void> _runControlAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('运行控制失败：$error')),
      );
    }
  }

  void _showRawLogDialog(BuildContext context, TaskSession task) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Raw Log'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(_fallback(task.rawLog, '无')),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
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
                    hintText: '继续补充你的要求...',
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
                  label: const Text('发送追加指令'),
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
  detached,
  stopped,
}

extension RuntimeControlStateLabel on RuntimeControlState {
  String get label {
    return switch (this) {
      RuntimeControlState.active => '运行中',
      RuntimeControlState.paused => '已暂停',
      RuntimeControlState.detached => '已断开监听',
      RuntimeControlState.stopped => '已停止',
    };
  }

  Color get color {
    return switch (this) {
      RuntimeControlState.active => ArminTheme.primary,
      RuntimeControlState.paused => Colors.orange,
      RuntimeControlState.detached => Colors.blueGrey,
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
  if (task.status == TaskStatus.turnIdle) {
    return '等待继续';
  }
  if (task.status == TaskStatus.needAttention) {
    return '需处理';
  }
  if (task.status == TaskStatus.observerDetached) {
    return '监听已断开';
  }
  if (task.status == TaskStatus.paused) {
    return '已暂停';
  }
  if (task.status == TaskStatus.runtimeLost) {
    return task.completedAt == null
        ? '运行丢失'
        : '${_timeLabel(task.completedAt!)} 丢失';
  }
  if (task.status == TaskStatus.stopped) {
    return task.completedAt == null
        ? '已停止'
        : '${_timeLabel(task.completedAt!)} 停止';
  }
  if (task.completedAt == null) {
    return '进行中';
  }
  return '${_timeLabel(task.completedAt!)} 完成';
}

String _timelineResultTitle(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => '等待确认',
    TaskStatus.turnIdle => '等待用户继续',
    TaskStatus.needAttention => '需要处理',
    TaskStatus.observerDetached => '监听已断开',
    TaskStatus.runtimeLost => '运行时丢失',
    _ => '接收结果',
  };
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
    'turn_idle' => '等待继续',
    'need_attention' => '需要处理',
    'observer_detached' => '断开监听',
    'observer_reconnected' => '重新监听',
    'runtime_lost' => '运行丢失',
    'user_mark_completed' => '用户确认完成',
    'user_mark_failed' => '用户标记失败',
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
    'turn_idle' => Icons.pause_circle_outline,
    'need_attention' => Icons.priority_high_outlined,
    'observer_detached' => Icons.link_off_outlined,
    'observer_reconnected' => Icons.sensors_outlined,
    'runtime_lost' => Icons.signal_wifi_connected_no_internet_4_outlined,
    'user_mark_completed' => Icons.check_circle_outline,
    'user_mark_failed' => Icons.report_gmailerrorred_outlined,
    'task_completed' => Icons.check_circle_outline,
    _ => Icons.circle_outlined,
  };
}

Color _eventColor(String eventType) {
  return switch (eventType) {
    'approval_requested' => Colors.orange.shade800,
    'turn_idle' => Colors.teal.shade700,
    'need_attention' => Colors.orange.shade800,
    'observer_detached' => Colors.blueGrey.shade700,
    'observer_reconnected' => ArminTheme.primary,
    'runtime_lost' => Colors.red.shade800,
    'user_mark_completed' => Colors.green.shade700,
    'user_mark_failed' => Colors.red.shade700,
    'task_completed' => Colors.green.shade700,
    'agent_output' => Colors.blueGrey.shade700,
    _ => ArminTheme.primary,
  };
}
