import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../hosts/screens/host_list_screen.dart';
import '../../projects/screens/project_path_list_screen.dart';
import '../../voice/screens/voice_settings_screen.dart';
import '../../voice/services/device_voice_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const _SectionTitle(label: '执行环境'),
          _SettingsTile(
            key: const ValueKey('settings-hosts'),
            icon: Icons.dns_outlined,
            title: '主机连接',
            subtitle: _hostSummary(state.hosts.length),
            onTap: () => _open(context, const HostListScreen()),
          ),
          _SettingsTile(
            key: const ValueKey('settings-project-paths'),
            icon: Icons.folder_outlined,
            title: '项目目录',
            subtitle: _projectSummary(
              state.projectPaths.length,
              state.defaultProjectPath?.name,
            ),
            onTap: () => _open(context, const ProjectPathListScreen()),
          ),
          const SizedBox(height: 24),
          const _SectionTitle(label: '语音与播报'),
          _SettingsTile(
            key: const ValueKey('settings-voice'),
            icon: Icons.record_voice_over_outlined,
            title: '语音与播报',
            subtitle: _voiceSummary(
              state.speechSettings.enabled,
              state.speechSettings.voiceStyle,
            ),
            onTap: () => _open(context, const VoiceSettingsScreen()),
          ),
        ],
      ),
    );
  }

  String _hostSummary(int count) {
    return count == 0 ? '尚未配置主机' : '已配置 $count 个主机';
  }

  String _projectSummary(int count, String? defaultName) {
    if (count == 0) {
      return '尚未配置项目目录';
    }
    return defaultName == null ? '已配置 $count 个目录' : '默认：$defaultName';
  }

  String _voiceSummary(bool enabled, SpeechVoiceStyle style) {
    if (!enabled) {
      return '已关闭';
    }
    final styleLabel = switch (style) {
      SpeechVoiceStyle.systemDefault => '系统默认',
      SpeechVoiceStyle.clearFemale => '清晰女性',
      SpeechVoiceStyle.fastFemale => '快速女性',
    };
    return '已开启，$styleLabel';
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
