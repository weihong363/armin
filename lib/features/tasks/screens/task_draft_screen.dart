import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../core/services/armin_app_state.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/services/agent_session_service.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../voice/services/voice_service.dart';
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

enum _VoiceInteractionStatus {
  idle,
  listening,
  transcribing,
}

class TaskDraftScreen extends StatefulWidget {
  const TaskDraftScreen({
    this.initialTaskText = '',
    this.selectedHostId,
    super.key,
  });

  final String initialTaskText;
  final String? selectedHostId;

  @override
  State<TaskDraftScreen> createState() => _TaskDraftScreenState();
}

class _TaskDraftScreenState extends State<TaskDraftScreen> {
  final _taskController = TextEditingController();
  final _projectPathController = TextEditingController();
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
  String _partialStt = '';
  String _promptPreview = '';
  _VoiceInteractionStatus _voiceStatus = _VoiceInteractionStatus.idle;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    final initialText = widget.initialTaskText.trim();
    if (initialText.isNotEmpty) {
      _taskController.text = initialText;
      _cleanedDraft = initialText;
      _promptPreview = _buildPrompt();
    }
    // Initialize selected host from parameter or default
  }

  @override
  void dispose() {
    _taskController.dispose();
    _projectPathController.dispose();
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 188),
        children: [
          if (_rawStt.isNotEmpty || _partialStt.isNotEmpty) ...[
            _SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _voiceStatus == _VoiceInteractionStatus.listening
                        ? '实时语音转写'
                        : '原始语音转写',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _partialStt.isNotEmpty ? _partialStt : _rawStt,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
          TextField(
            controller: _projectPathController,
            decoration: const InputDecoration(
              labelText: 'Project path',
              hintText: '/path/to/repo',
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
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: ArminTheme.border)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VoiceDock(
                  status: _voiceStatus,
                  onStart: _startListening,
                  onStop: _stopListening,
                ),
                const SizedBox(height: 10),
                Row(
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startListening() async {
    if (_isSending || _voiceStatus != _VoiceInteractionStatus.idle) {
      return;
    }

    final voiceService = AppStateScope.of(context).voiceService;
    if (!voiceService.isAvailable) {
      _showVoiceUnavailable();
      return;
    }

    setState(() {
      _voiceStatus = _VoiceInteractionStatus.listening;
      _partialStt = '';
    });

    try {
      await voiceService.startListening(
        onPartial: (partial) {
          if (!mounted) {
            return;
          }
          setState(() => _partialStt = partial);
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = _VoiceInteractionStatus.idle;
        _partialStt = '';
      });
      _showVoiceError(e);
    }
  }

  Future<void> _stopListening() async {
    if (_voiceStatus != _VoiceInteractionStatus.listening) {
      return;
    }

    setState(() => _voiceStatus = _VoiceInteractionStatus.transcribing);

    try {
      final stoppedRaw =
          await AppStateScope.of(context).voiceService.stopListening();
      final raw = stoppedRaw.trim().isNotEmpty ? stoppedRaw : _partialStt;

      if (!mounted) {
        return;
      }

      if (raw.trim().isEmpty) {
        setState(() {
          _voiceStatus = _VoiceInteractionStatus.idle;
          _partialStt = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未检测到语音，请重试或手动输入'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      _applyRecognizedSpeech(raw);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = _VoiceInteractionStatus.idle;
        _partialStt = '';
      });
      _showVoiceError(e);
    }
  }

  void _applyRecognizedSpeech(String raw) {
    final cleaned = _cleaner.clean(raw);
    final extracted = _extractor.extract(raw);

    setState(() {
      _rawStt = raw;
      _cleanedDraft = _appendText(_taskController.text, cleaned);
      _taskController.text = _cleanedDraft;
      _taskController.selection = TextSelection.collapsed(
        offset: _taskController.text.length,
      );
      _constraints.addAll(extracted);
      _voiceStatus = _VoiceInteractionStatus.idle;
      _partialStt = '';
      _promptPreview = _buildPrompt();
    });
  }

  String _appendText(String current, String value) {
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty) {
      return current;
    }

    final trimmedCurrent = current.trim();
    if (trimmedCurrent.isEmpty) {
      return trimmedValue;
    }
    return '$trimmedCurrent\n$trimmedValue';
  }

  void _showVoiceUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前设备不支持语音，请手动输入')),
    );
  }

  void _showVoiceError(Object error) {
    final message = error is VoiceUnavailableException
        ? error.message
        : '语音识别失败：${error.toString()}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '手动输入',
          onPressed: () {
            FocusScope.of(context).requestFocus(FocusNode());
          },
        ),
      ),
    );
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
    final projectPath = _projectPathController.text.trim();
    if (taskText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task description is required.')),
      );
      return;
    }
    if (projectPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project path is required.')),
      );
      return;
    }

    setState(() => _isSending = true);
    final state = AppStateScope.of(context);
    final host = state.defaultHost;
    if (host == null) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先添加 SSH Host 配置。')),
      );
      return;
    }
    if (host.password.trim().isEmpty) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在 Host 配置中填写 SSH password。')),
      );
      return;
    }

    final now = DateTime.now();
    final taskId = 'task-${now.microsecondsSinceEpoch}';
    final prompt = _buildPrompt();
    final taskHost = host.copyWith(projectPath: projectPath);
    final secretRecords = _secrets
        .map(
            (secret) => secret.toRedactedRecord(taskId: taskId, createdAt: now))
        .toList();
    final task = TaskSession(
      id: taskId,
      host: taskHost,
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
    unawaited(_runAgentExecution(
      state,
      task,
      AgentExecutionRequest(
        prompt: prompt,
        hostId: host.id,
        host: host.host,
        port: host.port,
        username: host.username,
        projectPath: projectPath,
        tmuxSessionName: host.tmuxSessionName,
        agentCommand: host.agentCommand,
        tmuxCommand: host.tmuxCommand,
        pathPrepend: host.pathPrepend,
        shellWrapper: host.shellWrapper,
        password: host.password,
      ),
    ));

    setState(() => _isSending = false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: task.id),
      ),
    );
  }

  Future<void> _runAgentExecution(
    ArminAppState state,
    TaskSession initialTask,
    AgentExecutionRequest request,
  ) async {
    var task = initialTask;
    try {
      await for (final update in state.agentSessionService.execute(request)) {
        final latest = _latestTask(state, task.id) ?? task;
        if (latest.status == TaskStatus.stopped) {
          return;
        }
        task = _taskWithExecutionUpdate(latest, update);
        await state.saveTask(task);
      }
      if (task.status == TaskStatus.completed) {
        await state.voiceService.speakSummary(task.shortSummary);
      }
    } catch (e) {
      final latest = _latestTask(state, task.id) ?? task;
      if (latest.status == TaskStatus.stopped) {
        return;
      }
      final failedAt = DateTime.now();
      final message = 'SSH 执行失败：${e.toString()}';
      await state.saveTask(
        latest.copyWith(
          status: TaskStatus.failed,
          rawLog: '${latest.rawLog}$message\n',
          updatedAt: failedAt,
          completedAt: failedAt,
          shortSummary: message,
          summary: message,
          executionLogs: [
            ...latest.executionLogs,
            ExecutionLog(
              id: 'log-${failedAt.microsecondsSinceEpoch}',
              taskId: latest.id,
              rawOutput: '$message\n',
              createdAt: failedAt,
            ),
          ],
          metricEvents: [
            ...latest.metricEvents,
            MetricEvent.create(
              taskId: latest.id,
              eventType: 'task_failed',
              payloadJson: '{"reason":"ssh_execution_error"}',
              now: failedAt,
            ),
          ],
          clearApproval: true,
        ),
      );
    }
  }

  TaskSession? _latestTask(ArminAppState state, String taskId) {
    for (final task in state.tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  TaskSession _taskWithExecutionUpdate(
    TaskSession task,
    AgentExecutionUpdate update,
  ) {
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
      return task.copyWith(
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
    }

    if (update.result != null) {
      final completedAt = DateTime.now();
      final resultStatus = update.result!.status;
      return task.copyWith(
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
    }

    if (update.done) {
      final failedAt = DateTime.now();
      final message = update.rawOutput.trim().isEmpty
          ? 'Codex CLI ended without a structured task result.'
          : update.rawOutput.trim();
      return task.copyWith(
        status: TaskStatus.failed,
        rawLog: rawLog,
        updatedAt: failedAt,
        completedAt: failedAt,
        shortSummary: message,
        summary: message,
        executionLogs: executionLogs,
        metricEvents: [
          ...task.metricEvents,
          MetricEvent.create(
            taskId: task.id,
            eventType: 'task_failed',
            payloadJson: '{"reason":"missing_structured_result"}',
            now: failedAt,
          ),
        ],
        clearApproval: true,
      );
    }

    return task.copyWith(
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

  String _titleFrom(String taskText) {
    final trimmed = taskText.replaceAll('\n', ' ').trim();
    if (trimmed.length <= 32) {
      return trimmed;
    }
    return '${trimmed.substring(0, 32)}...';
  }
}

class _VoiceDock extends StatefulWidget {
  const _VoiceDock({
    required this.status,
    required this.onStart,
    required this.onStop,
  });

  final _VoiceInteractionStatus status;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  State<_VoiceDock> createState() => _VoiceDockState();
}

class _VoiceDockState extends State<_VoiceDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (_isListening) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _VoiceDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isListening && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
    if (!_isListening && _controller.isAnimating) {
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
    final statusText = switch (widget.status) {
      _VoiceInteractionStatus.idle => '准备录音',
      _VoiceInteractionStatus.listening => '正在听',
      _VoiceInteractionStatus.transcribing => '正在整理语音',
    };
    final buttonText = switch (widget.status) {
      _VoiceInteractionStatus.idle => '按住说话',
      _VoiceInteractionStatus.listening => '松开发送到草稿',
      _VoiceInteractionStatus.transcribing => '正在整理语音',
    };

    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            statusText,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            key: const ValueKey('voice-hold-button'),
            onTapDown: (_) => widget.onStart(),
            onTapUp: (_) => widget.onStop(),
            onTapCancel: widget.onStop,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 58,
              decoration: BoxDecoration(
                color: _isListening ? ArminTheme.primary : ArminTheme.mint,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: ArminTheme.primary.withValues(alpha: 0.28),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return SizedBox(
                        width: 54,
                        height: 34,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (_isListening)
                              _PulseRing(
                                size: 32 + _controller.value * 10,
                                opacity: 0.18,
                              ),
                            _VoiceWaveform(
                              progress: _isListening ? _controller.value : 0.35,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 10),
                  Text(
                    buttonText,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: _isListening ? Colors.white : ArminTheme.ink,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool get _isListening => widget.status == _VoiceInteractionStatus.listening;
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
