import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../../shared/theme/armin_theme.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../agent/parsers/approval_request.dart';
import '../../agent/parsers/terminal_prompt.dart';
import '../../agent/services/codex_output_cleaner.dart';
import '../../voice/services/device_voice_service.dart';
import '../../voice/services/voice_service.dart';
import '../../tasks/models/native_output_turn.dart';
import '../../tasks/models/task_session.dart';
import '../../tasks/models/voice_input.dart';
import '../../projects/models/project_path_config.dart';
import '../../tasks/services/output_summary_provider.dart';
import '../../tasks/services/semantic_snippet_builder.dart';
import '../../tasks/services/turn_output_slicer.dart';
import '../../tasks/services/voice_task_command_processor.dart';
import '../../tasks/screens/task_draft_screen.dart';

enum _TaskDetailAction {
  rerun,
  forceStop,
  cleanupSession,
  delete,
}

class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _resultTabIndex = 1;

  late final TabController _tabController =
      TabController(length: 4, vsync: this);
  int _latestTurnRevealToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _revealLatestResult();
    }
  }

  void _revealLatestResult() {
    if (!mounted) {
      return;
    }
    setState(() {
      _latestTurnRevealToken++;
    });
    if (_tabController.index != _resultTabIndex) {
      _tabController.animateTo(_resultTabIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = _findTask(state.tasks);
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          PopupMenuButton<_TaskDetailAction>(
            onSelected: (action) async {
              switch (action) {
                case _TaskDetailAction.rerun:
                  _rerunTask(context, task);
                case _TaskDetailAction.forceStop:
                  await _forceStopTask(context, task);
                case _TaskDetailAction.cleanupSession:
                  await _cleanupSession(context, task);
                case _TaskDetailAction.delete:
                  _confirmDelete(context, task);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _TaskDetailAction.rerun,
                enabled: _canRerun(task),
                child: const Text('重新执行'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.forceStop,
                enabled: _canForceStop(task),
                child: const Text('强制停止'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.cleanupSession,
                enabled: _canCleanupSession(task),
                child: const Text('清理远端会话'),
              ),
              PopupMenuItem(
                value: _TaskDetailAction.delete,
                enabled: _canDelete(task),
                child: const Text('删除任务'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              sliver: SliverToBoxAdapter(child: _SummaryBanner(task: task)),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              sliver: SliverToBoxAdapter(
                child: _RuntimeControlPanel(task: task),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarHeaderDelegate(
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: ArminTheme.ink,
                  indicatorColor: ArminTheme.primary,
                  tabs: const [
                    Tab(text: '时间线'),
                    Tab(text: '结果'),
                    Tab(text: '日志'),
                    Tab(text: '指标'),
                  ],
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: _tabController,
            children: [
              _TimelinePanel(task: task),
              _ResultPanel(
                task: task,
                revealLatestTurnToken: _latestTurnRevealToken,
              ),
              _LogPanel(task: task),
              _MetricsPanel(task: task),
            ],
          ),
        ),
      ),
    );
  }

  TaskSession? _findTask(List<TaskSession> tasks) {
    for (final task in tasks) {
      if (task.id == widget.taskId) {
        return task;
      }
    }
    return null;
  }

  void _rerunTask(BuildContext context, TaskSession task) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDraftScreen(
          initialTaskText: task.userText,
          selectedHostId: task.host.id,
          initialProjectPath: task.host.projectPath,
        ),
      ),
    );
  }

  Future<void> _forceStopTask(BuildContext context, TaskSession task) async {
    try {
      await AppStateScope.read(context).stopTask(task);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('强制停止失败：$error')),
      );
    }
  }

  Future<void> _cleanupSession(BuildContext context, TaskSession task) async {
    try {
      await AppStateScope.read(context).cleanupRemoteSession(task);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已请求清理远端 tmux 会话。')),
        );
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理远端会话失败：$error')),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    TaskSession task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除任务?'),
          content: Text(task.displayTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && context.mounted) {
      try {
        await AppStateScope.read(context).deleteTask(task.id);
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$error')),
        );
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  bool _canDelete(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed;
  }

  bool _canForceStop(TaskSession task) {
    return task.status == TaskStatus.running ||
        task.status == TaskStatus.paused ||
        task.status == TaskStatus.needApproval ||
        task.status == TaskStatus.turnIdle ||
        task.status == TaskStatus.needAttention ||
        task.status == TaskStatus.observerDetached ||
        task.status == TaskStatus.pending;
  }

  bool _canRerun(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed ||
        task.status == TaskStatus.stopped ||
        task.status == TaskStatus.runtimeLost;
  }

  bool _canCleanupSession(TaskSession task) {
    return task.status == TaskStatus.completed ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.userCompleted ||
        task.status == TaskStatus.userFailed ||
        task.status == TaskStatus.stopped ||
        task.status == TaskStatus.runtimeLost;
  }
}

class _SummaryBanner extends StatefulWidget {
  const _SummaryBanner({required this.task});

  final TaskSession task;

  @override
  State<_SummaryBanner> createState() => _SummaryBannerState();
}

class _SummaryBannerState extends State<_SummaryBanner> {
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  Timer? _timer;
  bool _savingTitle = false;
  bool _editingTitle = false;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.task.title;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _SummaryBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.title != widget.task.title) {
      _titleController.text = widget.task.title;
      if (!_editingTitle) {
        _titleFocusNode.unfocus();
      }
    }
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.completedAt != widget.task.completedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _titleFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_isLiveTask(widget.task)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final task = widget.task;
    final projectLabel = _projectLabel(task, state.projectPaths);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F8F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDCECE6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusBadge(status: task.status),
                const Spacer(),
                Text(
                  _finishedLabel(task),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _editingTitle
                  ? TextField(
                      key: const Key('task-title-field'),
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      enabled: !_savingTitle,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      style: Theme.of(context).textTheme.titleLarge,
                      decoration: InputDecoration(
                        labelText: '标题',
                        hintText: task.displayTitle,
                        isDense: true,
                        border: const UnderlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: '保存标题',
                          icon: _savingTitle
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          onPressed: _savingTitle
                              ? null
                              : () => _saveTitle(context, task),
                        ),
                      ),
                      onSubmitted: (_) => _saveTitle(context, task),
                    )
                  : Row(
                      key: const ValueKey('task-title-display'),
                      children: [
                        Expanded(
                          child: Text(
                            task.displayTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '编辑标题',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _savingTitle
                              ? null
                              : () {
                                  setState(() => _editingTitle = true);
                                  _titleController.text = task.title;
                                  _titleController.selection =
                                      TextSelection.collapsed(
                                    offset: _titleController.text.length,
                                  );
                                  Future.microtask(() {
                                    if (mounted) {
                                      _titleFocusNode.requestFocus();
                                    }
                                  });
                                },
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            _TaskMetaLine(
              icon: Icons.folder_outlined,
              label: '项目名',
              value: projectLabel,
            ),
            const SizedBox(height: 6),
            _TaskMetaLine(
              icon: Icons.terminal_outlined,
              label: 'CLI',
              value: _cliLabel(task.host.agentCommand),
            ),
          ],
        ),
      ),
    );
  }

  bool _isLiveTask(TaskSession task) {
    return task.completedAt == null &&
        (task.status == TaskStatus.running ||
            task.status == TaskStatus.pending ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.needApproval ||
            task.status == TaskStatus.turnIdle ||
            task.status == TaskStatus.needAttention ||
            task.status == TaskStatus.observerDetached);
  }

  Future<void> _saveTitle(BuildContext context, TaskSession task) async {
    final trimmed = _titleController.text.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题不能为空。')),
      );
      _titleController.text = task.title;
      return;
    }
    if (trimmed == task.title.trim()) {
      if (mounted) {
        setState(() => _editingTitle = false);
      }
      return;
    }
    setState(() => _savingTitle = true);
    try {
      await AppStateScope.read(context).updateTaskTitle(task, trimmed);
      if (!context.mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      if (mounted) {
        setState(() => _editingTitle = false);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题已更新。')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('标题更新失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingTitle = false);
      }
    }
  }
}

class _TaskMetaLine extends StatelessWidget {
  const _TaskMetaLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: ArminTheme.ink),
        const SizedBox(width: 8),
        Text(
          '$label：',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

String _projectLabel(TaskSession task, List<ProjectPathConfig> projectPaths) {
  final projectPath = normalizeRemoteProjectPath(task.host.projectPath);
  if (projectPath.isEmpty) {
    return '未设置';
  }
  for (final project in projectPaths) {
    if (normalizeRemoteProjectPath(project.path) == projectPath) {
      return project.name.trim().isEmpty ? projectPath : project.name.trim();
    }
  }
  return projectPath;
}

String _cliLabel(String agentCommand) {
  final trimmed = agentCommand.trim();
  return trimmed.isEmpty ? '未设置' : trimmed;
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final readableSummary = const SemanticSnippetBuilder()
        .build(
          const CodexOutputCleaner().clean(task.shortSummary),
          contentType: SnippetContentType.agentSummary,
          maxChars: 220,
        )
        .visibleText;
    final items = [
      _TimelineItem(
        icon: Icons.mic_none_outlined,
        time: _timeLabel(task.createdAt),
        title: '语音输入',
        subtitle: _fallback(task.rawSttText, '原始语音已转写'),
      ),
      _TimelineItem(
        icon: Icons.edit_outlined,
        time: _timeLabel(task.updatedAt),
        title: '任务确认',
        subtitle: '用户确认并发送任务',
      ),
      _TimelineItem(
        icon: Icons.send_outlined,
        time: _timeLabel(task.startedAt ?? task.createdAt),
        title: '发送到 Agent',
        subtitle: '通过 SSH/tmux 发送任务',
      ),
      for (final input in _followUpVoiceInputs(task))
        _TimelineItem(
          icon: Icons.mic_none_outlined,
          time: _timeLabel(input.createdAt),
          title: '语音追加',
          subtitle: input.rawSttText,
        ),
      _TimelineItem(
        icon: _timelineResultIcon(task.status),
        time:
            task.completedAt == null ? '--:--' : _timeLabel(task.completedAt!),
        title: _timelineResultTitle(task.status),
        subtitle: readableSummary.isEmpty ? '任务执行中' : readableSummary,
        color: _timelineResultColor(task.status),
      ),
    ];

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: items.length + (task.turns.isEmpty ? 0 : 1),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index < items.length) {
          return items[index];
        }
        return _InfoCard(
          title: '交互轮次',
          child: _TurnSummaryList(task: task),
        );
      },
    );
  }

  Iterable<VoiceInput> _followUpVoiceInputs(TaskSession task) {
    final hasInitialVoice = task.rawSttText.trim().isNotEmpty &&
        task.voiceInputs.isNotEmpty &&
        task.voiceInputs.first.rawSttText.trim() == task.rawSttText.trim();
    return task.voiceInputs.skip(hasInitialVoice ? 1 : 0);
  }
}

class _TurnSummaryList extends StatelessWidget {
  const _TurnSummaryList({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    final indexedTurns = [
      for (var index = 0; index < task.turns.length; index++)
        _IndexedTurn(index: index, turn: task.turns[index]),
    ]..sort((a, b) => b.turn.turnIndex.compareTo(a.turn.turnIndex));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final indexedTurn in indexedTurns)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TurnSummaryRow(
              turn: indexedTurn.turn,
              turnIndex: indexedTurn.index,
              turns: task.turns,
            ),
          ),
      ],
    );
  }
}

class _TurnSummaryRow extends StatelessWidget {
  const _TurnSummaryRow({
    required this.turn,
    required this.turnIndex,
    required this.turns,
  });

  final NativeOutputTurn turn;
  final int turnIndex;
  final List<NativeOutputTurn> turns;

  @override
  Widget build(BuildContext context) {
    final title = turn.turnIndex == 1
        ? 'Turn ${turn.turnIndex}：初始任务'
        : 'Turn ${turn.turnIndex}：追加指令';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            _MiniBadge(
              label: _turnStatusLabel(turn.status),
              color: _turnStatusColor(turn.status),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _timeLabel(turn.startedAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          _fallback(turn.userInput, '无用户输入'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (turn.rawOutput.isNotEmpty || turn.cleanedOutput.isNotEmpty) ...[
          const SizedBox(height: 6),
          _LazyTurnOutputExpansion(
            key: ValueKey(
              '${turn.id}:${turn.lastOutputAt.microsecondsSinceEpoch}:'
              '${turn.rawOutput.length}:${turn.cleanedOutput.length}',
            ),
            turns: turns,
            turnIndex: turnIndex,
          ),
        ],
      ],
    );
  }
}

class _LazyTurnOutputExpansion extends StatefulWidget {
  const _LazyTurnOutputExpansion({
    required this.turns,
    required this.turnIndex,
    super.key,
  });

  final List<NativeOutputTurn> turns;
  final int turnIndex;

  @override
  State<_LazyTurnOutputExpansion> createState() =>
      _LazyTurnOutputExpansionState();
}

class _LazyTurnOutputExpansionState extends State<_LazyTurnOutputExpansion> {
  static const _turnOutputSlicer = TurnOutputSlicer();

  bool _expanded = false;
  String? _fullOutput;

  @override
  void didUpdateWidget(covariant _LazyTurnOutputExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turns != widget.turns ||
        oldWidget.turnIndex != widget.turnIndex) {
      _fullOutput = _expanded ? _buildFullOutput() : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 4),
      title: const Text('展开完整输出'),
      onExpansionChanged: (expanded) {
        setState(() {
          _expanded = expanded;
          _fullOutput = expanded ? _buildFullOutput() : null;
        });
      },
      children: [
        if (_expanded)
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              _fallback(_fullOutput ?? '', '无'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  String _buildFullOutput() {
    return _turnOutputSlicer.rawOutputForTurn(
      widget.turns,
      widget.turnIndex,
    );
  }
}

enum _VoicePlaybackState { idle, playing, paused }

class _IndexedTurn {
  const _IndexedTurn({required this.index, required this.turn});

  final int index;
  final NativeOutputTurn turn;
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.icon,
    required this.time,
    required this.title,
    required this.subtitle,
    this.color,
  });

  final IconData icon;
  final String time;
  final String title;
  final String subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(time, style: Theme.of(context).textTheme.bodySmall),
        ),
        Icon(icon, size: 20, color: color ?? ArminTheme.ink),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultPanel extends StatefulWidget {
  const _ResultPanel({
    required this.task,
    required this.revealLatestTurnToken,
  });

  final TaskSession task;
  final int revealLatestTurnToken;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  static const _turnOutputSlicer = TurnOutputSlicer();
  static const _foldLineLimit = 20;

  final GlobalKey _topAnchorKey = GlobalKey();
  Future<List<_TurnOutputSummary>>? _summariesFuture;
  int _handledRevealToken = 0;

  String? _activeVoiceCardId;
  _VoicePlaybackState _voicePlaybackState = _VoicePlaybackState.idle;
  VoiceService? _voiceService;

  Future<void> _onVoicePlay(String cardId, String fullOutput) async {
    final voiceService = AppStateScope.read(context).voiceService;

    if (_activeVoiceCardId != null) {
      await voiceService.stopSpeaking();
    }

    _activeVoiceCardId = cardId;
    _voicePlaybackState = _VoicePlaybackState.playing;
    setState(() {});

    final speechText = DeviceVoiceService.cleanSpeechText(fullOutput);
    try {
      await voiceService.speakSummary(speechText);
    } catch (_) {}

    if (!mounted) {
      return;
    }
    if (_activeVoiceCardId == cardId &&
        _voicePlaybackState == _VoicePlaybackState.playing) {
      _activeVoiceCardId = null;
      _voicePlaybackState = _VoicePlaybackState.idle;
      setState(() {});
    }
  }

  void _onVoicePause() {
    if (_activeVoiceCardId == null ||
        _voicePlaybackState != _VoicePlaybackState.playing) {
      return;
    }
    _voiceService?.pauseSpeaking();
    _voicePlaybackState = _VoicePlaybackState.paused;
    setState(() {});
  }

  void _onVoiceStop() {
    if (_activeVoiceCardId == null) {
      return;
    }
    _voiceService?.stopSpeaking();
    _activeVoiceCardId = null;
    _voicePlaybackState = _VoicePlaybackState.idle;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _voiceService = AppStateScope.of(context).voiceService;
    _summariesFuture ??= _outputSummaries(widget.task);
    _maybeRevealLatestTurn();
  }

  @override
  void dispose() {
    _disposeVoiceCoordinator();
    super.dispose();
  }

  void _disposeVoiceCoordinator() {
    if (_activeVoiceCardId != null) {
      _voiceService?.stopSpeaking();
      _activeVoiceCardId = null;
      _voicePlaybackState = _VoicePlaybackState.idle;
    }
  }

  @override
  void didUpdateWidget(covariant _ResultPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.updatedAt != widget.task.updatedAt ||
        oldWidget.task.summary != widget.task.summary ||
        oldWidget.task.result?.summary != widget.task.result?.summary ||
        _turnsSignature(oldWidget.task) != _turnsSignature(widget.task)) {
      _summariesFuture = _outputSummaries(widget.task);
    }
    if (oldWidget.revealLatestTurnToken != widget.revealLatestTurnToken) {
      _maybeRevealLatestTurn();
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.task.result;
    return ListView(
      key: const PageStorageKey<String>('task-detail-result-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
      children: [
        SizedBox(key: _topAnchorKey, height: 0),
        _InfoCard(
          title: '输出',
          trailing: Text(
            '点击播放/暂停 · 长按终止',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ArminTheme.ink.withValues(alpha: 0.45),
                ),
          ),
          child: FutureBuilder<List<_TurnOutputSummary>>(
            future: _summariesFuture,
            builder: (context, snapshot) {
              final outputs = snapshot.data ?? const [];
              if (outputs.isEmpty) {
                return const Text('暂无结果');
              }
              return Column(
                children: [
                  for (final output in outputs)
                    _OutputSegmentCard(
                      title: output.title,
                      text: output.text,
                      speechText: output.speechText,
                      fullOutputForSpeech: output.fullOutputForSpeech,
                      foldLineLimit: _foldLineLimit,
                      cardId: output.title,
                      voicePlaybackState: _activeVoiceCardId == output.title
                          ? _voicePlaybackState
                          : _VoicePlaybackState.idle,
                      onVoicePlay: _onVoicePlay,
                      onVoicePause: _onVoicePause,
                      onVoiceStop: _onVoiceStop,
                    ),
                ],
              );
            },
          ),
        ),
        _InfoCard(
          title: '执行详情',
          child: _ResultDetailsSection(
            changedFiles: result?.changedFiles ?? const [],
            validation: result?.validation ?? const [],
            risks: result?.risks ?? const [],
            nextActions: result?.nextActions ?? const [],
          ),
        ),
      ],
    );
  }

  Future<List<_TurnOutputSummary>> _outputSummaries(TaskSession task) async {
    final provider = AppStateScope.of(context).outputSummaryProvider;
    final summaries = <_TurnOutputSummary>[];
    final indexedTurns = [
      for (var index = 0; index < task.turns.length; index++)
        _IndexedTurn(index: index, turn: task.turns[index]),
    ]..sort((a, b) => b.turn.turnIndex.compareTo(a.turn.turnIndex));
    for (final indexedTurn in indexedTurns) {
      final index = indexedTurn.index;
      final turn = indexedTurn.turn;
      if (!_isResultTurn(turn.status)) {
        continue;
      }
      final cleanedOutput = _turnOutputSlicer.outputForTurn(task.turns, index);
      final summary = await provider.summarize(
        OutputSummaryRequest(
          cleanedOutput: cleanedOutput,
          status: task.status,
          taskTitle: task.title,
          promptInputs: [turn.userInput],
          agentCommand: task.host.agentCommand,
        ),
      );
      final text = summary.displaySummary.trim();
      final speechText = summary.speechSummary.trim().isNotEmpty
          ? summary.speechSummary.trim()
          : DeviceVoiceService.cleanSpeechText(text);
      if (text.isNotEmpty) {
        summaries.add(
          _TurnOutputSummary(
            title: 'Turn ${turn.turnIndex}',
            text: text,
            speechText: speechText,
            fullOutputForSpeech: text,
          ),
        );
      }
    }
    if (summaries.isNotEmpty) {
      return summaries;
    }
    final legacy = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: _legacyOutputSource(task),
        status: task.status,
        taskTitle: task.title,
        promptInputs: [
          task.userText,
          ...task.turns.map((turn) => turn.userInput)
        ],
        agentCommand: task.host.agentCommand,
      ),
    );
    final text = legacy.displaySummary.trim();
    return text.isEmpty
        ? const []
        : [
            _TurnOutputSummary(
              title: '输出结果',
              text: text,
              speechText: legacy.speechSummary.trim().isNotEmpty
                  ? legacy.speechSummary.trim()
                  : DeviceVoiceService.cleanSpeechText(text),
              fullOutputForSpeech: text,
            ),
          ];
  }

  bool _isResultTurn(NativeOutputTurnStatus status) {
    return switch (status) {
      NativeOutputTurnStatus.needAttention => false,
      NativeOutputTurnStatus.running ||
      NativeOutputTurnStatus.turnIdle ||
      NativeOutputTurnStatus.runtimeLost ||
      NativeOutputTurnStatus.failed ||
      NativeOutputTurnStatus.completedByUser ||
      NativeOutputTurnStatus.failedByUser ||
      NativeOutputTurnStatus.stopped =>
        true,
    };
  }

  void _maybeRevealLatestTurn() {
    if (widget.revealLatestTurnToken == _handledRevealToken) {
      return;
    }
    _handledRevealToken = widget.revealLatestTurnToken;
    _scheduleScrollToTop();
  }

  void _scheduleScrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final anchorContext = _topAnchorKey.currentContext;
      if (anchorContext != null) {
        Scrollable.ensureVisible(
          anchorContext,
          alignment: 0,
          duration: Duration.zero,
        );
      }
    });
  }

  String _turnsSignature(TaskSession task) {
    return task.turns
        .map(
          (turn) => [
            turn.turnIndex,
            turn.status.name,
            turn.userInput,
            turn.rawOutput,
            turn.cleanedOutput,
            turn.lastOutputAt.microsecondsSinceEpoch,
          ].join('|'),
        )
        .join('\n---\n');
  }

  String _legacyOutputSource(TaskSession task) {
    final candidates = [
      task.result?.summary ?? '',
      task.summary ?? '',
      task.shortSummary,
    ];
    for (final candidate in candidates) {
      if (const CodexOutputCleaner().clean(candidate).trim().isNotEmpty) {
        return candidate;
      }
    }
    return '';
  }
}

class _ResultDetailsSection extends StatefulWidget {
  const _ResultDetailsSection({
    required this.changedFiles,
    required this.validation,
    required this.risks,
    required this.nextActions,
  });

  final List<String> changedFiles;
  final List<String> validation;
  final List<String> risks;
  final List<String> nextActions;

  @override
  State<_ResultDetailsSection> createState() => _ResultDetailsSectionState();
}

class _ResultDetailsSectionState extends State<_ResultDetailsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          label: Text(_expanded ? '收起非输出内容' : '展开非输出内容'),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            children: [
              _DetailList(
                title: '变更文件',
                values: widget.changedFiles,
              ),
              _DetailList(
                title: '验证结果',
                values: widget.validation,
              ),
              _DetailList(
                title: '潜在风险',
                values: widget.risks,
              ),
              _DetailList(
                title: '下一步',
                values: widget.nextActions,
              ),
            ],
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        ),
      ],
    );
  }
}

class _TurnOutputSummary {
  const _TurnOutputSummary({
    required this.title,
    required this.text,
    this.speechText = '',
    required this.fullOutputForSpeech,
  });

  final String title;
  final String text;
  final String speechText;
  final String fullOutputForSpeech;
}

class _OutputSegmentCard extends StatefulWidget {
  const _OutputSegmentCard({
    required this.title,
    required this.text,
    required this.speechText,
    required this.fullOutputForSpeech,
    required this.foldLineLimit,
    required this.cardId,
    required this.voicePlaybackState,
    required this.onVoicePlay,
    required this.onVoicePause,
    required this.onVoiceStop,
  });

  final String title;
  final String text;
  final String speechText;
  final String fullOutputForSpeech;
  final int foldLineLimit;
  final String cardId;
  final _VoicePlaybackState voicePlaybackState;
  final Future<void> Function(String cardId, String fullOutput) onVoicePlay;
  final VoidCallback onVoicePause;
  final VoidCallback onVoiceStop;

  @override
  State<_OutputSegmentCard> createState() => _OutputSegmentCardState();
}

class _OutputSegmentCardState extends State<_OutputSegmentCard> {
  bool _outputExpanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final needsFolding = lines.length > widget.foldLineLimit;
    final displayText = (needsFolding && !_outputExpanded)
        ? lines.take(widget.foldLineLimit).join('\n')
        : widget.text;

    final voiceButton = _buildVoiceButton();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAF8),
          border: Border.all(color: ArminTheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  voiceButton,
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(displayText),
              if (needsFolding) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _outputExpanded = !_outputExpanded);
                    },
                    icon: Icon(
                      _outputExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    label: Text(
                      _outputExpanded ? '收起' : '展开完整输出',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceButton() {
    final state = widget.voicePlaybackState;

    final IconData icon;
    final String tooltip;
    final VoidCallback onTap;
    final VoidCallback? onLongPress;

    switch (state) {
      case _VoicePlaybackState.idle:
        icon = Icons.volume_up_outlined;
        tooltip = '朗读这段输出';
        onTap = () => _onPlay();
        onLongPress = null;
      case _VoicePlaybackState.playing:
        icon = Icons.pause_outlined;
        tooltip = '暂停朗读（长按停止）';
        onTap = () => widget.onVoicePause();
        onLongPress = () => widget.onVoiceStop();
      case _VoicePlaybackState.paused:
        icon = Icons.play_arrow_outlined;
        tooltip = '继续朗读（长按停止）';
        onTap = () => _onPlay();
        onLongPress = () => widget.onVoiceStop();
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 24),
          ),
        ),
      ),
    );
  }

  void _onPlay() {
    final speechSource = widget.fullOutputForSpeech.isNotEmpty
        ? widget.fullOutputForSpeech
        : (widget.speechText.isNotEmpty ? widget.speechText : widget.text);
    widget.onVoicePlay(widget.cardId, speechSource);
  }
}

class _DetailList extends StatelessWidget {
  const _DetailList({required this.title, required this.values});

  final String title;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _BulletList(values: values.isEmpty ? const ['无'] : values),
          ],
        ),
      ),
    );
  }
}

class _RuntimeControlPanel extends StatefulWidget {
  const _RuntimeControlPanel({required this.task});

  final TaskSession task;

  @override
  State<_RuntimeControlPanel> createState() => _RuntimeControlPanelState();
}

class _RuntimeControlPanelState extends State<_RuntimeControlPanel> {
  static const _voiceCommandProcessor = VoiceTaskCommandProcessor();
  static const _turnOutputSlicer = TurnOutputSlicer();

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final controlState = _runtimeControlStateFromTask(task.status);
    return _InfoCard(
      title: '运行控制',
      trailing: _MiniBadge(
        key: const Key('runtime-control-state-badge'),
        label: controlState.label,
        color: controlState.color,
        animate: task.status == TaskStatus.running,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_pendingApproval(task) != null) ...[
            _ApprovalPromptCard(
              approval: _pendingApproval(task)!,
              onApprove: () => _runControlAction(
                context,
                () => AppStateScope.read(context)
                    .resolveApproval(task, approved: true),
              ),
              onReject: () => _runControlAction(
                context,
                () => AppStateScope.read(context)
                    .resolveApproval(task, approved: false),
              ),
              onVoice: () => _showFollowUpSheet(
                context,
                title: '审批处理',
                hintText: '说“批准”或“拒绝”',
                approval: _pendingApproval(task),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (task.terminalPrompt != null) ...[
            _TerminalPromptCard(
              prompt: task.terminalPrompt!,
              onSelect: (option) => _selectTerminalPromptOption(
                context,
                task,
                option,
              ),
              onVoice: () => _showFollowUpSheet(
                context,
                title: '选择终端选项',
                hintText: _terminalPromptVoiceHint(task.terminalPrompt!),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ControlButton(
                icon: Icons.add_comment_outlined,
                label: '追加指令',
                tone: ControlTone.neutral,
                onPressed: controlState == RuntimeControlState.stopped
                    ? null
                    : () => _showFollowUpSheet(context),
              ),
              _ControlButton(
                icon: Icons.check_circle_outline,
                label: '标记完成',
                tone: ControlTone.neutral,
                onPressed: controlState == RuntimeControlState.stopped ||
                        controlState == RuntimeControlState.detached
                    ? null
                    : () => _runControlAction(
                          context,
                          () => AppStateScope.read(context)
                              .markTaskCompleted(task),
                        ),
              ),
              _ControlButton(
                icon: Icons.report_gmailerrorred_outlined,
                label: '标记失败',
                tone: ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped
                    ? null
                    : () => _runControlAction(
                          context,
                          () =>
                              AppStateScope.read(context).markTaskFailed(task),
                        ),
              ),
              _ControlButton(
                icon: controlState == RuntimeControlState.paused
                    ? Icons.play_arrow_outlined
                    : Icons.pause_outlined,
                label: controlState == RuntimeControlState.paused ? '恢复' : '暂停',
                tone: ControlTone.neutral,
                onPressed: controlState == RuntimeControlState.stopped ||
                        controlState == RuntimeControlState.detached
                    ? null
                    : () => _runControlAction(
                          context,
                          () => controlState == RuntimeControlState.paused
                              ? AppStateScope.read(context).resumeTask(task)
                              : AppStateScope.read(context).pauseTask(task),
                        ),
              ),
              _ControlButton(
                icon: Icons.stop_rounded,
                label: '停止',
                tone: ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped
                    ? null
                    : () => _runControlAction(
                          context,
                          () => AppStateScope.read(context).stopTask(task),
                        ),
              ),
              _ControlButton(
                icon: Icons.sensors_outlined,
                label: '重新监听',
                tone: ControlTone.neutral,
                onPressed: controlState == RuntimeControlState.detached
                    ? () => _runControlAction(
                          context,
                          () => AppStateScope.read(context).reconnectTask(task),
                        )
                    : null,
              ),
              _ControlButton(
                icon: Icons.link_off_outlined,
                label: '断开监听',
                tone: ControlTone.danger,
                onPressed: controlState == RuntimeControlState.stopped ||
                        controlState == RuntimeControlState.detached
                    ? null
                    : () => _runControlAction(
                          context,
                          () =>
                              AppStateScope.read(context).disconnectTask(task),
                        ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _runControlAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('运行控制失败：$error')),
      );
    }
  }

  Future<void> _selectTerminalPromptOption(
    BuildContext context,
    TaskSession task,
    TerminalPromptOption option,
  ) async {
    final needsText = _optionNeedsManualInput(option);
    final customResponse =
        needsText ? await _askTerminalPromptResponse(context, option) : null;
    if (!context.mounted || (needsText && customResponse == null)) {
      return;
    }
    await _runControlAction(
      context,
      () => AppStateScope.read(context).selectTerminalOption(
        task,
        option,
        customResponse: customResponse ?? '',
      ),
    );
  }

  bool _optionNeedsManualInput(TerminalPromptOption option) {
    final label = option.label.toLowerCase();
    return label.contains('type something') ||
        label.contains('input') ||
        label.contains('message') ||
        label.contains('输入') ||
        label.contains('填写') ||
        label.contains('补充');
  }

  String _terminalPromptVoiceHint(TerminalPrompt prompt) {
    final labels = prompt.options
        .where((option) => !_optionNeedsManualInput(option))
        .map((option) => _readableOptionLabel(option))
        .where((label) => label.isNotEmpty)
        .take(3)
        .toList(growable: false);
    if (labels.isEmpty) {
      return '说出要选择的编号，或直接说明要输入的内容';
    }
    final quoted = labels.map((label) => '“$label”').toList(growable: false);
    final examples = quoted.length == 1
        ? quoted.single
        : '${quoted.take(quoted.length - 1).join('、')}或${quoted.last}';
    final hasManualInput = prompt.options.any(_optionNeedsManualInput);
    return hasManualInput ? '说$examples，或说“输入内容”' : '说$examples';
  }

  String _readableOptionLabel(TerminalPromptOption option) {
    final label = option.label.trim();
    if (label.isNotEmpty) {
      return label;
    }
    return '选 ${option.key}';
  }

  Future<String?> _askTerminalPromptResponse(
    BuildContext context,
    TerminalPromptOption option,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _TerminalPromptResponseDialog(option: option),
    );
  }

  ApprovalRequest? _pendingApproval(TaskSession task) {
    for (final approval in task.approvalRequests) {
      if (_isPendingApproval(approval.status)) {
        return approval;
      }
    }
    if (task.approval != null && _isPendingApproval(task.approval!.status)) {
      return task.approval;
    }
    return null;
  }

  bool _isPendingApproval(String status) {
    return status.trim().toLowerCase() == 'pending';
  }

  void _showFollowUpSheet(
    BuildContext context, {
    String title = '追加指令',
    String hintText = '继续补充你的要求...',
    ApprovalRequest? approval,
  }) {
    final state = AppStateScope.read(context);
    var listening = false;
    var busy = false;
    var submitting = false;
    var partial = '';
    VoiceTaskCommandResult? voiceCommand;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return _FollowUpControllerHost(
          builder: (controller) => StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              Future<void> startVoice() async {
                if (listening || busy) {
                  return;
                }
                final voiceService = state.voiceService;
                if (!voiceService.isAvailable) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(content: Text('当前设备不支持语音，请手动输入')),
                  );
                  return;
                }
                setSheetState(() {
                  listening = true;
                  partial = '';
                });
                try {
                  await voiceService.stopSpeaking();
                  await voiceService.startListening(
                    onPartial: (value) {
                      if (!sheetContext.mounted) {
                        return;
                      }
                      setSheetState(() => partial = value);
                    },
                  );
                } catch (error) {
                  if (!sheetContext.mounted) {
                    return;
                  }
                  setSheetState(() => listening = false);
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    SnackBar(content: Text('语音输入失败：$error')),
                  );
                }
              }

              Future<void> stopVoice() async {
                if (!listening) {
                  return;
                }
                final voiceService = state.voiceService;
                setSheetState(() {
                  listening = false;
                  busy = true;
                });
                try {
                  final stopped = await voiceService.stopListening();
                  final raw = stopped.trim().isNotEmpty
                      ? stopped.trim()
                      : partial.trim();
                  if (raw.isEmpty) {
                    if (sheetContext.mounted) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(content: Text('未检测到语音')),
                      );
                    }
                    return;
                  }
                  final prefix = controller.text.trim();
                  controller.text = prefix.isEmpty ? raw : '$prefix\n$raw';
                  controller.selection = TextSelection.collapsed(
                    offset: controller.text.length,
                  );
                  voiceCommand = prefix.isEmpty
                      ? _voiceCommandProcessor.interpret(
                          raw, widget.task.status)
                      : null;
                } finally {
                  if (sheetContext.mounted) {
                    setSheetState(() => busy = false);
                  }
                }
              }

              final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
              final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.82;
              return AnimatedPadding(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: bottomInset),
                child: SafeArea(
                  top: false,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style:
                                  Theme.of(sheetContext).textTheme.titleLarge),
                          if (approval != null) ...[
                            const SizedBox(height: 8),
                            _ApprovalSheetDetails(approval: approval),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            controller: controller,
                            keyboardType: TextInputType.multiline,
                            minLines: 3,
                            maxLines: 5,
                            decoration: InputDecoration(hintText: hintText),
                            onChanged: (_) {
                              if (voiceCommand != null) {
                                setSheetState(() => voiceCommand = null);
                              }
                            },
                          ),
                          if (partial.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              partial,
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ],
                          if (voiceCommand?.isSemanticMatch ?? false) ...[
                            const SizedBox(height: 8),
                            Text(
                              '已识别：${voiceCommand!.label}',
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(sheetContext)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              _VoiceFollowUpButton(
                                disabled: busy || submitting,
                                listening: listening,
                                busy: busy,
                                onStart: startVoice,
                                onStop: stopVoice,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: busy || submitting
                                      ? null
                                      : () async {
                                          final instruction =
                                              controller.text.trim();
                                          if (instruction.isEmpty) {
                                            return;
                                          }
                                          setSheetState(
                                              () => submitting = true);
                                          try {
                                            final command =
                                                voiceCommand?.sourceText ==
                                                        instruction
                                                    ? voiceCommand
                                                    : null;
                                            if (command == null) {
                                              await state.sendFollowUp(
                                                  widget.task, instruction);
                                            } else {
                                              await _runVoiceCommand(
                                                  context, command);
                                            }
                                          } catch (error) {
                                            if (sheetContext.mounted) {
                                              setSheetState(
                                                  () => submitting = false);
                                              ScaffoldMessenger.of(sheetContext)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content:
                                                      Text('指令执行失败：$error'),
                                                ),
                                              );
                                            }
                                            return;
                                          }
                                          if (sheetContext.mounted) {
                                            Navigator.of(sheetContext).pop();
                                          }
                                        },
                                  icon: const Icon(Icons.send_outlined),
                                  label: Text(submitting ? '发送中...' : '发送'),
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
            },
          ),
        );
      },
    );
  }

  Future<void> _runVoiceCommand(
    BuildContext context,
    VoiceTaskCommandResult command,
  ) {
    final state = AppStateScope.read(context);
    return switch (command.action) {
      VoiceTaskAction.sendInstruction => state.sendFollowUp(
          widget.task,
          command.instruction,
          addedConstraints: command.constraints,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.stopTask =>
        state.stopTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.markCompleted => state.markTaskCompleted(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.resumeTask =>
        state.resumeTask(widget.task, rawVoiceText: command.sourceText),
      VoiceTaskAction.reconnectObserver => state.reconnectTask(
          widget.task,
          rawVoiceText: command.sourceText,
        ),
      VoiceTaskAction.selectTerminalOption => state.selectTerminalOption(
          widget.task,
          TerminalPromptOption(
            key: command.terminalOptionKey ?? '',
            label: command.label,
          ),
        ),
      VoiceTaskAction.readResult => _speakLatestResult(context),
      VoiceTaskAction.resolveApprovalRequest => state.resolveApproval(
          widget.task,
          approved: command.approvalApproved ?? false),
    };
  }

  Future<void> _speakLatestResult(BuildContext context) async {
    final state = AppStateScope.read(context);
    final text = await _latestResultSpeechText(context, widget.task);
    if (text.isEmpty) {
      throw const VoiceUnavailableException('没有可朗读的结果内容');
    }
    await state.voiceService.speakSummary(text);
  }

  Future<String> _latestResultSpeechText(
    BuildContext context,
    TaskSession task,
  ) async {
    final provider = AppStateScope.of(context).outputSummaryProvider;
    if (task.turns.isNotEmpty) {
      final latestIndex = task.turns.length - 1;
      final latestTurn = task.turns.last;
      final summary = await provider.summarize(
        OutputSummaryRequest(
          cleanedOutput:
              _turnOutputSlicer.outputForTurn(task.turns, latestIndex),
          status: task.status,
          taskTitle: task.title,
          promptInputs: [latestTurn.userInput],
          agentCommand: task.host.agentCommand,
        ),
      );
      final latestText = summary.displaySummary.trim();
      if (latestText.isNotEmpty) {
        final speechText = summary.speechSummary.trim();
        return speechText.isNotEmpty
            ? speechText
            : DeviceVoiceService.cleanSpeechText(latestText);
      }
    }

    final legacySummary = await provider.summarize(
      OutputSummaryRequest(
        cleanedOutput: _legacyOutputSource(task),
        status: task.status,
        taskTitle: task.title,
        promptInputs: [
          task.userText,
          ...task.turns.map((turn) => turn.userInput)
        ],
        agentCommand: task.host.agentCommand,
      ),
    );
    final legacyText = legacySummary.displaySummary.trim();
    if (legacyText.isEmpty) {
      return '';
    }
    final speechText = legacySummary.speechSummary.trim();
    return speechText.isNotEmpty
        ? speechText
        : DeviceVoiceService.cleanSpeechText(legacyText);
  }

  String _legacyOutputSource(TaskSession task) {
    final candidates = [
      task.result?.summary ?? '',
      task.summary ?? '',
      task.shortSummary,
    ];
    for (final candidate in candidates) {
      if (const CodexOutputCleaner().clean(candidate).trim().isNotEmpty) {
        return candidate;
      }
    }
    return '';
  }
}

class _ApprovalPromptCard extends StatelessWidget {
  const _ApprovalPromptCard({
    required this.approval,
    required this.onApprove,
    required this.onReject,
    required this.onVoice,
  });

  final ApprovalRequest approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Text(
                '任务确认',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            approval.reason,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            approval.command,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),
          Text(
            '风险：${approval.risk}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_outlined),
                label: const Text('允许'),
              ),
              OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_outlined),
                label: const Text('拒绝'),
              ),
              TextButton.icon(
                onPressed: onVoice,
                icon: const Icon(Icons.mic_none_outlined),
                label: const Text('语音处理'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalPromptCard extends StatelessWidget {
  const _TerminalPromptCard({
    required this.prompt,
    required this.onSelect,
    required this.onVoice,
  });

  final TerminalPrompt prompt;
  final ValueChanged<TerminalPromptOption> onSelect;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final command = prompt.command.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pause_circle_outline, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  prompt.question,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton.filledTonal(
                tooltip: '语音选择',
                icon: const Icon(Icons.mic_none_outlined, size: 18),
                onPressed: onVoice,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (command.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              command,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade800,
                    fontFamily: 'monospace',
                  ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in prompt.options)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  avatar: Text(option.key),
                  label: Text(option.label),
                  onPressed: () => onSelect(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalPromptResponseDialog extends StatefulWidget {
  const _TerminalPromptResponseDialog({required this.option});

  final TerminalPromptOption option;

  @override
  State<_TerminalPromptResponseDialog> createState() =>
      _TerminalPromptResponseDialogState();
}

class _TerminalPromptResponseDialogState
    extends State<_TerminalPromptResponseDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    return AlertDialog(
      title: Text('${option.key}. ${option.label}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: '输入要发送给远端 CLI 的内容',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) {
              return;
            }
            Navigator.of(context).pop(text);
          },
          child: const Text('发送'),
        ),
      ],
    );
  }
}

class _ApprovalSheetDetails extends StatelessWidget {
  const _ApprovalSheetDetails({required this.approval});

  final ApprovalRequest approval;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade100),
      ),
      child: Text(
        '${approval.reason}\n${approval.command}\n风险：${approval.risk}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _FollowUpControllerHost extends StatefulWidget {
  const _FollowUpControllerHost({required this.builder});

  final Widget Function(TextEditingController controller) builder;

  @override
  State<_FollowUpControllerHost> createState() =>
      _FollowUpControllerHostState();
}

class _FollowUpControllerHostState extends State<_FollowUpControllerHost> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}

class _LogPanel extends StatefulWidget {
  const _LogPanel({required this.task});

  final TaskSession task;

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '电脑端调试',
          child: SelectableText(
            'tmux attach -t ${task.host.tmuxSessionName}\n'
            'tmux capture-pane -p -t ${task.host.tmuxSessionName} -S -200',
          ),
        ),
        _InfoCard(
          title: 'Approval Requests',
          child: task.approvalRequests.isEmpty && task.approval == null
              ? const Text('无')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final approval in task.approvalRequests.isEmpty
                        ? [task.approval!]
                        : task.approvalRequests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              'reason: ${approval.reason}\n'
                              'command: ${approval.command}\n'
                              'risk: ${approval.risk}\n'
                              'status: ${approval.status}',
                            ),
                            const SizedBox(height: 10),
                            if (_isPendingApproval(approval.status))
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.read(context)
                                              .resolveApproval(task,
                                                  approved: true);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已允许，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.check_outlined),
                                    label: const Text('允许'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      var succeeded = false;
                                      await _runControlAction(
                                        context,
                                        () async {
                                          await AppStateScope.read(context)
                                              .resolveApproval(task,
                                                  approved: false);
                                          succeeded = true;
                                        },
                                      );
                                      if (succeeded && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已拒绝，正在继续监听远端任务。'),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.close_outlined),
                                    label: const Text('拒绝'),
                                  ),
                                ],
                              )
                            else
                              _MiniBadge(
                                label: _approvalStatusLabel(approval.status),
                                color: _approvalStatusColor(approval.status),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  bool _isPendingApproval(String status) {
    return status.trim().toLowerCase() == 'pending';
  }

  String _approvalStatusLabel(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => '已允许',
      'rejected' => '已拒绝',
      final value when value.isNotEmpty => value,
      _ => '已处理',
    };
  }

  Color _approvalStatusColor(String status) {
    return switch (status.trim().toLowerCase()) {
      'approved' => Colors.green.shade700,
      'rejected' => Colors.red.shade700,
      _ => Colors.grey.shade700,
    };
  }

  Future<void> _runControlAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('运行控制失败：$error')),
      );
    }
  }
}

class _MetricsPanel extends StatelessWidget {
  const _MetricsPanel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: '指标',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '指标展示已暂时关闭',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                '任务仍会记录必要运行指标，但当前页面不渲染 metrics 节点，避免长任务详情页卡顿。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TabBarHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TabBarHeaderDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.centerLeft,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarHeaderDelegate oldDelegate) {
    return oldDelegate.tabBar != tabBar;
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Text('无');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('- $value'),
          ),
      ],
    );
  }
}

class _MiniBadge extends StatefulWidget {
  const _MiniBadge({
    required this.label,
    required this.color,
    this.animate = false,
    super.key,
  });

  final String label;
  final Color color;
  final bool animate;

  @override
  State<_MiniBadge> createState() => _MiniBadgeState();
}

class _MiniBadgeState extends State<_MiniBadge> with TickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _MiniBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate ||
        oldWidget.color != widget.color) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.animate && !_isTestEnvironment) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1600),
      )..repeat();
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  bool get _isTestEnvironment {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('Test') || bindingName.contains('Automated');
  }

  @override
  Widget build(BuildContext context) {
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          widget.label,
          style: TextStyle(color: widget.color, fontSize: 12),
        ),
      ),
    );
    if (_controller == null) {
      return pill;
    }
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _CometBadgePainter(
          color: widget.color,
          animation: _controller!,
        ),
        child: pill,
      ),
    );
  }
}

class _CometBadgePainter extends CustomPainter {
  _CometBadgePainter({
    required this.color,
    required Animation<double> animation,
  }) : super(repaint: animation) {
    _animation = animation;
  }

  final Color color;
  late final Animation<double> _animation;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = _animation.value;
    final center = Offset(size.width / 2, size.height / 2);
    final radiusX = math.max(20, size.width / 2 + 5);
    final radiusY = math.max(12, size.height / 2 + 4);
    final angle = progress * math.pi * 2;

    for (var i = 4; i >= 0; i--) {
      final t = i / 4;
      final trailAngle = angle - t * 0.62;
      final dotCenter = Offset(
        center.dx + math.cos(trailAngle) * radiusX,
        center.dy + math.sin(trailAngle) * radiusY,
      );
      final alpha = math.max(0.08, 0.92 - i * 0.19);
      final radius = math.max(1.8, 4.2 - t * 2.3);
      final glowPaint = Paint()
        ..color = color.withValues(alpha: alpha * 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawCircle(dotCenter, radius + 2, glowPaint);

      final dotPaint = Paint()..color = color.withValues(alpha: alpha);
      canvas.drawCircle(dotCenter, radius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CometBadgePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate._animation != _animation;
  }
}

enum RuntimeControlState {
  active,
  paused,
  detached,
  stopped,
}

extension RuntimeControlStateLabel on RuntimeControlState {
  String get label {
    return switch (this) {
      RuntimeControlState.active => '运行中',
      RuntimeControlState.paused => '已暂停',
      RuntimeControlState.detached => '已断开监听',
      RuntimeControlState.stopped => '已停止',
    };
  }

  Color get color {
    return switch (this) {
      RuntimeControlState.active => ArminTheme.primary,
      RuntimeControlState.paused => Colors.orange,
      RuntimeControlState.detached => Colors.blueGrey,
      RuntimeControlState.stopped => Colors.red,
    };
  }
}

RuntimeControlState _runtimeControlStateFromTask(TaskStatus status) {
  return switch (status) {
    TaskStatus.paused => RuntimeControlState.paused,
    TaskStatus.stopped ||
    TaskStatus.runtimeLost ||
    TaskStatus.userCompleted ||
    TaskStatus.userFailed ||
    TaskStatus.completed ||
    TaskStatus.failed =>
      RuntimeControlState.stopped,
    TaskStatus.observerDetached => RuntimeControlState.detached,
    TaskStatus.draft ||
    TaskStatus.pending ||
    TaskStatus.running ||
    TaskStatus.needApproval ||
    TaskStatus.turnIdle ||
    TaskStatus.needAttention =>
      RuntimeControlState.active,
  };
}

enum ControlTone {
  neutral,
  danger,
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final ControlTone tone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = tone == ControlTone.danger ? Colors.red : ArminTheme.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.26)),
      ),
    );
  }
}

class _VoiceFollowUpButton extends StatelessWidget {
  const _VoiceFollowUpButton({
    required this.disabled,
    required this.listening,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final bool disabled;
  final bool listening;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final color = listening ? Colors.red : ArminTheme.primary;
    final enabledColor = disabled ? Colors.grey : color;
    final label = busy
        ? '整理语音'
        : listening
            ? '松开发送'
            : '语音追加';
    return GestureDetector(
      onTapDown: disabled ? null : (_) => onStart(),
      onTapUp: disabled ? null : (_) => onStop(),
      onTapCancel: disabled ? null : onStop,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: enabledColor.withValues(alpha: 0.26)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                listening ? Icons.mic : Icons.mic_none_outlined,
                color: enabledColor,
              ),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: enabledColor)),
            ],
          ),
        ),
      ),
    );
  }
}

String _fallback(String value, String fallback) {
  return value.trim().isEmpty ? fallback : value;
}

String _timeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _finishedLabel(TaskSession task) {
  if (task.status == TaskStatus.turnIdle) {
    return '等待继续';
  }
  if (task.status == TaskStatus.needAttention) {
    return '需处理';
  }
  if (task.status == TaskStatus.observerDetached) {
    return '监听已断开';
  }
  if (task.status == TaskStatus.paused) {
    return '已暂停';
  }
  if (task.status == TaskStatus.runtimeLost) {
    return task.completedAt == null
        ? '运行丢失'
        : '${_timeLabel(task.completedAt!)} 丢失';
  }
  if (task.status == TaskStatus.stopped) {
    return task.completedAt == null
        ? '已停止'
        : '${_timeLabel(task.completedAt!)} 停止';
  }
  if (task.status == TaskStatus.failed ||
      task.status == TaskStatus.userFailed) {
    return task.completedAt == null
        ? '失败'
        : '${_timeLabel(task.completedAt!)} 失败';
  }
  if (task.completedAt == null) {
    return '进行中';
  }
  return '${_timeLabel(task.completedAt!)} 完成';
}

String _timelineResultTitle(TaskStatus status) {
  return switch (status) {
    TaskStatus.needApproval => '等待确认',
    TaskStatus.turnIdle => '等待用户继续',
    TaskStatus.needAttention => '需要处理',
    TaskStatus.observerDetached => '监听已断开',
    TaskStatus.runtimeLost => '运行时丢失',
    TaskStatus.failed || TaskStatus.userFailed => '任务失败',
    _ => '接收结果',
  };
}

IconData _timelineResultIcon(TaskStatus status) {
  return switch (status) {
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost =>
      Icons.error_outline,
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.needApproval ||
    TaskStatus.observerDetached =>
      Icons.pause_circle_outline,
    _ => Icons.check_circle_outline,
  };
}

Color _timelineResultColor(TaskStatus status) {
  return switch (status) {
    TaskStatus.failed ||
    TaskStatus.userFailed ||
    TaskStatus.runtimeLost =>
      Colors.red,
    TaskStatus.turnIdle ||
    TaskStatus.needAttention ||
    TaskStatus.needApproval ||
    TaskStatus.observerDetached =>
      Colors.orange,
    _ => ArminTheme.ink,
  };
}

String _turnStatusLabel(NativeOutputTurnStatus status) {
  return switch (status) {
    NativeOutputTurnStatus.running => '运行中',
    NativeOutputTurnStatus.turnIdle => '等待继续',
    NativeOutputTurnStatus.needAttention => '需处理',
    NativeOutputTurnStatus.runtimeLost => '运行丢失',
    NativeOutputTurnStatus.failed => '失败',
    NativeOutputTurnStatus.completedByUser => '用户完成',
    NativeOutputTurnStatus.failedByUser => '用户失败',
    NativeOutputTurnStatus.stopped => '已停止',
  };
}

Color _turnStatusColor(NativeOutputTurnStatus status) {
  return switch (status) {
    NativeOutputTurnStatus.running => ArminTheme.primary,
    NativeOutputTurnStatus.turnIdle => Colors.teal,
    NativeOutputTurnStatus.needAttention => Colors.orange,
    NativeOutputTurnStatus.runtimeLost => Colors.red,
    NativeOutputTurnStatus.failed => Colors.red,
    NativeOutputTurnStatus.completedByUser => Colors.green,
    NativeOutputTurnStatus.failedByUser => Colors.red,
    NativeOutputTurnStatus.stopped => Colors.red,
  };
}
