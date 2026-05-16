import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../models/host_config.dart';

class HostFormScreen extends StatefulWidget {
  const HostFormScreen({this.host, super.key});

  final HostConfig? host;

  @override
  State<HostFormScreen> createState() => _HostFormScreenState();
}

class _HostFormScreenState extends State<HostFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _projectPathController;
  late final TextEditingController _tmuxController;
  late final TextEditingController _agentCommandController;
  late final TextEditingController _privateKeyPathController;
  HostAuthType _authType = HostAuthType.privateKey;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _nameController = TextEditingController(text: host?.name ?? '');
    _addressController = TextEditingController(text: host?.address ?? '');
    _portController = TextEditingController(text: '${host?.port ?? 22}');
    _usernameController = TextEditingController(text: host?.username ?? '');
    _projectPathController =
        TextEditingController(text: host?.projectPath ?? '');
    _tmuxController = TextEditingController(
      text: host?.tmuxSessionName ?? 'armin-codex',
    );
    _agentCommandController = TextEditingController(
      text: host?.agentCommand ?? 'codex',
    );
    _privateKeyPathController = TextEditingController(
      text: host?.privateKeyPath ?? '~/.ssh/id_ed25519',
    );
    _authType = host?.authType ?? HostAuthType.privateKey;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _projectPathController.dispose();
    _tmuxController.dispose();
    _agentCommandController.dispose();
    _privateKeyPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text(widget.host == null ? 'Add Host' : 'Edit Host')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_nameController, 'Host name'),
            _field(_addressController, 'Host / IP'),
            _field(_portController, 'Port', keyboardType: TextInputType.number),
            _field(_usernameController, 'Username'),
            DropdownButtonFormField<HostAuthType>(
              initialValue: _authType,
              decoration: const InputDecoration(labelText: 'Auth type'),
              items: const [
                DropdownMenuItem(
                  value: HostAuthType.password,
                  child: Text('Password'),
                ),
                DropdownMenuItem(
                  value: HostAuthType.privateKey,
                  child: Text('Private key'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _authType = value);
                }
              },
            ),
            const SizedBox(height: 12),
            _field(_projectPathController, 'Project path'),
            _field(_tmuxController, 'tmux session name'),
            _field(_agentCommandController, 'Agent command'),
            if (_authType == HostAuthType.privateKey)
              _field(_privateKeyPathController, 'Private key path'),
            const SizedBox(height: 12),
            Text(
              'Phase 2 persists host config and private key path only. Passwords and private key values are not written into normal task history.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save Host'),
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return '$label is required';
          }
          return null;
        },
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final now = DateTime.now();
    final existing = widget.host;
    final host = HostConfig(
      id: existing?.id ?? 'host-${now.microsecondsSinceEpoch}',
      name: _nameController.text.trim(),
      host: _addressController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 22,
      username: _usernameController.text.trim(),
      authType: _authType,
      projectPath: _projectPathController.text.trim(),
      tmuxSessionName: _tmuxController.text.trim(),
      agentCommand: _agentCommandController.text.trim(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      privateKeyPath: _privateKeyPathController.text.trim(),
    );

    await AppStateScope.of(context).saveHost(host);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}
