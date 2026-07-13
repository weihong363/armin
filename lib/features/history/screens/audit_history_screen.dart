import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_state_scope.dart';
import '../../tasks/models/metric_event.dart';
import '../../tasks/models/task_session.dart';

class AuditHistoryScreen extends StatefulWidget {
  const AuditHistoryScreen({super.key});

  @override
  State<AuditHistoryScreen> createState() => _AuditHistoryScreenState();
}

class _AuditHistoryScreenState extends State<AuditHistoryScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = AppStateScope.of(context).tasks;
    final entries = _entries(tasks, query: _query);
    return Scaffold(
      appBar: AppBar(
        title: const Text('审计历史'),
        actions: [
          IconButton(
            key: const ValueKey('export-audit-history'),
            tooltip: '导出 JSON',
            onPressed: tasks.isEmpty ? null : () => _export(context, tasks),
            icon: const Icon(Icons.content_copy_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: SearchBar(
              controller: _searchController,
              hintText: '搜索任务、事件类型或结构化内容',
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('没有匹配的审计事件'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _AuditEventTile(entry: entries[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, List<TaskSession> tasks) async {
    final payload = const JsonEncoder.withIndent('  ').convert({
      'exportedAt': DateTime.now().toIso8601String(),
      'tasks': [
        for (final task in tasks)
          {
            'taskId': task.id,
            'title': task.displayTitle,
            'events': task.metricEvents.map((event) => event.toJson()).toList(),
          },
      ],
    });
    await Clipboard.setData(ClipboardData(text: payload));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('结构化审计历史已复制为 JSON')),
    );
  }
}

class _AuditEventTile extends StatelessWidget {
  const _AuditEventTile({required this.entry});

  final _AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(_eventLabel(entry.event.eventType)),
        subtitle:
            Text('${entry.taskTitle} · ${_timeLabel(entry.event.createdAt)}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(_prettyPayload(entry.event.payloadJson)),
        ],
      ),
    );
  }
}

class _AuditEntry {
  const _AuditEntry({required this.taskTitle, required this.event});

  final String taskTitle;
  final MetricEvent event;
}

List<_AuditEntry> _entries(List<TaskSession> tasks, {required String query}) {
  final normalized = query.toLowerCase();
  final entries = <_AuditEntry>[];
  for (final task in tasks) {
    for (final event in task.metricEvents) {
      final searchable =
          '${task.displayTitle} ${event.eventType} ${event.payloadJson}'
              .toLowerCase();
      if (normalized.isEmpty || searchable.contains(normalized)) {
        entries.add(_AuditEntry(taskTitle: task.displayTitle, event: event));
      }
    }
  }
  entries.sort((a, b) => b.event.createdAt.compareTo(a.event.createdAt));
  return entries;
}

String _eventLabel(String value) => switch (value) {
      'loop_evaluated' => 'Loop 评估',
      'loop_user_action' => '用户动作',
      'loop_approval_event' => '审批动作',
      'loop_auto_action' => 'Autopilot 动作',
      'loop_result_summary' => 'Loop 结果摘要',
      _ => value.replaceAll('_', ' '),
    };

String _prettyPayload(String source) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
  } catch (_) {
    return source;
  }
}

String _timeLabel(DateTime value) =>
    '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
