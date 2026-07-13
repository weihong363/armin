import 'package:flutter/material.dart';

import '../services/native_slm_client.dart';
import '../services/slm_client.dart';

class SlmSettingsScreen extends StatefulWidget {
  const SlmSettingsScreen({super.key});

  @override
  State<SlmSettingsScreen> createState() => _SlmSettingsScreenState();
}

class _SlmSettingsScreenState extends State<SlmSettingsScreen> {
  static const _client = NativeSlmClient();
  late Future<SlmCapability> _capability = _client.capability();
  bool _installing = false;

  void _refresh() {
    setState(() => _capability = _client.capability());
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除端侧模型？'),
        content: const Text('删除后辅助判断会自动回退到规则路径，不影响任务执行、结果卡片或 TTS。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除模型'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _client.deleteModel();
    if (mounted) _refresh();
  }

  Future<void> _installModel() async {
    setState(() => _installing = true);
    try {
      final capability = await _client.installManagedModel();
      if (!mounted) return;
      setState(() => _capability = Future.value(capability));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('模型安装失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('端侧模型'),
        actions: [
          IconButton(
            tooltip: '重新检测',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<SlmCapability>(
        future: _capability,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final capability = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  capability.available
                      ? Icons.memory_outlined
                      : Icons.memory_rounded,
                ),
                title: Text(capability.available ? '模型已就绪' : '模型不可用'),
                subtitle: Text(capability.message),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('运行时'),
                subtitle: Text(capability.backend),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('模型文件'),
                subtitle: Text(capability.modelPath ?? '未配置'),
                trailing: capability.modelSizeBytes > 0
                    ? Text(_fileSize(capability.modelSizeBytes))
                    : null,
              ),
              const SizedBox(height: 12),
              const Text('模型仅用于低频 Loop Evaluation。正式结果、状态归约和 TTS 始终使用确定性路径。'),
              if (!capability.available && _client.canInstallManagedModel) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _installing ? null : _installModel,
                  icon: _installing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(_installing ? '正在安装模型' : '安装端侧模型'),
                ),
              ],
              if (capability.modelSizeBytes > 0) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _deleteModel,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除本地模型'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _fileSize(int bytes) {
  final megabytes = bytes / (1024 * 1024);
  return '${megabytes.toStringAsFixed(megabytes >= 100 ? 0 : 1)} MB';
}
