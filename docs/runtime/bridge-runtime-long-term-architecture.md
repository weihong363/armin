# Bridge Runtime 长期架构

> 将 Armin 从手机远程控制界面推进为任务中心 Agent Runtime 的长期方向。

## 问题

当前 Phase 2 实现仍然把 `tmux capture-pane` 输出作为重要的 runtime 事实来源。它适合观察终端可见内容，但不是可靠的完成信号。

`capture-pane` 可以告诉 Armin 终端里当前可见什么，但无法证明：

- Agent 进程是否仍在 thinking
- 子命令是否仍在运行
- TUI 是否隐藏或重写了 thinking 块
- 没有可见输出是否代表本轮已经完成
- 用户响应后权限提示是否真的消失

最重要的规则是：

```text
没有可见输出不等于完成。
```

pane 稳定可能表示 `outputQuieting` 或 `no visible update`，但不能单独产生 `turnIdle`、结果卡片、TTS 播报或任务完成。

## 目标架构

长期上，Flutter App 不应持有权威 runtime 状态。App 是客户端界面：创建任务、查看进度、追加上下文和发送控制决策。

权威 runtime 应逐步迁移到持久化 Bridge 层：

```text
Armin App
    ↓
Remote Bridge Runtime
    ↓
SQLite Task/Event Store
    ↓
Task Watcher
    ↓
tmux / Codex / Qoder / other CLI Agent
```

当前运行在 Flutter 进程内的 Bridge Runtime 是过渡步骤。它适合验证契约、reducer 和 UI 消费方式，但不是最终持久化边界，因为它会随 App 进程结束而消失。

## 持久化边界

SQLite 是 runtime 状态的长期持久化边界。

Runtime 状态不能只依赖 Flutter 内存对象、临时 SSH stream 或终端屏幕快照。持久化 store 至少应拥有：

- `tasks`
- `turns`
- `runtime_events`
- `work_state`
- `approval_state`
- `session_bindings`
- `last_seen_offsets`
- `deliverables`
- `timeline_events`
- `watcher_checkpoints`

App 可以在内存中缓存这些记录，但必须能在重启、重连或 watcher 恢复后，从 SQLite 重建视图。

## Runtime Event 作为状态权威

任务状态应由持久化 runtime events 归约得到，而不是由 UI 直接从终端文本推断。

主要事件示例：

- `TASK_STARTED`
- `TASK_PROGRESS`
- `OUTPUT_UPDATED`
- `TASK_WAITING_USER`
- `APPROVAL_REQUESTED`
- `APPROVAL_RESOLVING`
- `APPROVAL_RESOLVED`
- `APPROVAL_FAILED`
- `DELIVERABLE_UPDATED`
- `TASK_COMPLETED`
- `TASK_FAILED`
- `SESSION_LOST`
- `OBSERVER_DETACHED`
- `OBSERVER_ATTACHED`

`TaskStatus`、`WorkState`、`ApprovalState`、timeline 行、结果卡片和 TTS 都应从事件流和持久化状态派生。

## Watcher 契约

短期内 watcher 可以继续使用 `tmux capture-pane`，但只能把它当作输入源。

允许 watcher 输出：

- 最新可见输出
- 增量输出切片
- last seen offset/hash
- 检测到的审批 prompt
- 检测到的终端选项 prompt
- 检测到的进度/动作文本
- 检测到的强完成/失败 marker

禁止 watcher 行为：

- 把稳定输出当作完成
- 把安静输出直接变成 `turnIdle`
- 从 prompt echo 或仅 thinking 的输出中生成 deliverable
- 在没有确认 prompt 消失或工作继续推进时解决审批

## CLI Adapter 边界

CLI 专属行为应放在 adapter 中，而不是放在通用 watcher 中。

Adapter 应识别：

- 审批 prompt 格式
- 等待用户输入 prompt
- 显式完成 marker
- 失败 marker
- running/thinking marker
- 仅用于展示的输出区块

Codex、Qoder、Claude 和未来 CLI 可以共享通用结构 parser，但个性化 marker 应留在各自 adapter 配置中。

## Adapter 不变量

Adapter 不会消除文本解析。Codex 和 Qoder 是 TUI 程序，raw text 是不可避免的观察输入。长期规则更窄也更重要：

```text
文本只解析一次，只解析新增文本，然后持久化事件。
```

必要不变量：

- Adapter 输入必须基于 delta：`last_offset` / `last_event_id` / `baseline_hash` 定义当前观察窗口。
- 完整 `capture-pane` 快照可用于审计、恢复和人工排查，但不能直接发出状态变更事件。
- 状态变更事件必须有当前 baseline 之后的新证据。
- 旧 exit marker、审批 prompt、终端选项 prompt、thinking 文本、prompt echo 和旧 deliverable 只是历史证据。
- Reducer 在改变 `WorkState`、`ApprovalState`、turn 状态、结果可见性或 TTS 资格前，必须按 offset、event id、marker count 或内容 fingerprint 去重。
- UI 和 TTS 消费 event-linked payload，例如 `ApprovalRequested.question` 或 `TurnCompleted.deliverable`，不能消费任意 task-level 历史 summary。

这能避免 attach/reconnect 把旧终端残留重新播放成新的审批请求、新的进程退出、新的 turn 结果或新的语音事件。

## 任务循环评估

Runtime events 回答任务是在运行、等待、审批中、完成还是失败。后续评估层应回答另一个问题：用户是否从这次任务循环中获得了高效且符合预期的结果。

Armin 的 loop 以任务为边界：

```text
Plan -> Execute -> Observe -> Evaluate -> Adjust -> Verify
```

这是用于任务协作的 Loop Engineering，不是 workflow engine。它应记录轻量事实，帮助后续 turn 更短、更有用：

- 用户输入长度和 follow-up 次数
- 输出长度、deliverable 是否存在、摘要长度
- 可获得时记录 token 消耗
- 审批、暂停/恢复、重试和等待次数
- 用户是否接受、继续、拒绝、重试或标记完成
- 从任务创建到可查看结果的耗时

评估层必须消费持久化 runtime events 和 turn deliverables。它不能从 raw pane 残留、prompt echo、thinking 文本或 CLI chrome 推断质量。它的目的在于提升每次交互效率和结果符合预期程度，而不是做模型基准测试或引入多 Agent 编排。

## 审批生命周期

原生终端审批必须具备持久化生命周期：

```text
pending -> resolving -> resolved
                    \-> failed
```

用户点击 Allow/Reject 后，Armin 不应立即假设远端 Agent 已接受选择。Runtime 应进入 `resolving`，并等待以下确认之一：

- 最新 watcher 输出中审批 prompt 消失
- 选项发送后出现新的 Agent 输出
- adapter 报告确认后的状态转换
- 发送动作失败或超时，产生 `failed`

这能避免 App 显示 `running`，但远端 Agent 实际仍卡在 `Apply this change?`。

## Turn Idle 契约

`turnIdle` 不是安静输出的同义词。

它只应由更强的信号产生，例如：

- 明确等待下一条指令的 prompt
- 明确 Agent-ready prompt
- 已确认的审批/等待用户状态
- adapter 识别到的已完成 turn 输出
- 在所选 Agent 模式下合适的进程退出信号

长时间 thinking、隐藏 TUI 更新、子命令运行和输出安静都必须保持为 `running` 或 `outputQuieting`。

## 部署演进

### Phase A：Flutter Runtime + SQLite

- 增加 SQLite-backed task/event/runtime store，基线由 `SQLiteRuntimePersistenceStore` 实现。
- Bridge Runtime 暂时保留在 Flutter 内，同时让事件归约具备持久性。
- App 重启后从 SQLite 恢复 runtime snapshots 和 `WorkState`。
- 停止把 pane 稳定当成完成信号。

### Phase B：断线/重连回放

- 持久化 watcher offset、snapshot hash 和 last event id。
- 重连时把错过的远端输出回放进 event reducer。
- 把 capture-pane resync 视为 reconcile，而不是 source-of-truth guessing。

### Phase C：远端 Runtime Daemon

- 将 watcher、reducer、审批生命周期和 SQLite store 迁移到远端机器。
- daemon 运行在 tmux/session 环境旁路或内部。
- Mobile App 通过 SSH/RPC/API 与 daemon 通信，只渲染 durable runtime state。

## 非目标

该架构不是：

- 多 Agent scheduler
- workflow engine
- fork/join runtime
- 自动 merge/commit 系统
- Slack/飞书替代品
- 通用终端模拟器

目标更窄：让任务执行状态在用户离开 App 或终端输出变安静后，仍然持久、事件驱动且可靠。
