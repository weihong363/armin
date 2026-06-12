import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../agent/services/agent_session_service.dart';
import '../../agent/models/agent_approval_config.dart';
import '../../hosts/models/host_config.dart';
import '../../history/screens/task_detail_screen.dart';
import '../../projects/models/project_path_config.dart';
import '../../voice/services/voice_service.dart';
import '../../voice/models/normalization_result.dart';
import '../models/metric_event.dart';
import '../models/native_output_turn.dart';
import '../models/prompt_record.dart';
import '../models/secret_entry.dart';
import '../models/task_constraint.dart';
import '../models/task_draft.dart';
import '../models/task_session.dart';
import '../models/voice_input.dart';
import '../services/agent_instruction_discovery.dart';
import '../../voice/services/transcript_normalizer.dart';
import '../../voice/widgets/normalization_confirmation_sheet.dart';
import '../services/constraint_extractor.dart';
import '../services/prompt_template_builder.dart';
import '../services/secret_redactor.dart';
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
    this.initialProjectPath,
    super.key,
  });

  final String initialTaskText;
  final String? selectedHostId;
  final String? initialProjectPath;

  @override
  State<TaskDraftScreen> createState() => _TaskDraftScreenState();
}

class _TaskDraftScreenState extends State<TaskDraftScreen> {
  final _taskController = TextEditingController();
  final _contextController = TextEditingController();
  final _secretNameController = TextEditingController();
  final _secretValueController = TextEditingController();
  final _secretUsageController = TextEditingController();
  final _normalizer = const TranscriptNormalizer();
  final _cleaner = SpeechDraftCleaner();
  final _extractor = const ConstraintExtractor();
  final _promptBuilder = PromptTemplateBuilder();
  final _secretRedactor = const SecretRedactor();
  final List<SecretEntry> _secrets = [];
  final Set<TaskConstraint> _constraints = {
    TaskConstraint.minimalChange,
    TaskConstraint.noGitCommit,
    TaskConstraint.confirmHighRisk,
  };
  bool _showAdvanced = false;
  _ExecutionMode _executionMode = _ExecutionMode.balanced;

  String _rawStt = '';
  String _cleanedDraft = '';
  String _partialStt = '';
  String _promptPreview = '';
  _VoiceInteractionStatus _voiceStatus = _VoiceInteractionStatus.idle;
  bool _isSending = false;
  bool _isDiscoveringAgentInstructions = false;
  String? _selectedHostId;
  String? _selectedProjectPathId;
  String _agentInstructionMessage = '未检测到 AGENTS.md。Armin 将使用内置轻量上下文治理规则。';
  String _agentInstructionWarning = '';
  String? _agentInstructionDetectionKey;

  @override
  void initState() {
    super.initState();
    final initialText = widget.initialTaskText.trim();
    if (initialText.isNotEmpty) {
      _taskController.text = initialText;
      _cleanedDraft = initialText;
      _promptPreview = _buildPrompt();
    }
    _selectedHostId = widget.selectedHostId;
  }

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
    final state = AppStateScope.of(context);
    final selectedHost = _selectedHost(state.hosts);
    final selectedProjectPath = _selectedProjectPath(state.projectPaths);
    _scheduleAgentInstructionDiscovery(selectedProjectPath, selectedHost);
    return Scaffold(
      appBar: AppBar(
        title: const Text('新建任务'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 188),
        children: [
          _TaskComposerHero(
            taskController: _taskController,
            onChanged: (_) => _refreshPreview(),
            rawStt: _rawStt,
            partialStt: _partialStt,
            voiceStatus: _voiceStatus,
            onStartVoice: _startListening,
            onStopVoice: _stopListening,
          ),
          const SizedBox(height: 20),
          const _SectionTitle(title: '运行环境'),
          const SizedBox(height: 8),
          _ExecutionTarget(
            key: const ValueKey('host-selector'),
            host: selectedHost,
            projectPath: selectedProjectPath,
            onHostChanged: (value) {
              setState(() {
                _selectedHostId = value;
                _agentInstructionDetectionKey = null;
              });
            },
            onProjectChanged: (value) {
              setState(() {
                _selectedProjectPathId = value;
                _agentInstructionDetectionKey = null;
              });
              _refreshPreview();
            },
            hosts: state.hosts,
            projectPaths: state.projectPaths,
          ),
          _AgentInstructionNotice(
            message: _isDiscoveringAgentInstructions
                ? '正在检测 AGENTS.md...'
                : _agentInstructionMessage,
            warning: _agentInstructionWarning,
          ),
          const SizedBox(height: 20),
          const _SectionTitle(title: '执行模式'),
          const SizedBox(height: 8),
          _ExecutionModeSelector(
            mode: _executionMode,
            onChanged: (mode) {
              setState(() {
                _executionMode = mode;
                _syncConstraintsFromMode();
                _promptPreview = _buildPrompt();
              });
            },
          ),
          const SizedBox(height: 20),
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                const Expanded(
                  child: _SectionTitle(title: '高级选项'),
                ),
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  color: ArminTheme.ink.withValues(alpha: 0.54),
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            firstChild: const SizedBox.shrink(),
            secondChild: _AdvancedOptions(
              contextController: _contextController,
              onContextChanged: (_) => _refreshPreview(),
              constraints: _constraints,
              onConstraintToggle: (constraint) {
                setState(() {
                  if (_constraints.contains(constraint)) {
                    _constraints.remove(constraint);
                  } else {
                    _constraints.add(constraint);
                  }
                  _promptPreview = _buildPrompt();
                });
              },
              secretNameController: _secretNameController,
              secretValueController: _secretValueController,
              secretUsageController: _secretUsageController,
              secrets: _secrets,
              onAddSecret: _addSecret,
              onAppendContext: _appendContext,
            ),
            crossFadeState: _showAdvanced
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
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
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('预览'),
                    onPressed: () => _showPromptPreview(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.send_outlined),
                    label: Text(_isSending ? '发送中...' : '发送任务'),
                    onPressed: _isSending ? null : _send,
                  ),
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
      await voiceService.stopSpeaking();
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

      // ---- Voice Transcript Normalization Layer ----
      final result = _normalizer.normalize(raw);

      if (result.confidence >= NormalizationResult.highConfidence) {
        // 高置信度：静默应用修正结果
        _applyRecognizedSpeech(result.correctedText, raw);
      } else {
        // 中低置信度：展示确认界面
        setState(() {
          _voiceStatus = _VoiceInteractionStatus.idle;
          _partialStt = '';
        });
        if (mounted) {
          _showNormalizationConfirmation(raw, result);
        }
      }
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

  void _showNormalizationConfirmation(
    String rawText,
    NormalizationResult result,
  ) {
    NormalizationConfirmationSheet.show(
      context,
      result: result,
      onConfirm: () {
        _applyRecognizedSpeech(result.correctedText, rawText);
      },
      onEdit: () {
        // 直接将修正文本填入输入框
        _applyRecognizedSpeech(result.correctedText, rawText);
      },
      onRetry: () {
        // 重新开始录音
        _startListening();
      },
      onCancel: () {
        // 不做任何操作，保留原始状态
      },
    );
  }

  void _applyRecognizedSpeech(String text, [String? rawStt]) {
    final cleaned = _cleaner.clean(text);
    final extracted = _extractor.extract(text);

    setState(() {
      _rawStt = rawStt ?? text;
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
              ? '仅用于本次任务'
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
                  '提示词预览',
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
        const SnackBar(content: Text('请输入任务描述。')),
      );
      return;
    }

    final state = AppStateScope.of(context);
    final project = _selectedProjectPath(state.projectPaths);
    final projectPath = normalizeRemoteProjectPath(project?.path ?? '');
    if (projectPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置并选择项目目录。')),
      );
      return;
    }

    setState(() => _isSending = true);
    final host = _selectedHost(state.hosts);
    if (host == null) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先添加主机连接配置。')),
      );
      return;
    }
    if (host.password.trim().isEmpty) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在主机连接中填写 SSH 密码。')),
      );
      return;
    }

    final activeCount = state.tasks
        .where((t) => switch (t.status) {
              TaskStatus.completed ||
              TaskStatus.userCompleted ||
              TaskStatus.failed ||
              TaskStatus.userFailed ||
              TaskStatus.stopped ||
              TaskStatus.paused ||
              TaskStatus.observerDetached ||
              TaskStatus.runtimeLost =>
                false,
              _ => true,
            })
        .length;
    if (activeCount >= state.maxActiveTasks) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('活跃任务已达上限（$activeCount/${state.maxActiveTasks}）。'
              '请先完成或停止一些任务后再创建新任务。'),
        ),
      );
      return;
    }

    final now = DateTime.now();
    final taskId = 'task-${now.microsecondsSinceEpoch}';
    final prompt = _buildPrompt();
    final tmuxSessionName = _taskTmuxSessionName(host.tmuxSessionName, taskId);
    final taskHost = host
        .copyWith(
          projectPath: projectPath,
          tmuxSessionName: tmuxSessionName,
        )
        .toSafePersistedCopy();
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
      turns: [
        NativeOutputTurn(
          id: 'turn-$taskId-1',
          taskId: taskId,
          turnIndex: 1,
          userInput: _secretRedactor.redactInlineSecrets(taskText),
          rawOutput: '',
          cleanedOutput: '',
          startedAt: now,
          lastOutputAt: now,
          status: NativeOutputTurnStatus.running,
        ),
      ],
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
    if (!mounted) {
      return;
    }
    state.startTaskExecution(
      task,
      AgentExecutionRequest(
        prompt: prompt,
        hostId: host.id,
        host: host.host,
        port: host.port,
        username: host.username,
        projectPath: projectPath,
        tmuxSessionName: tmuxSessionName,
        agentCommand: host.agentCommand,
        tmuxCommand: host.tmuxCommand,
        pathPrepend: host.pathPrepend,
        shellWrapper: host.shellWrapper,
        password: host.password,
        approvalConfig: AgentApprovalConfig(
          agentType: AgentTypeDetection.detect(host.agentCommand),
          mode: _executionMode.toApprovalMode(),
        ),
      ),
    );

    setState(() => _isSending = false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(taskId: task.id),
      ),
    );
  }

  void _scheduleAgentInstructionDiscovery(
    ProjectPathConfig? project,
    HostConfig? host,
  ) {
    if (project == null || host == null || _isDiscoveringAgentInstructions) {
      return;
    }
    final normalizedProjectPath = normalizeRemoteProjectPath(project.path);
    final detectionKey = AgentInstructionDiscoveryKey(
      hostId: host.id,
      projectPathId: project.id,
      normalizedProjectPath: normalizedProjectPath,
    ).value;
    if (detectionKey == _agentInstructionDetectionKey) {
      return;
    }
    Future.microtask(
      () => _refreshAgentInstructionDiscovery(
        project,
        host,
        detectionKey,
        normalizedProjectPath,
      ),
    );
  }

  Future<void> _refreshAgentInstructionDiscovery(
    ProjectPathConfig project,
    HostConfig host,
    String detectionKey,
    String normalizedProjectPath,
  ) async {
    final state = AppStateScope.of(context);
    setState(() {
      _isDiscoveringAgentInstructions = true;
      _agentInstructionDetectionKey = detectionKey;
      _agentInstructionWarning = '';
    });

    if (host.password.trim().isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDiscoveringAgentInstructions = false;
        _agentInstructionMessage = '未检测到 AGENTS.md。Armin 将使用内置轻量上下文治理规则。';
        _agentInstructionWarning = '主机密码未配置，暂时无法检测 AGENTS.md。';
      });
      return;
    }

    try {
      final result = await state.agentSessionService.discoverAgentInstructions(
        AgentInstructionDiscoveryRequest(
          host: host.host,
          port: host.port,
          username: host.username,
          password: host.password,
          projectPath: normalizedProjectPath,
          pathPrepend: host.pathPrepend,
          shellWrapper: host.shellWrapper,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isDiscoveringAgentInstructions = false;
        _agentInstructionMessage = result.uiMessage;
        _agentInstructionWarning = '';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDiscoveringAgentInstructions = false;
        _agentInstructionMessage = '未检测到 AGENTS.md。Armin 将使用内置轻量上下文治理规则。';
        _agentInstructionWarning = 'AGENTS.md 检测失败。内置轻量上下文治理规则仍会启用。';
      });
    }
  }

  ProjectPathConfig? _selectedProjectPath(List<ProjectPathConfig> items) {
    if (items.isEmpty) {
      return null;
    }
    final selectedId = _selectedProjectPathId;
    if (selectedId != null) {
      for (final item in items) {
        if (item.id == selectedId) {
          return item;
        }
      }
    }
    final initialPath = normalizeRemoteProjectPath(
      widget.initialProjectPath ?? '',
    );
    if (initialPath.isNotEmpty) {
      for (final item in items) {
        if (normalizeRemoteProjectPath(item.path) == initialPath) {
          _selectedProjectPathId = item.id;
          return item;
        }
      }
    }
    final defaultPath = AppStateScope.of(context).defaultProjectPath;
    _selectedProjectPathId = defaultPath?.id ?? items.first.id;
    return defaultPath ?? items.first;
  }

  HostConfig? _selectedHost(List<HostConfig> items) {
    if (items.isEmpty) {
      return null;
    }
    final selectedId = _selectedHostId;
    if (selectedId != null) {
      for (final item in items) {
        if (item.id == selectedId) {
          return item;
        }
      }
    }
    final defaultHost = AppStateScope.of(context).defaultHost;
    _selectedHostId = defaultHost?.id ?? items.first.id;
    return defaultHost ?? items.first;
  }

  String _taskTmuxSessionName(String _, String taskId) {
    final id = taskId.replaceFirst('task-', '');
    final shortId = id.length <= 8 ? id : id.substring(id.length - 8);
    return 'armin-$shortId';
  }

  String _titleFrom(String taskText) {
    final trimmed = taskText.replaceAll('\n', ' ').trim();
    if (trimmed.length <= 32) {
      return trimmed;
    }
    return '${trimmed.substring(0, 32)}...';
  }

  void _syncConstraintsFromMode() {
    _constraints.clear();
    switch (_executionMode) {
      case _ExecutionMode.safe:
        _constraints.addAll({
          TaskConstraint.analyzeOnly,
          TaskConstraint.noGitCommit,
          TaskConstraint.confirmHighRisk,
        });
      case _ExecutionMode.balanced:
        _constraints.addAll({
          TaskConstraint.minimalChange,
          TaskConstraint.noGitCommit,
          TaskConstraint.confirmHighRisk,
        });
      case _ExecutionMode.aggressive:
        _constraints.add(TaskConstraint.allowChanges);
    }
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

class _AgentInstructionNotice extends StatelessWidget {
  const _AgentInstructionNotice({
    required this.message,
    required this.warning,
  });

  final String message;
  final String warning;

  @override
  Widget build(BuildContext context) {
    final hasWarning = warning.trim().isNotEmpty;
    final color = hasWarning ? Colors.orange.shade800 : ArminTheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          hasWarning ? Icons.info_outline : Icons.check_circle_outline,
          size: 18,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            hasWarning ? '$message\n$warning' : message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.72),
                ),
          ),
        ),
      ],
    );
  }
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

class _CompactVoiceButton extends StatelessWidget {
  const _CompactVoiceButton({
    super.key,
    required this.onStart,
    required this.onStop,
  });
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onStart(),
      onTapUp: (_) => onStop(),
      onTapCancel: onStop,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: ArminTheme.mint,
          shape: BoxShape.circle,
          border: Border.all(
            color: ArminTheme.primary.withValues(alpha: 0.28),
          ),
        ),
        child:
            const Icon(Icons.mic_outlined, size: 22, color: ArminTheme.primary),
      ),
    );
  }
}

// ──────────────────── New Task Composer Widgets ────────────────────

enum _ExecutionMode {
  safe,
  balanced,
  aggressive,
}

extension _ExecutionModeApproval on _ExecutionMode {
  AgentApprovalMode toApprovalMode() {
    return switch (this) {
      _ExecutionMode.safe => AgentApprovalMode.safe,
      _ExecutionMode.balanced => AgentApprovalMode.balanced,
      _ExecutionMode.aggressive => AgentApprovalMode.aggressive,
    };
  }
}

extension _ExecutionModeLabel on _ExecutionMode {
  String get label {
    return switch (this) {
      _ExecutionMode.safe => '安全',
      _ExecutionMode.balanced => '平衡',
      _ExecutionMode.aggressive => '激进',
    };
  }

  String get description {
    return switch (this) {
      _ExecutionMode.safe => '只读 · 不做修改',
      _ExecutionMode.balanced => '可修改代码 · 先请示',
      _ExecutionMode.aggressive => '完全授权 · 不中断',
    };
  }

  IconData get icon {
    return switch (this) {
      _ExecutionMode.safe => Icons.shield_outlined,
      _ExecutionMode.balanced => Icons.tune_outlined,
      _ExecutionMode.aggressive => Icons.flash_on_outlined,
    };
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _TaskComposerHero extends StatelessWidget {
  const _TaskComposerHero({
    required this.taskController,
    required this.onChanged,
    required this.rawStt,
    required this.partialStt,
    required this.voiceStatus,
    required this.onStartVoice,
    required this.onStopVoice,
  });

  final TextEditingController taskController;
  final ValueChanged<String> onChanged;
  final String rawStt;
  final String partialStt;
  final _VoiceInteractionStatus voiceStatus;
  final VoidCallback onStartVoice;
  final VoidCallback onStopVoice;

  @override
  Widget build(BuildContext context) {
    final voiceActive = voiceStatus == _VoiceInteractionStatus.listening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '任务编辑器',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Stack(
          children: [
            TextField(
              controller: taskController,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: '需要做什么？',
                alignLabelWithHint: true,
              ),
              onChanged: onChanged,
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: _CompactVoiceButton(
                key: const ValueKey('voice-hold-button'),
                onStart: onStartVoice,
                onStop: onStopVoice,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '帮我看下这个项目有哪些问题 · 修一下登录界面的 bug · 生成一份项目总结',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ArminTheme.ink.withValues(alpha: 0.42),
              ),
          maxLines: voiceActive ? 1 : 2,
        ),
        if (rawStt.isNotEmpty || partialStt.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  voiceStatus == _VoiceInteractionStatus.listening
                      ? '正在听...'
                      : '识别结果',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  partialStt.isNotEmpty ? partialStt : rawStt,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ExecutionTarget extends StatelessWidget {
  const _ExecutionTarget({
    super.key,
    required this.host,
    required this.projectPath,
    required this.onHostChanged,
    required this.onProjectChanged,
    required this.hosts,
    required this.projectPaths,
  });

  final HostConfig? host;
  final ProjectPathConfig? projectPath;
  final ValueChanged<String?> onHostChanged;
  final ValueChanged<String?> onProjectChanged;
  final List<HostConfig> hosts;
  final List<ProjectPathConfig> projectPaths;

  @override
  Widget build(BuildContext context) {
    final projectLabel = projectPath != null ? projectPath!.name : '选择项目';
    final hostSub = host != null
        ? '${host!.name} \u00b7 ${host!.username}@${host!.host}'
        : null;

    return InkWell(
      onTap: () => _showExecutionTargetSheet(context),
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: ArminTheme.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      projectLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (hostSub != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        hostSub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: ArminTheme.ink.withValues(alpha: 0.54),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('点击切换',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ArminTheme.ink.withValues(alpha: 0.48),
                      )),
            ],
          ),
        ),
      ),
    );
  }

  void _showExecutionTargetSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('主机', style: Theme.of(sheetContext).textTheme.titleSmall),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: host?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '执行主机'),
                  items: [
                    for (final h in hosts)
                      DropdownMenuItem(
                        value: h.id,
                        child: Text(
                            '${h.name} \u00b7 ${h.username}@${h.host}:${h.port}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) {
                    onHostChanged(value);
                    Navigator.of(sheetContext).pop();
                  },
                ),
                const SizedBox(height: 16),
                Text('项目', style: Theme.of(sheetContext).textTheme.titleSmall),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: projectPath?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '项目目录'),
                  items: [
                    for (final p in projectPaths)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text('${p.name} \u00b7 ${p.path}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) {
                    onProjectChanged(value);
                    Navigator.of(sheetContext).pop();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ExecutionModeSelector extends StatelessWidget {
  const _ExecutionModeSelector({
    required this.mode,
    required this.onChanged,
  });

  final _ExecutionMode mode;
  final ValueChanged<_ExecutionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            for (final m in _ExecutionMode.values) ...[
              if (m != _ExecutionMode.values.first) const SizedBox(width: 8),
              Expanded(
                child: _ModeCard(
                  mode: m,
                  isSelected: mode == m,
                  onTap: () => onChanged(m),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          mode.description,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ArminTheme.ink.withValues(alpha: 0.62),
              ),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.isSelected,
    required this.onTap,
  });

  final _ExecutionMode mode;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected ? ArminTheme.primary.withValues(alpha: 0.08) : null,
          border: Border.all(
            color: isSelected ? ArminTheme.primary : ArminTheme.border,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Icon(mode.icon,
                  size: 22,
                  color: isSelected
                      ? ArminTheme.primary
                      : ArminTheme.ink.withValues(alpha: 0.54)),
              const SizedBox(height: 4),
              Text(mode.label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isSelected ? ArminTheme.primary : ArminTheme.ink,
                        fontWeight: isSelected ? FontWeight.w600 : null,
                      )),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdvancedOptions extends StatelessWidget {
  const _AdvancedOptions({
    required this.contextController,
    required this.onContextChanged,
    required this.constraints,
    required this.onConstraintToggle,
    required this.secretNameController,
    required this.secretValueController,
    required this.secretUsageController,
    required this.secrets,
    required this.onAddSecret,
    required this.onAppendContext,
  });

  final TextEditingController contextController;
  final ValueChanged<String> onContextChanged;
  final Set<TaskConstraint> constraints;
  final ValueChanged<TaskConstraint> onConstraintToggle;
  final TextEditingController secretNameController;
  final TextEditingController secretValueController;
  final TextEditingController secretUsageController;
  final List<SecretEntry> secrets;
  final VoidCallback onAddSecret;
  final void Function(String value) onAppendContext;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const _SectionTitle(title: '附加上下文'),
        const SizedBox(height: 4),
        Text(
          '可选附加上下文、错误日志或文件路径',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ArminTheme.ink.withValues(alpha: 0.54),
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.report_outlined, size: 18),
              label: const Text('错误日志'),
              onPressed: () => onAppendContext('错误日志：\n'),
            ),
            ActionChip(
              avatar: const Icon(Icons.folder_outlined, size: 18),
              label: const Text('文件路径'),
              onPressed: () => onAppendContext('文件路径：'),
            ),
            ActionChip(
              avatar: const Icon(Icons.terminal_outlined, size: 18),
              label: const Text('命令输出'),
              onPressed: () => onAppendContext('命令输出：\n'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: contextController,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '粘贴错误日志、文件路径或有用的上下文...',
            alignLabelWithHint: true,
          ),
          onChanged: onContextChanged,
        ),
        const SizedBox(height: 16),
        const _SectionTitle(title: '精细约束'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final constraint in TaskConstraint.values)
              FilterChip(
                label: Text(constraint.label),
                selected: constraints.contains(constraint),
                onSelected: (selected) => onConstraintToggle(constraint),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const _SectionTitle(title: '敏感信息'),
        const SizedBox(height: 8),
        TextField(
          controller: secretNameController,
          decoration: const InputDecoration(labelText: '密钥名称'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: secretValueController,
          obscureText: true,
          decoration: const InputDecoration(labelText: '密钥值'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: secretUsageController,
          decoration: const InputDecoration(labelText: '用途'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('添加密钥'),
          onPressed: onAddSecret,
        ),
        for (final secret in secrets)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline),
            title: Text(secret.placeholder),
            subtitle: Text(secret.usage),
          ),
      ],
    );
  }
}
