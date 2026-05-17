import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../hosts/screens/host_list_screen.dart';
import '../../voice/services/voice_service.dart';
import '../models/task_session.dart';
import '../services/speech_draft_cleaner.dart';
import '../widgets/task_card.dart';
import 'task_draft_screen.dart';

enum _HomeVoiceStatus {
  idle,
  listening,
  transcribing,
  ready,
  failed,
}

class TaskHomeScreen extends StatefulWidget {
  const TaskHomeScreen({super.key});

  @override
  State<TaskHomeScreen> createState() => _TaskHomeScreenState();
}

class _TaskHomeScreenState extends State<TaskHomeScreen> {
  final _cleaner = SpeechDraftCleaner();
  _HomeVoiceStatus _voiceStatus = _HomeVoiceStatus.idle;
  String _partialText = '';
  String _recognizedText = '';

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final currentTask = _currentTask(state.tasks);
    final recentTasks = state.tasks
        .where((task) => task.id != currentTask?.id)
        .toList(growable: false);

    return Scaffold(
      body: SafeArea(
        child: !state.ready
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 132),
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: ArminTheme.mint,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.auto_awesome,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Armin',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontSize: 26),
                                ),
                                Text(
                                  'AI coding agent Shell',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: 'Hosts',
                            icon: const Icon(Icons.settings_outlined),
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const HostListScreen(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      const _SectionHeader(title: '当前任务'),
                      const SizedBox(height: 12),
                      if (currentTask == null)
                        _EmptyCurrentTask(
                          onCreate: () => _openNewTask(context),
                        )
                      else
                        TaskCard(
                          task: currentTask,
                          featured: true,
                          onTap: () => _openTask(context, currentTask.id),
                        ),
                      Row(
                        children: [
                          const _SectionHeader(title: '最近任务'),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _openNewTask(context),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('新任务'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final task in recentTasks)
                        TaskCard(
                          task: task,
                          onTap: () => _openTask(context, task.id),
                        ),
                    ],
                  ),
                  if (_voiceStatus != _HomeVoiceStatus.idle)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 12,
                      child: _HomeVoicePanel(
                        status: _voiceStatus,
                        text: _displayVoiceText,
                        onCancel: _cancelVoiceCapture,
                        onUseResult: _recognizedText.trim().isEmpty
                            ? null
                            : () => _openNewTask(
                                  context,
                                  initialTaskText: _recognizedText,
                                ),
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: SizedBox(
        width: 70,
        height: 70,
        child: Listener(
          key: const ValueKey('home-voice-button'),
          onPointerDown: (_) => _startVoiceCapture(),
          onPointerUp: (_) => _stopVoiceCapture(),
          onPointerCancel: (_) => _stopVoiceCapture(),
          child: FloatingActionButton(
            backgroundColor: _voiceStatus == _HomeVoiceStatus.listening
                ? ArminTheme.mint
                : ArminTheme.primary,
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            onPressed: () {},
            child: const Icon(Icons.mic, size: 32),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        height: 76,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            label: '主机',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '我',
          ),
        ],
        onDestinationSelected: (index) {
          if (index == 2) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const HostListScreen(),
              ),
            );
          }
        },
      ),
    );
  }

  String get _displayVoiceText {
    if (_partialText.trim().isNotEmpty) {
      return _partialText;
    }
    if (_recognizedText.trim().isNotEmpty) {
      return _recognizedText;
    }
    return switch (_voiceStatus) {
      _HomeVoiceStatus.listening => '正在听...',
      _HomeVoiceStatus.transcribing => '正在整理语音',
      _HomeVoiceStatus.failed => '未检测到语音，可返回后手动新建任务',
      _HomeVoiceStatus.idle || _HomeVoiceStatus.ready => '',
    };
  }

  Future<void> _startVoiceCapture() async {
    if (_voiceStatus == _HomeVoiceStatus.listening ||
        _voiceStatus == _HomeVoiceStatus.transcribing) {
      return;
    }

    final voiceService = AppStateScope.of(context).voiceService;
    if (!voiceService.isAvailable) {
      setState(() {
        _voiceStatus = _HomeVoiceStatus.failed;
        _partialText = '';
        _recognizedText = '当前设备不支持语音，请手动输入';
      });
      return;
    }

    setState(() {
      _voiceStatus = _HomeVoiceStatus.listening;
      _partialText = '';
      _recognizedText = '';
    });

    try {
      await voiceService.startListening(
        onPartial: (partial) {
          if (!mounted) {
            return;
          }
          setState(() => _partialText = partial);
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = _HomeVoiceStatus.failed;
        _partialText = '';
        _recognizedText = _voiceErrorMessage(e);
      });
    }
  }

  Future<void> _stopVoiceCapture() async {
    if (_voiceStatus != _HomeVoiceStatus.listening) {
      return;
    }

    setState(() => _voiceStatus = _HomeVoiceStatus.transcribing);
    try {
      final raw = await AppStateScope.of(context).voiceService.stopListening();
      if (!mounted) {
        return;
      }
      final cleaned = _cleaner.clean(raw);
      setState(() {
        _partialText = '';
        _recognizedText = cleaned;
        _voiceStatus =
            cleaned.isEmpty ? _HomeVoiceStatus.failed : _HomeVoiceStatus.ready;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _partialText = '';
        _recognizedText = _voiceErrorMessage(e);
        _voiceStatus = _HomeVoiceStatus.failed;
      });
    }
  }

  String _voiceErrorMessage(Object error) {
    if (error is VoiceUnavailableException) {
      return error.message;
    }
    return '语音识别失败：${error.toString()}';
  }

  void _cancelVoiceCapture() {
    setState(() {
      _voiceStatus = _HomeVoiceStatus.idle;
      _partialText = '';
      _recognizedText = '';
    });
  }

  TaskSession? _currentTask(List<TaskSession> tasks) {
    for (final task in tasks) {
      if (task.status == TaskStatus.running ||
          task.status == TaskStatus.needApproval) {
        return task;
      }
    }
    return tasks.isEmpty ? null : tasks.first;
  }

  void _openTask(BuildContext context, String taskId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: taskId),
      ),
    );
  }

  void _openNewTask(BuildContext context, {String initialTaskText = ''}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(initialTaskText: initialTaskText),
      ),
    );
  }
}

class _HomeVoicePanel extends StatelessWidget {
  const _HomeVoicePanel({
    required this.status,
    required this.text,
    required this.onCancel,
    required this.onUseResult,
  });

  final _HomeVoiceStatus status;
  final String text;
  final VoidCallback onCancel;
  final VoidCallback? onUseResult;

  @override
  Widget build(BuildContext context) {
    final title = switch (status) {
      _HomeVoiceStatus.listening => '正在听',
      _HomeVoiceStatus.transcribing => '正在整理语音',
      _HomeVoiceStatus.ready => '语音结果',
      _HomeVoiceStatus.failed => '语音不可用',
      _HomeVoiceStatus.idle => '',
    };

    return Material(
      key: const ValueKey('home-voice-panel'),
      color: Colors.white,
      elevation: 10,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ArminTheme.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  key: const ValueKey('home-voice-cancel'),
                  tooltip: '返回',
                  icon: const Icon(Icons.close),
                  onPressed: onCancel,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (status == _HomeVoiceStatus.ready) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const ValueKey('home-voice-use-result'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('写入草稿'),
                  onPressed: onUseResult,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _EmptyCurrentTask extends StatelessWidget {
  const _EmptyCurrentTask({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: InkWell(
        onTap: onCreate,
        borderRadius: BorderRadius.circular(14),
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.mic_none_outlined, color: ArminTheme.primary),
              SizedBox(width: 12),
              Expanded(child: Text('暂无运行任务，点击创建新的委派任务')),
            ],
          ),
        ),
      ),
    );
  }
}
