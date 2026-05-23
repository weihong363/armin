import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import 'host_form_screen.dart';

class HostListScreen extends StatelessWidget {
  const HostListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('SSH Hosts')),
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
                await appState.deleteHost(host.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('主机已删除'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              }

              return shouldDelete;
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
                    '${host.tmuxSessionName}\n'
                    '${_passwordStatusText(host.password)}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => HostFormScreen(host: host),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Host'),
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
      return 'SSH password not set for this run';
    }
    return 'SSH password ready for this run';
  }
}
