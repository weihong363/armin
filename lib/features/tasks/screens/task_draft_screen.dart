import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
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
      appBar: AppBar(title: const Text('New Task')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            icon: Icon(_isListening ? Icons.hourglass_top : Icons.mic_outlined),
            label: Text(_isListening ? 'Listening...' : 'Mock Voice Input'),
            onPressed: _isListening ? null : _listen,
          ),
          if (_rawStt.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Raw STT', style: Theme.of(context).textTheme.titleSmall),
            Text(_rawStt),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _taskController,
            minLines: 6,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Task description',
              alignLabelWithHint: true,
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
              labelText: 'Supplemental context',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => _refreshPreview(),
          ),
          const SizedBox(height: 16),
          Text('Constraints', style: Theme.of(context).textTheme.titleSmall),
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
            decoration: const InputDecoration(labelText: 'Mock result'),
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
          Text('Secrets', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _secretNameController,
            decoration: const InputDecoration(labelText: 'Secret name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretValueController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Secret value'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretUsageController,
            decoration: const InputDecoration(labelText: 'Usage'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Secret'),
            onPressed: _addSecret,
          ),
          for (final secret in _secrets)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: Text(secret.placeholder),
              subtitle: Text(secret.usage),
            ),
          const SizedBox(height: 16),
          Text('Prompt Preview', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE3E7ED)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _promptPreview.isEmpty ? _buildPrompt() : _promptPreview,
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.send_outlined),
            label: Text(_isSending ? 'Sending...' : 'Send to Mock Agent'),
            onPressed: _isSending ? null : _send,
          ),
        ],
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
    final now = DateTime.now();
    final taskId = 'task-${now.microsecondsSinceEpoch}';
    final prompt = _buildPrompt();
    final secretRecords = _secrets
        .map(
            (secret) => secret.toRedactedRecord(taskId: taskId, createdAt: now))
        .toList();
    var task = TaskSession(
      id: taskId,
      host: state.defaultHost,
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
          payloadJson: '{"agent_command":"${state.defaultHost.agentCommand}"}',
          now: now,
        ),
      ],
    );
    await state.saveTask(task);

    await for (final update in state.agentSessionService.execute(
      AgentExecutionRequest(
        prompt: prompt,
        scenario: _scenario,
        hostId: state.defaultHost.id,
        projectPath: state.defaultHost.projectPath,
        agentCommand: state.defaultHost.agentCommand,
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
}
