import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../services/task_notification_service.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  Future<TaskNotificationPermission>? _status;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _status ??= _service.permissionStatus();
  }

  TaskNotificationService get _service =>
      AppStateScope.read(context).taskNotificationService;

  Future<void> _requestPermission() async {
    final status = await _service.requestPermission();
    if (!mounted) return;
    setState(() => _status = Future.value(status));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('任务通知')),
      body: FutureBuilder<TaskNotificationPermission>(
        future: _status,
        builder: (context, snapshot) {
          final status = snapshot.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_statusIcon(status)),
                title: const Text('系统通知权限'),
                subtitle: Text(_statusLabel(status)),
              ),
              const SizedBox(height: 12),
              const Text('审批、等待输入、结果可验收、连接丢失和任务终态会触发通知。相同事件不会重复通知。'),
              if (status == TaskNotificationPermission.denied) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey('request-notification-permission'),
                  onPressed: _requestPermission,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('开启任务通知'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

IconData _statusIcon(TaskNotificationPermission? status) => switch (status) {
      TaskNotificationPermission.granted => Icons.notifications_active_outlined,
      TaskNotificationPermission.denied => Icons.notifications_off_outlined,
      TaskNotificationPermission.unsupported => Icons.info_outline,
      null => Icons.hourglass_empty,
    };

String _statusLabel(TaskNotificationPermission? status) => switch (status) {
      TaskNotificationPermission.granted => '已开启',
      TaskNotificationPermission.denied => '未开启',
      TaskNotificationPermission.unsupported => '当前平台暂不支持',
      null => '正在检查',
    };
