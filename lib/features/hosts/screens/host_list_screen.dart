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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final host in state.hosts)
            Card(
              child: ListTile(
                title: Text(host.name),
                subtitle: Text('${host.username}@${host.address}:${host.port}\n'
                    '${host.projectPath} · ${host.tmuxSessionName}'),
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
        ],
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
}
