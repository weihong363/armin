import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../../../core/models/task_status.dart';
import '../../runtime/models/approval_state.dart';
import '../models/task_session.dart';
import '../services/voice_task_command_processor.dart';

class AddContextSheet extends StatelessWidget {
  const AddContextSheet({
    required this.task,
    required this.title,
    required this.hintText,
    required this.onSubmit,
    this.approval,
    this.interpretVoiceCommand,
    super.key,
  });

  final TaskSession task;
  final String title;
  final String hintText;
  final NativeTerminalApproval? approval;
  final VoiceTaskCommandResult? Function(String text, TaskStatus status)?
      interpretVoiceCommand;
  final Future<void> Function(
    BuildContext context,
    String instruction,
    VoiceTaskCommandResult? command,
  ) onSubmit;

  static Future<void> show(
    BuildContext context, {
    required TaskSession task,
    String title = '继续任务',
    String hintText = '接下来需要做什么？',
    NativeTerminalApproval? approval,
    VoiceTaskCommandResult? Function(String text, TaskStatus status)?
        interpretVoiceCommand,
    required Future<void> Function(
      BuildContext context,
      String instruction,
      VoiceTaskCommandResult? command,
    ) onSubmit,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AddContextSheet(
        task: task,
        title: title,
        hintText: hintText,
        approval: approval,
        interpretVoiceCommand: interpretVoiceCommand,
        onSubmit: onSubmit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AddContextControllerHost(
      builder: (controller) => _AddContextSheetBody(
        task: task,
        title: title,
        hintText: hintText,
        approval: approval,
        controller: controller,
        interpretVoiceCommand: interpretVoiceCommand,
        onSubmit: onSubmit,
      ),
    );
  }
}

class _AddContextSheetBody extends StatefulWidget {
  const _AddContextSheetBody({
    required this.task,
    required this.title,
    required this.hintText,
    required this.controller,
    required this.onSubmit,
    this.approval,
    this.interpretVoiceCommand,
  });

  final TaskSession task;
  final String title;
  final String hintText;
  final TextEditingController controller;
  final NativeTerminalApproval? approval;
  final VoiceTaskCommandResult? Function(String text, TaskStatus status)?
      interpretVoiceCommand;
  final Future<void> Function(
    BuildContext context,
    String instruction,
    VoiceTaskCommandResult? command,
  ) onSubmit;

  @override
  State<_AddContextSheetBody> createState() => _AddContextSheetBodyState();
}

class _AddContextSheetBodyState extends State<_AddContextSheetBody> {
  bool _listening = false;
  bool _busy = false;
  bool _submitting = false;
  String _partial = '';
  VoiceTaskCommandResult? _voiceCommand;
  String _recognizedText = '';
  bool _showTextInput = false;

  bool get _hasRecognizedText => _recognizedText.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                _TargetTaskLabel(task: widget.task),
                if (widget.approval != null) ...[
                  const SizedBox(height: 8),
                  _ApprovalSheetDetails(approval: widget.approval!),
                ],
                const SizedBox(height: 16),
                if (!_showTextInput) ...[
                  Text(
                    widget.hintText,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                ],
                _buildInputArea(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea(BuildContext context) {
    if (_submitting) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_showTextInput) {
      return _buildTextInput(context);
    }

    if (_listening || _busy) {
      return _buildListeningState(context);
    }

    if (_hasRecognizedText) {
      return _buildRecognizedState(context);
    }

    return _buildInitialState(context);
  }

  Widget _buildInitialState(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VoiceContextButton(
          disabled: _busy || _submitting,
          listening: _listening,
          busy: _busy,
          onStart: _startVoice,
          onStop: _stopVoice,
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _showTextInput = true),
            child: const Text('手动输入'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
      ],
    );
  }

  Widget _buildListeningState(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_partial.trim().isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _partial,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 16),
        ],
        _VoiceContextButton(
          disabled: false,
          listening: _listening,
          busy: _busy,
          onStart: () {},
          onStop: _busy ? () {} : _stopVoice,
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
      ],
    );
  }

  Widget _buildRecognizedState(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _recognizedText,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        if (_voiceCommand?.isSemanticMatch ?? false) ...[
          const SizedBox(height: 8),
          Text(
            '已识别：${_voiceCommand!.label}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _recognizedText = '';
                    _voiceCommand = null;
                  });
                },
                child: const Text('重试'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _submitVoiceResult,
                icon: const Icon(Icons.send_outlined),
                label: const Text('发送'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _showTextInput = true),
            child: const Text('手动输入'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
      ],
    );
  }

  Widget _buildTextInput(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '输入指令...'),
        ),
        if (_partial.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_partial, style: Theme.of(context).textTheme.bodySmall),
        ],
        if (_voiceCommand?.isSemanticMatch ?? false) ...[
          const SizedBox(height: 8),
          Text(
            '已识别：${_voiceCommand!.label}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submitTextContext,
                icon: const Icon(Icons.send_outlined),
                label: Text(_submitting ? '发送中...' : '发送'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _submitVoiceResult() async {
    if (_recognizedText.trim().isEmpty) {
      return;
    }
    widget.controller.text = _recognizedText;
    await _doSubmit(_recognizedText);
  }

  Future<void> _submitTextContext() async {
    final instruction = widget.controller.text.trim();
    if (instruction.isEmpty) {
      return;
    }
    await _doSubmit(instruction);
  }

  Future<void> _doSubmit(String instruction) async {
    setState(() => _submitting = true);
    try {
      final command =
          _voiceCommand?.sourceText == instruction ? _voiceCommand : null;
      await widget.onSubmit(context, instruction, command);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败：$error')),
      );
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _startVoice() async {
    if (_listening || _busy) {
      return;
    }
    final voiceService = AppStateScope.read(context).voiceService;
    if (!voiceService.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前设备不支持语音，请手动输入')),
      );
      return;
    }
    setState(() {
      _listening = true;
      _partial = '';
    });
    try {
      await voiceService.stopSpeaking();
      await voiceService.startListening(
        onPartial: (value) {
          if (mounted) {
            setState(() => _partial = value);
          }
        },
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _listening = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('语音输入失败：$error')),
      );
    }
  }

  Future<void> _stopVoice() async {
    if (!_listening) {
      return;
    }
    final voiceService = AppStateScope.read(context).voiceService;
    setState(() {
      _listening = false;
      _busy = true;
    });
    try {
      final stopped = await voiceService.stopListening();
      final raw = stopped.trim().isNotEmpty ? stopped.trim() : _partial.trim();
      if (raw.isEmpty) {
        if (mounted) {
          setState(() => _busy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未检测到语音')),
          );
        }
        return;
      }
      _voiceCommand =
          widget.interpretVoiceCommand?.call(raw, widget.task.status);
      if (mounted) {
        setState(() {
          _busy = false;
          _recognizedText = raw;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}

class _TargetTaskLabel extends StatelessWidget {
  const _TargetTaskLabel({required this.task});

  final TaskSession task;

  @override
  Widget build(BuildContext context) {
    return Text(
      '此上下文将添加到：${task.displayTitle}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

class _ApprovalSheetDetails extends StatelessWidget {
  const _ApprovalSheetDetails({required this.approval});

  final NativeTerminalApproval approval;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('原因：${approval.question}'),
            const SizedBox(height: 4),
            Text('状态：${_approvalStateLabel(approval.state)}'),
          ],
        ),
      ),
    );
  }
}

String _approvalStateLabel(ApprovalState state) {
  return switch (state) {
    ApprovalState.none => '无',
    ApprovalState.pending => '等待处理',
    ApprovalState.resolving => '处理中',
    ApprovalState.resolved => '已处理',
    ApprovalState.failed => '处理失败',
  };
}

class _VoiceContextButton extends StatelessWidget {
  const _VoiceContextButton({
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
    final color =
        listening ? Colors.red : Theme.of(context).colorScheme.primary;
    final enabledColor = disabled ? Colors.grey : color;
    final label = busy
        ? '整理语音'
        : listening
            ? '松开'
            : '按住说话';
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

class _AddContextControllerHost extends StatefulWidget {
  const _AddContextControllerHost({required this.builder});

  final Widget Function(TextEditingController controller) builder;

  @override
  State<_AddContextControllerHost> createState() =>
      _AddContextControllerHostState();
}

class _AddContextControllerHostState extends State<_AddContextControllerHost> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}
