import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_state_scope.dart';
import '../../agent/services/agent_session_service.dart';
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
  late final List<TextEditingController> _ipControllers;
  late final List<FocusNode> _ipFocusNodes;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _tmuxController;
  late final TextEditingController _agentCommandController;
  bool _isTestingConnection = false;
  bool _setAsDefault = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _nameController = TextEditingController(text: host?.name ?? '');
    _ipControllers = _ipSegments(host?.address ?? '')
        .map((segment) => TextEditingController(text: segment))
        .toList(growable: false);
    _ipFocusNodes = List.generate(4, (_) => FocusNode(), growable: false);
    _portController = TextEditingController(text: '${host?.port ?? 22}');
    _usernameController = TextEditingController(text: host?.username ?? '');
    _passwordController = TextEditingController(text: host?.password ?? '');
    _tmuxController = TextEditingController(
      text: host?.tmuxSessionName ?? 'armin-codex',
    );
    _agentCommandController = TextEditingController(
      text: host?.agentCommand ?? 'codex',
    );
    // If editing existing host, use its isDefault; if creating new, default to true
    _setAsDefault = host?.isDefault ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final controller in _ipControllers) {
      controller.dispose();
    }
    for (final focusNode in _ipFocusNodes) {
      focusNode.dispose();
    }
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _tmuxController.dispose();
    _agentCommandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final hostCount = state.hosts.length;
    // If only one host (or creating the first), it's automatically default and cannot be changed
    final isSingleHost = hostCount <= 1;
    final canToggleDefault = !isSingleHost;
    
    return Scaffold(
      appBar:
          AppBar(title: Text(widget.host == null ? 'Add Host' : 'Edit Host')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_nameController, 'Host name'),
            Text('Host / IP', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            _IpAddressField(
              controllers: _ipControllers,
              focusNodes: _ipFocusNodes,
            ),
            const SizedBox(height: 12),
            _field(_portController, 'Port', keyboardType: TextInputType.number),
            _field(_usernameController, 'Username'),
            _field(
              _passwordController,
              'SSH password',
              obscureText: true,
            ),
            _field(_tmuxController, 'tmux session name'),
            _field(_agentCommandController, 'Agent command'),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('设为默认 Host'),
              subtitle: Text(
                isSingleHost
                    ? '唯一主机，自动设为默认'
                    : '新建任务时将自动使用此主机',
              ),
              value: _setAsDefault,
              onChanged: canToggleDefault
                  ? (value) {
                      setState(() {
                        _setAsDefault = value;
                      });
                    }
                  : null,
              secondary: Icon(
                isSingleHost ? Icons.star : Icons.star_outline,
                color: isSingleHost ? Colors.amber : null,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Phase 2 uses password auth first. Password is kept in memory only for this MVP. TODO: persist it with Android Keystore / EncryptedSharedPreferences.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: _isTestingConnection
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sensors_outlined),
              label: Text(_isTestingConnection
                  ? 'Testing SSH...'
                  : 'Test SSH Connection'),
              onPressed: _isTestingConnection ? null : _testConnection,
            ),
            const SizedBox(height: 12),
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
    bool obscureText = false,
    bool required = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          if (required && (value == null || value.trim().isEmpty)) {
            return '$label is required';
          }
          return null;
        },
      ),
    );
  }

  Future<void> _testConnection() async {
    final host = _ipAddress();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final port = int.tryParse(_portController.text.trim()) ?? 22;

    if (!_isValidIpAddress(host) ||
        username.isEmpty ||
        password.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Host, username, and SSH password are required.')),
      );
      return;
    }

    setState(() => _isTestingConnection = true);
    try {
      final result =
          await AppStateScope.of(context).agentSessionService.testConnection(
                AgentConnectionTestRequest(
                  host: host,
                  port: port,
                  username: username,
                  password: password,
                ),
              );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SSH connection failed: ${e.toString()}')),
      );
    } finally {
      if (mounted) {
        setState(() => _isTestingConnection = false);
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final ipAddress = _ipAddress();
    if (!_isValidIpAddress(ipAddress)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Valid host IP is required.')),
      );
      return;
    }

    final state = AppStateScope.of(context);
    final hostCount = state.hosts.length;
    // If only one host (or creating the first), force it to be default
    final isSingleHost = hostCount <= 1;
    final shouldBeDefault = isSingleHost ? true : _setAsDefault;

    final now = DateTime.now();
    final existing = widget.host;
    final host = HostConfig(
      id: existing?.id ?? 'host-${now.microsecondsSinceEpoch}',
      name: _nameController.text.trim(),
      host: ipAddress,
      port: int.tryParse(_portController.text.trim()) ?? 22,
      username: _usernameController.text.trim(),
      authType: HostAuthType.password,
      projectPath: existing?.projectPath ?? '',
      tmuxSessionName: _tmuxController.text.trim(),
      agentCommand: _agentCommandController.text.trim(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      password: _passwordController.text,
      isDefault: shouldBeDefault,
    );

    // First save the host
    await state.saveHost(host);
    
    // If setting as default and there are multiple hosts, update all hosts
    if (shouldBeDefault && hostCount > 0) {
      await state.setDefaultHost(host.id);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _ipAddress() {
    return _ipControllers.map((controller) => controller.text.trim()).join('.');
  }

  bool _isValidIpAddress(String value) {
    final segments = value.split('.');
    if (segments.length != 4) {
      return false;
    }
    return segments.every((segment) {
      final number = int.tryParse(segment);
      return number != null && number >= 0 && number <= 255;
    });
  }

  List<String> _ipSegments(String address) {
    final segments = address.split('.');
    if (segments.length != 4) {
      return ['', '', '', ''];
    }
    return segments;
  }
}

class _IpAddressField extends StatelessWidget {
  const _IpAddressField({
    required this.controllers,
    required this.focusNodes,
  });

  final List<TextEditingController> controllers;
  final List<FocusNode> focusNodes;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < 4; index++) ...[
          Expanded(
            child: TextFormField(
              key: ValueKey('host-ip-segment-$index'),
              controller: controllers[index],
              focusNode: focusNodes[index],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              decoration: const InputDecoration(counterText: ''),
              validator: (value) {
                final number = int.tryParse(value ?? '');
                if (number == null || number < 0 || number > 255) {
                  return '0-255';
                }
                return null;
              },
              onChanged: (value) {
                if (value.length == 3 && index < focusNodes.length - 1) {
                  focusNodes[index + 1].requestFocus();
                }
              },
            ),
          ),
          if (index < 3)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('.'),
            ),
        ],
      ],
    );
  }
}
