import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/services/armin_app_state.dart';
import '../models/host_config.dart';
import 'host_form_screen.dart';

enum _HostListAction {
  edit,
  duplicate,
}

class HostListScreen extends StatelessWidget {
  const HostListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('主机连接')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: state.hosts.length,
        itemBuilder: (context, index) {
          final host = state.hosts[index];
          return Dismissible(
            key: ValueKey(host.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(
                Icons.delete_outline,
                color: Colors.white,
              ),
            ),
            confirmDismiss: (direction) async {
              final shouldDelete = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除主机'),
                  content: Text('确定要删除主机 "${host.name}" 吗？此操作不可恢复。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );

              if (shouldDelete == true && context.mounted) {
                final appState = AppStateScope.of(context);
                try {
                  await appState.deleteHost(host.id);
                } on HostEditBlockedException catch (e) {
                  if (context.mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('无法删除主机'),
                        content: Text(e.message),
                        actions: [
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    );
                  }
                  return false;
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('主机已删除'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              }

              return shouldDelete == true;
            },
            onDismissed: (direction) {
              // Widget is already removed by confirmDismiss, nothing to do here
            },
            child: Card(
              child: ListTile(
                leading: host.isDefault
                    ? const Icon(Icons.star, color: Colors.amber)
                    : null,
                title: Row(
                  children: [
                    Expanded(child: Text(host.name)),
                    if (host.isDefault)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '默认',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.amber.shade900,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                subtitle: Text('${host.username}@${host.address}:${host.port}\n'
                    '${_passwordStatusText(host.password)}'),
                isThreeLine: false,
                trailing: PopupMenuButton<_HostListAction>(
                  tooltip: '主机操作',
                  onSelected: (action) {
                    switch (action) {
                      case _HostListAction.edit:
                        _openHostForm(context, host);
                      case _HostListAction.duplicate:
                        _openHostForm(context, host, duplicate: true);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _HostListAction.edit,
                      child: Text('编辑配置'),
                    ),
                    PopupMenuItem(
                      value: _HostListAction.duplicate,
                      child: Text('复制配置'),
                    ),
                  ],
                ),
                onTap: () {
                  _openHostForm(context, host);
                },
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('添加主机'),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const HostFormScreen(),
            ),
          );
        },
      ),
    );
  }

  String _passwordStatusText(String password) {
    if (password.trim().isEmpty) {
      return '未保存 SSH 密码';
    }
    return 'SSH 密码已安全保存';
  }

  void _openHostForm(
    BuildContext context,
    HostConfig host, {
    bool duplicate = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HostFormScreen(host: host, duplicate: duplicate),
      ),
    );
  }
}
