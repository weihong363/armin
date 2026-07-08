import 'package:armin/core/models/task_status.dart';
import 'package:armin/features/agent/models/agent_approval_config.dart';
import 'package:armin/features/hosts/models/host_config.dart';
import 'package:armin/features/runtime/models/resolved_runtime_state.dart';
import 'package:armin/features/runtime/models/work_state.dart';
import 'package:armin/features/tasks/models/task_constraint.dart';
import 'package:armin/features/tasks/models/task_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task projection overrides stale working work state', () {
    final task = _task();
    final stale = WorkState(
      taskId: task.id,
      phase: WorkPhase.working,
      headline: 'Agent started.',
      detail: '',
    );

    final resolved = resolveRuntimeState(
      task,
      taskStatus: TaskStatus.turnIdle,
      workState: stale,
    );

    expect(resolved.phase, WorkPhase.turnIdle);
    expect(resolved.headline, '等待你的指示');
    expect(
      isRuntimeStateConsistent(
        taskStatus: TaskStatus.turnIdle,
        workState: stale,
      ),
      isFalse,
    );
  });

  test('matching work state keeps runtime headline and detail', () {
    final task = _task();
    final current = WorkState(
      taskId: task.id,
      phase: WorkPhase.working,
      headline: 'Reading pubspec.yaml',
      detail: 'Current Focus',
    );

    final resolved = resolveRuntimeState(
      task,
      taskStatus: TaskStatus.running,
      workState: current,
    );

    expect(resolved.phase, WorkPhase.working);
    expect(resolved.headline, 'Reading pubspec.yaml');
    expect(resolved.detail, 'Current Focus');
    expect(
      isRuntimeStateConsistent(
        taskStatus: TaskStatus.running,
        workState: current,
      ),
      isTrue,
    );
  });
}

TaskSession _task() {
  final now = DateTime(2026, 7, 5);
  return TaskSession(
    id: 'task-1',
    host: HostConfig(
      id: 'host-1',
      name: 'Dev',
      host: '127.0.0.1',
      port: 22,
      username: 'ironion',
      authType: HostAuthType.password,
      projectPath: '',
      tmuxSessionName: 'armin-39640616',
      agentCommand: 'qodercli',
      createdAt: now,
      updatedAt: now,
    ),
    title: 'Task',
    createdAt: now,
    updatedAt: now,
    rawSttText: '',
    cleanedDraft: 'Task',
    userText: 'Task',
    context: '',
    constraints: const <TaskConstraint>{},
    finalPrompt: 'Task',
    secretRecords: const [],
    approvalMode: AgentApprovalMode.aggressive,
  );
}
