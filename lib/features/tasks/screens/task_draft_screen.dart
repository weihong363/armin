import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/services/agent_session_service.dart';
import '../../history/screens/task_detail_screen.dart';
import '../models/execution_log.dart';
import '../models/metric_event.dart';
import '../models/prompt_record.dart';
import '../models/secret_entry.dart';
import '../models/task_constraint.dart';
import '../models/task_draft.dart';
import '../models/task_session.dart';
import '../models/voice_input.dart';
import '../services/constraint_extractor.dart';
import '../services/prompt_template_builder.dart';
import '../services/speech_draft_cleaner.dart';

class TaskDraftScreen extends StatefulWidget {
  const TaskDraftScreen({super.key});

  @override
  State<TaskDraftScreen> createState() => _TaskDraftScreenState();
}

class _TaskDraftScreenState extends State<TaskDraftScreen> {
  final _taskController = TextEditingController();
  final _contextController = TextEditingController();
  final _secretNameController = TextEditingController();
  final _secretValueController = TextEditingController();
  final _secretUsageController = TextEditingController();
  final _cleaner = SpeechDraftCleaner();
  final _extractor = ConstraintExtractor();
  final _promptBuilder = PromptTemplateBuilder();
  final List<SecretEntry> _secrets = [];
  final Set<TaskConstraint> _constraints = {
    TaskConstraint.minimalChange,
    TaskConstraint.noGitCommit,
    TaskConstraint.confirmHighRisk,
  };

  String _rawStt = '';
  String _cleanedDraft = '';
  String _promptPreview = '';
  MockAgentScenario _scenario = MockAgentScenario.completed;
  bool _isListening = false;
  bool _isSending = false;

  @override
  void dispose() {
    _taskController.dispose();
    _contextController.dispose();
    _secretNameController.dispose();
    _secretValueController.dispose();
    _secretUsageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('新建任务'),
        actions: [
          IconButton(
            tooltip: 'Prompt',
            icon: const Icon(Icons.description_outlined),
            onPressed: () => _showPromptPreview(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 112),
        children: [
          _VoiceCard(
            isListening: _isListening,
            onListen: _listen,
          ),
          if (_rawStt.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('原始语音转写', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(_rawStt, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('任务草稿', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _taskController,
            minLines: 6,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '描述你要交给 Codex 的任务...',
              alignLabelWithHint: true,
              counterText: '36/1000',
            ),
            onChanged: (_) => _refreshPreview(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.report_outlined),
                label: const Text('添加错误日志'),
                onPressed: () => _appendContext('错误日志：\n'),
              ),
              ActionChip(
                avatar: const Icon(Icons.folder_outlined),
                label: const Text('添加文件路径'),
                onPressed: () => _appendContext('相关路径：'),
              ),
              ActionChip(
                avatar: const Icon(Icons.terminal_outlined),
                label: const Text('添加命令输出'),
                onPressed: () => _appendContext('命令输出：\n'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contextController,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '补充上下文',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => _refreshPreview(),
          ),
          const SizedBox(height: 16),
          Text('执行约束', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final constraint in TaskConstraint.values)
                FilterChip(
                  label: Text(constraint.label),
                  selected: _constraints.contains(constraint),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _constraints.add(constraint);
                      } else {
                        _constraints.remove(constraint);
                      }
                      _promptPreview = _buildPrompt();
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<MockAgentScenario>(
            initialValue: _scenario,
            decoration: const InputDecoration(labelText: 'Mock 执行结果'),
            items: const [
              DropdownMenuItem(
                value: MockAgentScenario.completed,
                child: Text('Completed'),
              ),
              DropdownMenuItem(
                value: MockAgentScenario.needApproval,
                child: Text('Needs approval'),
              ),
              DropdownMenuItem(
                value: MockAgentScenario.failed,
                child: Text('Failed'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _scenario = value);
              }
            },
          ),
          const SizedBox(height: 16),
          Text('敏感信息', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _secretNameController,
            decoration: const InputDecoration(labelText: 'Secret 名称'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretValueController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Secret 值'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretUsageController,
            decoration: const InputDecoration(labelText: '用途'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('添加 Secret'),
            onPressed: _addSecret,
          ),
          for (final secret in _secrets)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: Text(secret.placeholder),
              subtitle: Text(secret.usage),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _showPromptPreview(context),
                  child: const Text('预览 Prompt'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.send_outlined),
                  label: Text(_isSending ? '发送中...' : '发送给 Codex'),
                  onPressed: _isSending ? null : _send,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _listen() async {
    setState(() => _isListening = true);
    final raw = await AppStateScope.of(context).voiceService.listenOnce();
    final cleaned = _cleaner.clean(raw);
    final extracted = _extractor.extract(raw);
    setState(() {
      _rawStt = raw;
      _cleanedDraft = cleaned;
      _taskController.text = cleaned;
      _constraints.addAll(extracted);
      _isListening = false;
      _promptPreview = _buildPrompt();
    });
  }

  void _appendContext(String value) {
    final current = _contextController.text;
    _contextController.text = current.isEmpty ? value : '$current\n$value';
    _refreshPreview();
  }

  void _addSecret() {
    final name = _secretNameController.text.trim();
    final value = _secretValueController.text;
    if (name.isEmpty || value.isEmpty) {
      return;
    }
    setState(() {
      _secrets.add(
        SecretEntry(
          name: name,
          value: value,
          usage: _secretUsageController.text.trim().isEmpty
              ? 'Only for this task'
              : _secretUsageController.text.trim(),
        ),
      );
      _secretNameController.clear();
      _secretValueController.clear();
      _secretUsageController.clear();
      _promptPreview = _buildPrompt();
    });
  }

  String _buildPrompt() {
    return _promptBuilder.build(
      taskDescription: _taskController.text,
      context: _contextController.text,
      constraints: _constraints,
      secrets: _secrets,
    );
  }

  void _refreshPreview() {
    setState(() => _promptPreview = _buildPrompt());
  }

  void _showPromptPreview(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prompt Preview',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _promptPreview.isEmpty ? _buildPrompt() : _promptPreview,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _send() async {
    final taskText = _taskController.text.trim();
    if (taskText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task description is required.')),
      );
      return;
    }

    setState(() => _isSending = true);
    final state = AppStateScope.of(context);
    final host = state.defaultHost;
    final now = DateTime.now();
    final taskId = 'task-${now.microsecondsSinceEpoch}';
    final prompt = _buildPrompt();
    final privateKeyPem = await _privateKeyPemFor(host.privateKeyPath);
    final secretRecords = _secrets
        .map(
            (secret) => secret.toRedactedRecord(taskId: taskId, createdAt: now))
        .toList();
    var task = TaskSession(
      id: taskId,
      host: host,
      title: _titleFrom(taskText),
      status: TaskStatus.running,
      createdAt: now,
      updatedAt: now,
      startedAt: now,
      rawSttText: _rawStt,
      cleanedDraft: _cleanedDraft,
      userText: taskText,
      context: _contextController.text.trim(),
      constraints: Set.unmodifiable(_constraints),
      finalPrompt: prompt,
      secretRecords: secretRecords,
      rawLog: '',
      voiceInputs: [
        if (_rawStt.isNotEmpty)
          VoiceInput(
            id: 'voice-$taskId',
            taskId: taskId,
            rawSttText: _rawStt,
            language: 'zh-CN',
            createdAt: now,
          ),
      ],
      draftRecord: TaskDraft(
        id: 'draft-$taskId',
        taskId: taskId,
        cleanedText: _cleanedDraft,
        userEditedText: taskText,
        contextText: _contextController.text.trim(),
        constraints: Set.unmodifiable(_constraints),
        createdAt: now,
        updatedAt: now,
      ),
      promptRecord: PromptRecord(
        id: 'prompt-$taskId',
        taskId: taskId,
        finalPrompt: prompt,
        templateVersion: PromptTemplateBuilder.templateVersion,
        createdAt: now,
      ),
      metricEvents: [
        MetricEvent.create(
          taskId: taskId,
          eventType: 'task_created',
          payloadJson: '{"source":"new_task"}',
          now: now,
        ),
        MetricEvent.create(
          taskId: taskId,
          eventType: 'task_started',
          payloadJson: '{"agent_command":"${host.agentCommand}"}',
          now: now,
        ),
      ],
    );
    await state.saveTask(task);

    await for (final update in state.agentSessionService.execute(
      AgentExecutionRequest(
        prompt: prompt,
        scenario: _scenario,
        hostId: host.id,
        host: host.host,
        port: host.port,
        username: host.username,
        projectPath: host.projectPath,
        tmuxSessionName: host.tmuxSessionName,
        agentCommand: host.agentCommand,
        privateKeyPem: privateKeyPem,
      ),
    )) {
      final updateAt = DateTime.now();
      final rawLog = '${task.rawLog}${update.rawOutput}';
      final executionLogs = [
        ...task.executionLogs,
        ExecutionLog(
          id: 'log-${updateAt.microsecondsSinceEpoch}',
          taskId: task.id,
          rawOutput: update.rawOutput,
          createdAt: updateAt,
        ),
      ];
      if (update.approval != null) {
        final approval = update.approval!;
        task = task.copyWith(
          status: TaskStatus.needApproval,
          rawLog: rawLog,
          approval: approval,
          approvalRequests: [...task.approvalRequests, approval],
          executionLogs: executionLogs,
          updatedAt: updateAt,
          shortSummary: approval.reason,
          metricEvents: [
            ...task.metricEvents,
            MetricEvent.create(
              taskId: task.id,
              eventType: 'approval_requested',
              payloadJson: '{"risk":"${approval.risk}"}',
              now: updateAt,
            ),
          ],
        );
      } else if (update.result != null) {
        final completedAt = DateTime.now();
        final resultStatus = update.result!.status;
        task = task.copyWith(
          status: resultStatus == 'success'
              ? TaskStatus.completed
              : TaskStatus.failed,
          rawLog: rawLog,
          result: update.result,
          updatedAt: completedAt,
          completedAt: completedAt,
          shortSummary: update.result!.summary,
          summary: update.result!.summary,
          executionLogs: executionLogs,
          metricEvents: [
            ...task.metricEvents,
            MetricEvent.create(
              taskId: task.id,
              eventType: 'task_completed',
              payloadJson: '{"result_status":"$resultStatus"}',
              now: completedAt,
            ),
          ],
          clearApproval: true,
        );
      } else {
        task = task.copyWith(
          rawLog: rawLog,
          updatedAt: updateAt,
          executionLogs: executionLogs,
          metricEvents: [
            ...task.metricEvents,
            MetricEvent.create(
              taskId: task.id,
              eventType: 'agent_output',
              payloadJson: '{"bytes":${update.rawOutput.length}}',
              now: updateAt,
            ),
          ],
        );
      }
      await state.saveTask(task);
    }

    if (!mounted) {
      return;
    }
    setState(() => _isSending = false);
    await state.voiceService.speakSummary(task.shortSummary);
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => TaskDetailScreen(taskId: task.id),
        ),
      );
    }
  }

  String _titleFrom(String taskText) {
    final trimmed = taskText.replaceAll('\n', ' ').trim();
    if (trimmed.length <= 32) {
      return trimmed;
    }
    return '${trimmed.substring(0, 32)}...';
  }

  Future<String?> _privateKeyPemFor(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) {
      return null;
    }
    final expandedPath = path.startsWith('~/')
        ? '${Platform.environment['HOME'] ?? ''}/${path.substring(2)}'
        : path;
    final file = File(expandedPath);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }
}

class _VoiceCard extends StatefulWidget {
  const _VoiceCard({required this.isListening, required this.onListen});

  final bool isListening;
  final VoidCallback onListen;

  @override
  State<_VoiceCard> createState() => _VoiceCardState();
}

class _VoiceCardState extends State<_VoiceCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isListening) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _VoiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListening && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
    if (!widget.isListening && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: InkWell(
        onTap: widget.isListening ? null : widget.onListen,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final pulse = widget.isListening ? _controller.value : 0.0;
                  return SizedBox(
                    width: 132,
                    height: 116,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        _PulseRing(size: 104 + pulse * 24, opacity: 0.18),
                        _PulseRing(size: 88 + pulse * 18, opacity: 0.28),
                        Container(
                          width: 78,
                          height: 78,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFE4F4EF),
                            border: Border.all(
                              color: ArminTheme.mint.withValues(alpha: 0.55),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: _VoiceWaveform(
                              progress:
                                  widget.isListening ? _controller.value : 0.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                widget.isListening ? '正在听...' : '按住说话',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                widget.isListening ? '正在生成语音波形' : '松开发送，或点击停止',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ArminTheme.mint.withValues(alpha: opacity),
          width: 2,
        ),
      ),
    );
  }
}

class _VoiceWaveform extends StatelessWidget {
  const _VoiceWaveform({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    const baseHeights = [14.0, 24.0, 34.0, 22.0, 30.0, 18.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var index = 0; index < baseHeights.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 4,
              height: baseHeights[index] *
                  (0.72 + 0.45 * ((progress + index * 0.19) % 1.0)),
              decoration: BoxDecoration(
                color: ArminTheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ArminTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}
