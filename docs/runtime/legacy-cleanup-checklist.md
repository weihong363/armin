# 遗留逻辑清理清单

> Phase 2.5 → Phase A 过渡期 — 旧逻辑向新 Runtime 架构迁移

## 状态

- **当前阶段**: 新旧逻辑共存（Phase 2.5 → Phase A 过渡中，测试需以当前分支 `flutter test` 为准）
- **目标阶段**: 旧逻辑在功能等价、性能不回退、真机验证通过后逐步移除；Phase 2.6 让 RuntimeEventBus + WorkState + ApprovalState 成为稳定主路径，跨重启持久化与 event replay 完成后再讨论唯一权威
- **迁移原则**: 功能连续性优先于架构纯度。从防御层向核心收敛，每步只切换一个调用者，全链路验证后进入下一步；任何迁移如果让原有自动刷新、Tab 切换、朗读或结果验收退化，必须暂停并回补兼容路径
- **核心约束**: 所有状态触发型检测必须基于当前观察基线之后的新增证据
- **持久化边界**: Phase A 以 SQLite Runtime Store 为边界；Flutter 进程内 Runtime 可重建，但状态 reducer 的结果必须可从 SQLite 恢复
- **文档职责**: 本文件是 Phase 2.6 / Phase A 迁移的唯一执行入口。`ROADMAP.md` 只记录方向，`SPEC.md` 只记录产品/行为原则，`ARCHITECTURE.md` 只记录稳定架构边界。
- **回归契约**: 所有迁移必须满足 [Armin 核心行为与性能基线](core-behavior-performance-baseline.md)。任一适用基线失败时，不得继续删除旧逻辑或通过放宽验收标准完成收口。

---

## Phase 2.6 收口修订：不为迁移而迁移

近期真机问题表明，Phase 2.6 不能把“旧逻辑清理”理解为尽快删除 parser / tmux capture / TaskStatus fallback。收口的目标是降低错源、减少重复解析、提升可复盘性，而不是为了形式上统一到 RuntimeEventBus / WorkState 牺牲已经可用的交互。

### 功能不回退红线

以下行为必须先保持，之后才能继续删除旧路径：

- 任务完成后，列表和详情状态能自动从 `running` / `Agent started` 更新到 `turnIdle`、`needAttention`、`runtimeLost` 或终态。
- 自动刷新不能依赖用户手动 pull refresh 才发现远端已完成。
- 任务完成或输出稳定后，Tab 仍可立即切换，结果页首帧不被大日志切片或摘要阻塞。
- 手动朗读、自动 TTS、结果卡片使用同一方向的数据契约，但不能强行绑定到一个同步重解析入口。
- WorkState 可以增强 UI 文案，但不能覆盖或掩盖仍为主数据面的 `TaskSession.status`；当二者冲突时，必须优先保护用户可操作状态。

### parser / tmux capture 的阶段性职责

在完整 event-linked runtime 尚未落地前，parser / tmux capture 不能只作为审计 fallback。它们仍承担三类职责：

1. **Observation input**：为 RuntimeEventBus / WorkState 提供新增证据。
2. **Auto reconcile fallback**：当 stream marker、RuntimeEvent 或 WorkState 卡住时，自动用轻量 probe / snapshot 校准状态。
3. **Audit recovery**：用于最终日志、人工刷新和异常恢复。

禁止做法：

- 仅因为迁移目标是 RuntimeEventBus，就删除自动 reconcile 能力。
- 让 `Agent started` / `working` 文案长期覆盖已经可由 tmux snapshot 证明完成的任务。
- 把 stable pane 或旧 exit marker 直接当作完成；自动 reconcile 必须遵守增量证据、marker count、fingerprint 或明确事件去重。

### 继续迁移的前置条件

后续任何状态类迁移必须同时证明：

- 新 Runtime 路径能覆盖迁移前的自动完成 / 自动等待用户 / 自动断线识别能力。
- 手动刷新能修复的状态，自动 reconcile 也有等价路径。
- WorkState 与 TaskSession 在同一输入下不会长期分叉；若分叉，UI fallback 会保护旧有可用状态。
- 真机完成任务后状态刷新、Tab 切换、结果首帧和朗读都通过验收。

---

## 圈号 → 原始项对照表

> ①–⑫ 为旧版文档第 1–12 项的原始编号，⑬–⑭ 为迁移期间新增的补强项。执行顺序中引用圈号即指下表中对应的原始项。

| 圈号 | 原始项 | 当前归属 Step |
|:---:|------|:---:|
| ① | `TaskWatcher._extractStatus()` — 字符串匹配状态推断 | Step 8（已移除 ✅） |
| ② | `TaskWatcher._extractAction() / _extractCheckpoint()` — 正则匹配摘要提取 | 辅助功能，保留不驱动状态 |
| ③ | `BridgeRuntime.observeOutput()` — TaskWatcher 间接推断状态 | Step 8（已去状态化 ✅） |
| ④ | `_bridgeSyncTerminalStatus()` — 手动桥接同步 | Step 5（已移除 ✅） |
| ⑤ | `ApprovalRequest` — 旧审批模型（字符串 status） | Phase 5 后已物理移除 ✅ |
| ⑥ | `TerminalPrompt → ApprovalRequest` 包装 | 已替换为 `TerminalPrompt → NativeTerminalApproval` ✅ |
| ⑦ | UI 直接消费 `TaskStatus` | Step 9（一等 UI 已迁移，二级 fallback 保留 ✅） |
| ⑧ | `_bridgeSyncTerminalStatus()` 暂停/运行/observer 无操作 | Step 5（已合并移除 ✅） |
| ⑨ | `_bridgeNotifyExecutionUpdate()` — 重型 observeOutput 调用 | Step 4（已轻量化 ✅） |
| ⑩ | `OutputSummaryProvider` 中的 TerminalPrompt 块过滤 | Step 3（已完成 ✅） |
| ⑪ | `AgentExecutionUpdate` 旧字段与新模型并存 | Step 7（旧字段已物理移除，native-only ✅） |
| ⑫ | Attach/Reconnect 解析历史残留 | Step 0（已完成 ✅） |
| ⑬ | 结果/TTS 同源门禁 | Step 1（半迁移态：evidence / resolved summary 契约已建立，按 event-linked deliverable 继续演进） |
| ⑭ | 运行时限制分类门禁 | Step 2（新增补强，已完成 ✅） |

---

## 当前不足与补强方向

这份清单原先偏重“删旧代码”，但近期问题表明，迁移前还需要明确几条行为门禁，否则迁到新 Runtime 后旧问题会被重新实现：

1. **状态分类不能把运行时限制当成用户输入**
   - `Credits exhausted` / `usage limit` 属于运行时限制，不是普通 `needAttention`。
   - 若限制信息前已有本轮交付性 `▪ ...` 输出，应保留 deliverable 并进入 `turnIdle` / 可继续状态。
   - 若没有任何交付性输出，才进入需要处理的运行时问题状态，文案也不应是 `Needs Input`。

2. **结果卡片和 TTS 必须逐步同源，但不得破坏当前功能效率**
   - 结果卡片、手动朗读、自动 TTS 最终应使用同一套 event-linked deliverable 数据契约。
   - 迁移分三层：轻量 candidate / evidence、异步 resolved summary、复用 resolved speech source。
   - `rawOutput` / `cleanedOutput` 只能作为 evidence 输入，不是结果卡片或 TTS 的最终内容。
   - 不再为了旧数据可读性保留 `task.summary` / `shortSummary` deliverable fallback。
   - 禁止从初始 prompt、旧 turn summary、running snapshot 或 reconnect snapshot 生成新的 latest result/TTS。

3. **UI 不应被 Runtime 事件抢占手势**
   - 结果出现、App resume、progress event 都不能强制切到产出 tab 或重置用户滚动。
   - 只有用户显式点击“查看结果/产出”时才切 tab。

4. **probe / refresh / reconcile 是状态校准，不是可删除的审计尾巴**
   - probe 可以发现远端新证据，但不能把旧 pane 残留重新归约为当前事件。
   - full capture 可用于审计、恢复和人工刷新；在自动刷新链路缺事件时，也可以作为轻量 reconcile 的输入。
   - 若要改变状态，必须经过 marker count、offset、event id 或 fingerprint 去重。

5. **Adapter 可以解析文本，但 parser 位置必须集中**
   - Codex / Qoder 仍是 TUI，文本 → 事件不可避免。
   - 问题不在“有解析”，而在解析分散在 SSH 脚本、Dart parser、summary fallback、UI/TTS 多处。
   - 迁移目标是：Adapter/Watcher 负责文本解析，Runtime reducer 负责状态归约，UI/TTS 只消费归约后的事件/状态/结果。

---

## 迁移收益

| 维度 | 迁移前 | 迁移后 |
|------|--------|--------|
| 状态权威 | 分散于 SSH 脚本 grep + Dart parser + `_extractStatus` 三处 | 先以 `RuntimeEventBus` → reducer 为主路径；parser / tmux 保留自动校准输入，直到功能等价后再收口 |
| 文本残留污染 | 旧 exit marker / approval prompt 可被误判为当前状态 | 增量证据原则：只在新增文本中触发状态 |
| 审批模型 | `String status`（`'pending'` / `'approved'`），无类型安全 | `ApprovalState` enum，编译期保证 |
| 断线恢复 | 重新 capture-pane 全量重解析 | `last_offset` / `last_event_id` 增量恢复 |
| TTS 播报源 | 可回退到 `task.summary` / 初始提示词 | 逐步迁移到 resolved speech summary / event-linked payload；raw output 仅作 evidence |
| App 职责 | 直接判断任务完成 | 过渡期负责桥接命令、事件和兼容校准；Runtime 覆盖完整后再收敛为状态归约主路径 |

---

## 执行顺序

> 注意：顺序 ≠ 旧 P0–P3 优先级。正确的迁移路径是从防御层向核心收敛。

```
Step 0: ⑫ 增量证据约束（新增保护网，不移除任何旧逻辑）
Step 1: ⑬ 结果/TTS 同源门禁（candidate evidence / resolved summary / speech source）
Step 2: ⑭ 运行时限制分类门禁（quota / usage limit）
Step 3: ⑩ P3  OutputSummaryProvider 重复检测
Step 4: ⑨ P2  _bridgeNotifyExecutionUpdate 轻量化
Step 5: ④+⑧ P2  _bridgeSyncTerminalStatus 适配层清理
Step 6: ⑥+⑤ P1  TerminalPrompt → NativeTerminalApproval 包装 → ApprovalRequest 移除
Step 7: ⑪ P1  AgentExecutionUpdate 字段迁移
Step 8: ③+① P0  observeOutput 去状态化 → _extractStatus 移除
Step 9: ⑦ P2  UI 消费 TaskStatus → WorkState
```

---

## 2026-06-20 核对结果与剩余计划

本节以当前代码和测试为准，覆盖下文较早的阶段性勾选。Phase 2.6 不再重复建设已经存在的异步解析、页面缓存或 Tab 隔离能力，也不在本阶段提前实现 Phase 3 的完整跨重启 deliverable 持久化。

| 切片 | 当前状态 | 代码证据 | Phase 2.6 剩余工作 |
|------|----------|----------|--------------------|
| A0 增量证据保护 | 已完成 | attach/probe 使用新增证据、exit marker count 和基线保护 | 保持回归测试，不再扩张 |
| A1 输出与播报同源 | **部分完成** | `TaskDeliverableSource` 已提供 candidate/evidence/resolve/provenance；结果页已有 `Isolate.run`、页面缓存和 in-flight 去重 | 结果页和 TTS 接入同一个 resolver/cache；移除 deliverable 场景的 `summary` / `shortSummary` fallback；发布 event-linked provenance |
| A2 Runtime issue 分类 | 已完成 | quota 前有 deliverable 与无 deliverable 已分流并有测试 | 补正常额度下真机用例，不调整分类语义 |
| A3 审批/终端交互 | 已完成 | `NativeTerminalApproval` + `ApprovalState` 为生产模型 | 保持 safe/balanced/aggressive 回归 |
| A4 Streaming 事件 | 已完成 | streaming 使用 `notifyOutputUpdated()`；`OUTPUT_UPDATED` 只走内存 EventBus，不写 SQLite | 保持高频事件 memory-only 回归 |
| A5 状态 reducer | **部分完成** | 显式 Runtime API 和 WorkState 已存在，但 AppState 仍通过 `_taskWithExecutionUpdate()` / `_bridgeSyncStreamStatus()` 归约部分状态 | 先补齐 Runtime 事件覆盖和一致性测试；不得为了删除 AppState 判断破坏自动刷新 |
| A6 Reconcile/Refresh | **部分完成** | exit marker count、probe baseline、fingerprint 类保护已存在；full capture 仍承担恢复输入 | 验证自动 reconcile 与手动刷新等价；watcher offset/event replay 完整化留到 Phase 3 |
| A7 UI 状态消费 | 主 UI 已迁移，fallback 保留 | 首页、详情、历史卡片优先读取 WorkState，仍保留 TaskStatus 低层/兼容分支 | A5/A6 完整前不删除 fallback；只清理被证明无调用者的重复映射 |
| E1 交互效率指标 | **未开始** | 目前只有通用 `MetricEvent` 和 bounded append | 增加 task/turn 级轻量字段与事件，不建设 workflow engine |

### 已具备、不得重复建设

- 结果摘要在规则 provider 下通过 `Isolate.run()` 后台执行。
- 结果页拥有有界内存缓存和相同 signature 的 in-flight 去重。
- 摘要工作在首帧后调度，`FutureBuilder` 异步展示。
- 高频 progress 不写任务 JSON、不触发全局 AppState rebuild。
- `OUTPUT_UPDATED` 是瞬时事件，不写入 SQLite；状态、审批和 deliverable 事件仍持久化。

### 修订后的执行顺序

1. **P0 行为基线冻结**：以 [Armin 核心行为与性能基线](core-behavior-performance-baseline.md) 为门禁，保留状态自动刷新、follow-up observer 连续性、Tab 可切换和高频事件 memory-only 测试。
2. **P1 A1 主路径接入**：让结果卡片、手动朗读和自动 TTS 复用同一个 `ResolvedDeliverable` resolver/cache；cache key 使用 turn id + evidence fingerprint + provider 配置。
3. **P2 移除 deliverable fallback**：只在新任务功能路径已稳定写入 turn/event evidence 后，移除结果/TTS 的 `task.summary` / `shortSummary` fallback；状态卡和时间线仍可使用状态摘要。
4. **P3 event-linked provenance**：发布 `DELIVERABLE_UPDATED` 时关联 turn id、evidence fingerprint 和 resolved summary identity。Phase 2.6 只要求当前运行期同源；完整 SQLite payload、App 重启恢复和 event replay 归 Phase 3。
5. **P4 A5/A6 一致性补齐**：按 safe → balanced → aggressive 验证 `TaskSession.status` 与 `WorkState.phase`；自动 reconcile 必须覆盖手动刷新可恢复的场景。
6. **P5 交互效率指标**：记录输入/摘要长度、追加/审批/重试次数、等待与验收耗时、接受/继续/拒绝/重做/完成动作；token 指标只记录可获得的数据，不引入模型基准平台。
7. **P6 最终验收**：正常 deliverable、quota、审批、断线/重连、多 turn 和 TTS 真机回归；确认任务运行与完成后 Tab、首帧和状态刷新无退化。

### 明确延后到 Phase 3

- resolved deliverable payload 的完整 SQLite 持久化与跨 App 重启恢复。
- watcher offset/event replay 替代 full capture 恢复。
- Loop Engine、日历触发、调度、自动恢复和长期任务自动化。

---

## Step 0: ⑫ 增量证据约束 — 必须先做

### 目标

给所有旧 parser / grep 加一道保护门：attach/reconnect 后，只有当前观察基线之后的新增文本才能触发状态变更。不移除任何旧逻辑，只加约束。

### 改动范围

- `SSHAgentSessionService._ExecutionOutputState`：增加 `baselineHash` / `hasNewDelta` 状态位
- `SSHAgentSessionService._buildStreamingUpdate()`：streaming 中 parser 结果只在有 delta 时传播
- `SSHAgentSessionService.execute()` 的 `whenComplete`：无新增 snapshot 时，`approval` / `terminalPrompt` 仅记日志不驱动 `needsAttention`

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| `hasNewDelta` 状态位未正确维护，pipe 流延迟导致误屏蔽合法新 prompt | 低 | 先在测试中验证 pipe 流的 delta 检测逻辑；`hasNewDelta` 使用 hash 比较而非时间戳 |
| `whenComplete` 中跳过 parser 导致合法 follow-up 的审批提示被静默 | 低 | 只有 `attachOnly && !hasNewDelta` 时才跳过，非 attach 模式不受影响 |

### 验证标准

- [x] `ssh_agent_session_service_test`：attach-only 初始 pane 有旧 exit marker / approval marker，无新增时不应触发 break
- [x] `armin_app_state_task_control_test`：follow-up 后服务端只返回旧 prompt 残留，task 不应变为 `needAttention`
- [x] `probeRemoteState`：首次看到旧 exit marker 只建立计数基线，不触发 refresh
- [x] 非 attach 模式行为不变（`flutter test` 全量回归）

---

## Step 1: ⑬ — 结果/TTS 同源门禁

### 目标

在继续迁移前，先固定“结果从哪里来、如何变成可读摘要”的行为契约，但不得以牺牲当前功能和性能为代价。Step 1 的目标不是一次性替换所有调用者，而是建立 event-linked deliverable 的 evidence → resolved summary 契约，并按场景逐步切换。

### Step 1a：冻结旧体验基线

先冻结当前功能体验，补齐行为基线：

- 任务完成后可以立即切换 Tab。
- 结果页首帧不被 summary、output slicing 或大日志处理阻塞。
- 多 turn 结果不串线。
- 没有当前 turn / event evidence 时，不伪造 deliverable。
- 手动朗读和自动 TTS 仍可用。
- reconnect / running snapshot 不生成 latest result。

### Step 1b：建立三层 deliverable 契约

- Candidate / Evidence Layer：只看 turn status / id / timestamp / length 选候选；真正需要解析时才读取 scoped raw / cleaned output 作为 evidence。evidence 不直接展示、不直接朗读。
- Resolved Summary Layer：异步执行 turn output slicing、prompt echo / thinking / CLI chrome 过滤和 `OutputSummaryProvider` 摘要生成，产物是 `displaySummary` / `speechSummary` / provenance。
- Speech Source Layer：优先复用 resolved `speechSummary`，没有时才读清洗后的 `displaySummary`；没有 resolved deliverable 时只能播明确状态提示或跳过，不能新造 latest result。

### Step 1c：区分 fallback 与权威来源

- 允许：当前 turn / event evidence 缺失时显示“暂无结果”或明确状态提示。
- 禁止：latest turn deliverable 从 `task.summary`、初始 prompt、旧 turn summary、running snapshot 或 reconnect snapshot 生成。
- 禁止：为了同源把结果卡片、TTS、diagnostics 绑到一个同步重解析入口。

### Step 1d：按场景逐步切换

切换顺序：

1. Diagnostics 使用新 source 记录 provenance。
2. 手动朗读使用 resolved `speechSummary` / `displaySummary`。
3. 自动 TTS 使用 resolved deliverable / event-linked payload。
4. 结果卡片迁移到 resolved `displaySummary`。
5. 历史结果列表最后迁移。

结果卡片和历史列表最敏感，必须最后迁移。只有真机确认不卡顿、Tab 可切换、TTS 不误播、多 turn 不串线后，才能继续删除旧逻辑。

### 当前实现状态

- 已建立 `TaskDeliverableSource` 作为 evidence → resolved summary 的基础服务，但尚未成为结果页和 TTS 的共享主路径。
- `TaskDetailScreen` 已具备后台 isolate、页面级有界缓存、in-flight 去重和首帧后调度；这些性能能力已经完成，不需要重建。
- `TaskDetailScreen` 仍保留 `_summaryOutputSource()`，相关 widget test 仍明确覆盖 task summary fallback。
- `TaskSpeechPolicy` 仍独立执行 turn slicing / summary，并保留 `_summarySource()`；因此自动 TTS 尚未复用结果页的 resolved deliverable/cache。
- `TaskDeliverableSource.resolve()` 已产出 turn id / turn index / evidence fingerprint provenance，但当前没有共享 cache，也没有 event-linked payload 持久化。
- Phase 2.6 只完成当前运行期 UI/TTS 同源与 provenance；完整 SQLite payload 和跨重启恢复延后到 Phase 3。

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 为了同源再次把 UI 首帧变成重解析路径 | 高 | Candidate Layer 必须保持同步轻量；resolved deliverable 只能异步运行 |
| 删除 `summary` fallback 后没有 turn evidence 的任务显示暂无结果 | 中 | 当前未发布应用，不为旧数据兜底；功能路径必须保证新任务写入 turn / event evidence |
| raw output 中含 TUI chrome，结果卡片出现噪声 | 中 | raw 只作为 source，仍交给 `OutputSummaryProvider` / `AgentOutputCleaner` 清洗 |
| TTS 播报长文本过长 | 低 | 当前策略保持旧行为；后续 speech summarizer 必须单独验收 |

### 验证标准

- [x] Candidate lookup 不切大输出。
- [x] resolved deliverable 请求时才做 turn output slicing。
- [x] running / needAttention turn 不进入 deliverable candidate。
- [ ] 结果页移除 deliverable 场景的 legacy summary fallback。
- [ ] 自动 TTS、手动朗读和结果卡片接入同一个 resolved deliverable/cache。
- [x] 结果页规则摘要使用后台 isolate，并具备页面级有界缓存与 in-flight 去重。
- [x] 高频 `OUTPUT_UPDATED` 不写 SQLite，运行后 Tab 可切换的模拟器审批场景已验证。
- [ ] 真机确认正常 deliverable 完成后不卡顿，Tab 可切换，结果页首帧不卡。

---

## Step 2: ⑭ — 运行时限制分类门禁

### 目标

`Credits exhausted` / `usage limit` / `quota exhausted` 不能一律进入 `needAttention`。运行时限制前若已有本轮 deliverable，应保留结果并进入可继续状态；没有 deliverable 时才提示用户处理运行时问题。

### 改动范围

- `NativeOutputObserver`：将 quota 判断拆成“有 deliverable”和“无 deliverable”两类
- `ArminAppState._taskWithExecutionUpdate()`：`turnIdle + done + deliverable` 写入 task summary / turn output，不再写入 `TaskResult`
- `OutputSummaryProvider`：继续过滤 quota 文案中的升级/用量提示，不把它当作结果主体

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 工具调用 `▪ Bash(...)` 被误认为 deliverable | 中 | deliverable 检测排除 `Read(...)` / `Write(...)` / `Edit(...)` / `Bash(...)` 等工具调用 |
| 真正需要用户充值/升级的任务被静默归为完成 | 中 | 只有 quota 前已有自然语言 deliverable 才归入 `turnIdle`；无 deliverable 仍需处理 |
| Qoder / Codex quota 文案不同 | 中 | quota pattern 统一放入 adapter/observer，后续迁到 Agent Adapter 专属配置 |

### 验证标准

- [x] `Credits exhausted` 跟在 `▪ 12 个测试全部通过...` 后面时，task 为 `turnIdle`，result 被写入
- [x] `Credits exhausted` 前无 deliverable 时，仍进入 needs-attention/runtime issue
- [x] 结果卡片和 TTS 播最终 deliverable，不播 `Credits exhausted` 作为主体

---

## Step 3: ⑩ P3 — OutputSummaryProvider 重复检测

### 目标

移除 `_removeTerminalPromptBlocks()` 中的硬编码字符串匹配，改为复用 `TerminalPromptParser` 的统一结构化识别。

### 改动范围

- `TerminalPromptParser`：新增 `stripPromptBlocks()`，统一负责审批/终端交互块剥离
- `OutputSummaryProvider._removeTerminalPromptBlocks()`：移除内部硬编码 prompt start / option / footer 规则，改为调用 `TerminalPromptParser.stripPromptBlocks()`

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 统一 parser 漏掉边缘 prompt 格式，摘要中出现审批文本 | 中 | 新 prompt 格式只补 `TerminalPromptParser`，摘要层不再复制规则 |
| 两个 parser（SSH 层 + OutputSummaryProvider）的 prompt 检测逻辑不一致 | 低 | 终端 prompt 检测统一使用 `TerminalPromptParser`，`_isTerminalPromptStart` 的硬编码字符串逐步迁移到 parser 规则 |

### 验证标准

- [x] 摘要输出中不再出现 `Permission Required`、`Apply this change?` 等终端交互文本
- [x] 正常输出（非 prompt 块）不被误过滤
- [x] `OutputSummaryProvider` 相关测试通过

---

## Step 4: ⑨ P2 — _bridgeNotifyExecutionUpdate 轻量化

### 目标

将 `_bridgeNotifyExecutionUpdate()` 从调用重型 `observeOutput()`（含 TaskWatcher 解析 + 状态推断 + 持久化）改为调用轻量 `notifyOutputUpdated()`。

### 改动范围

- `ArminAppState._bridgeNotifyExecutionUpdate()`：内部调用从 `bridgeRuntime.observeOutput()` 切换为 `bridgeRuntime.notifyOutputUpdated()`
- `BridgeRuntime.observeOutput()`：保留为 legacy observation API，但不再从 streaming / reconcile 生产路径调用

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| legacy `observeOutput()` 仍存在，后续新调用者可能误用它做状态推断 | 中 | 生产路径已切到 `notifyOutputUpdated()` / `RuntimeReconcileDecision`；后续 Step 8 再让 `observeOutput()` 去状态化 |
| `notifyOutputUpdated()` 不持久化，BridgeRuntime 内存中的输出进度在 App 重启后丢失 | 低 | Phase A 目标之一就是让 SQLite 成为持久化边界。当前 `TaskSession` 已通过 JSON 文件持久化，BridgeRuntime 的进度数据为辅助信息，丢失可接受 |

### 验证标准

- [x] streaming 路径每次 update 只发布 `outputUpdated` 事件，不触发状态变更事件
- [x] 状态变更仍由 `_taskWithExecutionUpdate()` 中的结构化字段驱动
- [x] `running` case 在 `_bridgeSyncTerminalStatus` 中的 `break` 随旧适配器移除

---

## Step 5: ④+⑧ P2 — _bridgeSyncTerminalStatus 适配层清理

### 目标

将 AppState 中的 `_bridgeSyncTerminalStatus()` 调用者逐个切换为直接调用 `bridgeRuntime.notifyXxx()`，并移除旧适配器方法。

### 改动范围

- `ArminAppState`：6 处 `_bridgeSyncTerminalStatus()` 调用点已逐一替换
- `_bridgeSyncTerminalStatus()`：全部调用者迁移后已移除

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 逐一切换过程中新旧状态同步路径不一致 | 中 | 每次只切换一个调用点，切换后验证该状态路径的 BridgeRuntime 事件是否正确发布 |
| `needAttention` / `turnIdle` 直接映射到 `WorkPhase` 时语义可能被压扁 | 中 | 切换前确认是否应映射为 `turnIdle`、`needsInstruction`、`needsReview` 或 `needsDecision`，禁止统一塞进单一 waiting 状态 |

### 验证标准

- [x] stream-side 状态变化调用点已切换为显式 Runtime API
- [x] 其余调用者切换后，对应状态路径的 RuntimeEvent 正确发布
- [x] `taskWaitingUser` / `taskCompleted` / `taskFailed` 事件与迁移前一致
- [x] 全部迁移后 `_bridgeSyncTerminalStatus()` 无调用者

---

## Step 6: ⑥+⑤ P1 — 审批模型迁移

### 目标

将 TerminalPrompt → ApprovalRequest 的包装链路替换为 `TerminalPrompt → NativeTerminalApproval`。历史任务已迁移后，`ApprovalRequest` / `ApprovalParser` 不再保留为兼容投影，审批状态只通过 `NativeTerminalApproval.state` / `ApprovalState` 表达。

### 改动范围

- `AgentExecutionUpdate`：新增 `nativeApproval`
- `SSHAgentSessionService`：streaming / settled update 同时产出 `nativeApproval`
- `BridgeRuntime.notifyApprovalRequested()`：接收 `NativeTerminalApproval` 并写入 `WorkState.approval`
- `TaskSession`：持久化 `nativeApproval` / `nativeApprovalRequests`
- `ArminAppState._taskWithExecutionUpdate()`：消费 `nativeApproval`
- `_ApprovalPromptCard`：原生消费 `NativeTerminalApproval`
- `TaskSpeechPolicy`：审批播报优先读取 `nativeApproval`
- `ApprovalRequest` / `ApprovalParser`：历史兼容外壳已移除

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 旧审批 JSON 已不再兼容 | 低 | 历史任务已完成 schema migration；后续不再写入旧字段 |
| UI `_ApprovalPromptCard` 与 runtime 状态显示不一致 | 低 | 详情页统一读取 `nativeApprovalRequests` / `nativeApproval` |

### 验证标准

- [x] 审批 prompt 在 safe / balanced / aggressive 三种模式下正确识别（现有 parser / app state 回归）
- [x] `ApprovalState` 状态机：pending → resolving → resolved/failed 完整流转（BridgeRuntime diagnostics + WorkState）
- [x] 审批历史 `nativeApprovalRequests` 正确记录
- [x] JSON 持久化往返无数据丢失（native 字段，`flutter test` 全量回归）
- [x] `TaskSession.nativeApproval` JSON 字段与 `_ApprovalPromptCard` 原生消费完成

---

## Step 7: ⑪ P1 — AgentExecutionUpdate 字段迁移

### 目标

`AgentExecutionUpdate` 中新增 `nativeApproval` 字段。生产路径产出 `nativeApproval`；旧 `approval` / `terminalPrompt` 字段已随历史 schema 清理移除。

### 改动范围

- `AgentExecutionUpdate`：新增 `nativeApproval`
- SSH 层 streaming / settled 构造点：产出 `nativeApproval`
- AppState：优先识别 `nativeApproval`，再回退旧 `approval` / `terminalPrompt`
- refresh / captured snapshot：从旧 parser 结果投影生成 `nativeApproval` 后再进入 AppState 归约

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 测试文件构造 `AgentExecutionUpdate` 时仍用旧字段 | 低 | 旧字段已删除，编译期阻止回归 |

### 验证标准

- [x] `flutter analyze` 0 error, 0 warning
- [x] SSH 生产路径 `AgentExecutionUpdate` 构造携带 `nativeApproval`
- [x] AppState 消费 native-only approval 并投影到当前任务模型
- [x] 核心测试中 native-only `AgentExecutionUpdate` 路径已覆盖
- [x] 旧 `approval` / `terminalPrompt` 字段不再是生产主路径；物理移除延后到历史 JSON schema 清理

---

## Step 8: ③+① P0 — observeOutput 去状态化 → _extractStatus 移除

### 目标

`observeOutput()` 改为纯数据记录，不再通过 `_extractStatus()` 驱动状态变更。`_extractStatus()` 最终标记 `@Deprecated` 并移除。

### 前置条件

- [x] Step 0 增量证据约束已落地
- [x] Step 1 evidence → resolved summary 契约已建立，结果卡片和 TTS 保持半迁移态
- [x] Step 2 运行时限制分类门禁已落地
- [x] Step 4 `_bridgeNotifyExecutionUpdate` 已切换到轻量路径
- [x] Step 5 reconcile 路径不再依赖 `observeOutput` 的状态变更
- [x] Step 6 审批路径已具备新模型主路径（旧字段/兼容投影已移除）

### 改动范围

- `BridgeRuntime.observeOutput()`：已移除 `_publish(_eventTypeForStatus(nextStatus), ...)` 状态驱动发布，仅保留数据记录和 `outputUpdated`
- `TaskWatcher._extractStatus()`：已移除，`TaskWatcherUpdate` 不再携带 `status`
- `TaskWatcher._extractAction()` / `_extractCheckpoint()`：保留为数据记录辅助功能

### 覆盖盲区验证

| 旧 grep 模式 | 新事件覆盖 | 状态 |
|-------------|-----------|:---:|
| `waiting for user` / `needs approval` / `need approval` / `waiting for your` | `taskWaitingUser` / `approvalRequested` | ✅ |
| `task completed` / `completed successfully` | `taskCompleted` | ✅ |
| `task failed` | `taskFailed` | ✅ |
| `fatal error` | 评估是否归入 `taskFailed` 或新增事件 | ⚠️ |

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 旧 `_extractStatus` 的 grep 覆盖了少数新 RuntimeEventBus 未建模的场景（如 `"fatal error"`） | 中 | 移除前逐个 grep 验证覆盖 |
| legacy `observeOutput` 不再负责状态，旧 grep 覆盖场景可能失去 fallback | 低 | 生产路径必须通过 `RuntimeEventBus` / `RuntimeReconcileDecision` 覆盖状态变化 |

### 验证标准

- [x] 所有旧 grep 模式在新 RuntimeEventBus 中有对应事件覆盖（`fatal error` 留在 observer/failure 分类回归中）
- [x] `observeOutput()` 调用不再产生 `taskProgress` / `taskWaitingUser` / `taskCompleted` / `taskFailed` 事件
- [x] `_extractStatus()` 无调用者后移除
- [x] 相关测试通过

---

## Step 9: ⑦ P2 — UI 消费 TaskStatus → WorkState

### 目标

UI 层不再直接 `switch (task.status)`，改为通过 `WorkState.phase` 判断展示内容。

### 前置条件

- [x] Step 5 `_bridgeSyncTerminalStatus` 已完成迁移，BridgeRuntime 的 `_workStates` 在状态变更时同步更新
- [x] Step 8 完成，TaskStatus 的状态变更路径唯一且正确

### 改动范围

- `task_detail_screen.dart`：`switch (task.status)` / `_isAttentionRequired(task.status)` → `workState(taskId).phase`
- `task_home_screen.dart`：Waiting For You / Running Summary / Activity Feed / task list labels → `WorkState.phase`
- `task_card.dart` / `task_history_screen.dart`：历史任务卡片状态 badge / progress label → `WorkState.phase`
- Current Situation 卡片：改为消费 `WorkState`
- 状态标签：`TaskStatusLabel.label` → `WorkPhase` 映射

### 当前 WorkPhase 映射缺口

```
TaskStatus                  WorkPhase
─────────                  ─────────
turnIdle        →          turnIdle
needAttention   →          needsInstruction / needsDecision / needsReview（按原因细分）
needApproval    →          needsApproval
running         →          working
completed       →          completed
failed          →          failed
stopped         →          stopped
```

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| `needAttention` 原因不明，UI 无法决定是继续、审批、查看还是恢复 | 中 | 迁移前先让 reducer 填充 `WorkState.detail` / `approval` / `phase`，UI 不再自行猜原因 |
| `WorkState` 只在 `BridgeRuntime._transition()` 和 `_updateWorkState()` 中更新，非终端状态路径可能未覆盖 | 低 | 在 Step 5 验证 `_bridgeSyncTerminalStatus` 的所有调用者都已在 BridgeRuntime 侧产生状态变更 |

### 验证标准

- [x] 首页 Waiting For You / Running Summary / Activity Feed 优先消费 `WorkState`
- [x] 历史任务卡片优先消费 `WorkState`
- [x] Task Detail 首屏状态标签 / Current Situation / What This Task Needs / 主按钮优先消费 `WorkState`
- [x] Current Situation 卡片显示内容与迁移前一致
- [x] 状态标签正确映射
- [x] 二级控制、调试、兼容 fallback 中残留的 `TaskStatus` 判断仅作为低层兼容分支，不再承载一等 UI 心智

---

## 风险总览

| Step | 核心风险 | 严重度 | 缓解措施 |
|------|---------|:---:|------|
| 0 | `hasNewDelta` 状态位维护错误 | 中 | hash 比较 + 测试覆盖 |
| 1 | 结果卡片和 TTS 再次分叉 | 高 | evidence → resolved summary 契约 + 分场景回归测试；禁止 UI 同步重解析 |
| 2 | quota / usage limit 再次被归为普通输入需求 | 高 | observer / adapter 先判 deliverable，再判 runtime issue |
| 3 | SSH 层预处理遗漏 prompt 格式 | 中 | 双 parser 并行运行，diff 验证 |
| 4 | legacy `observeOutput` 被新调用者误用 | 低 | 生产路径只用 `notifyOutputUpdated` 和 `RuntimeReconcileDecision` |
| 5 | 逐一切换时新旧同步不一致 | 中 | 每次仅切一个调用者，立即验证 |
| 6 | JSON 持久化旧审批数据丢失 | 中 | 新旧字段并行一个版本周期 |
| 7 | 测试文件旧字段残留 | 中 | 核心 fake agent 已迁 native-only；旧字段 fixture 只保留兼容覆盖 |
| 8 | 新事件未覆盖旧 grep 模式 | 中 | 逐个 grep 词验证覆盖 |
| 9 | `WorkPhase` 粒度不足 | 中 | 迁移前确认 `needsInstruction` / `needsDecision` / `needsReview` 映射 |

---

## 功能迁移计划

迁移按“功能垂直切片”推进，而不是按文件批量替换。每个切片完成后都必须能独立通过测试，并且旧路径只作为 fallback 存在。

| 阶段 | 功能切片 | 当前旧路径 | 目标新路径 | 完成标准 |
|------|----------|------------|------------|----------|
| A0 | 状态触发保护网 | SSH grep / full capture 直接触发状态 | 增量证据、marker count、fingerprint 去重 | 旧 prompt / 旧 exit marker 不能触发 `needAttention` / `turnIdle` |
| A1 | 输出与播报同源 | 结果卡片、TTS 仍分散解析，且保留 summary fallback | event-linked evidence / shared resolved summary cache / speech source | 后续 turn 结果、TTS、手动朗读一致，raw output 只作 evidence |
| A2 | Runtime issue 分类 | `Credits exhausted` → `needAttention` | deliverable 优先，runtime issue 次之 | 有结果时显示结果，无结果时提示运行时问题 |
| A3 | 审批/终端交互 | `TerminalPrompt` → `ApprovalRequest` String 状态 | `TerminalPrompt` → `NativeTerminalApproval` + `ApprovalState` | Runtime/WorkState、审批卡、历史、JSON 已纵切，旧模型已移除 |
| A4 | Streaming 事件 | `_bridgeNotifyExecutionUpdate` → `observeOutput` | `notifyOutputUpdated` 轻量事件 | progress 不触发状态归约，不引发全局重建 |
| A5 | 状态 reducer | `_bridgeSyncTerminalStatus` + `TaskStatus` 写入 | RuntimeEventBus → reducer → WorkState | AppState 只发 command，不猜状态 |
| A6 | Reconcile/Refresh | full capture 重新推断状态 | `RuntimeReconcileDecision` + 增量补齐 | refresh 只校准新证据，不复活旧 pane 残留 |
| A7 | UI 状态消费 | UI 直接 `switch (TaskStatus)` | UI 读取 `WorkState.phase/detail` | 首页、详情、TTS 不再直接消费 raw terminal state |

### 推荐执行节奏

1. **先冻结行为契约**：保留 Step 0–2 的测试，不允许迁移中改回旧行为。
2. **先迁移输出类功能，再迁移状态类功能**：结果/TTS 的错源问题最容易影响用户感知，且能作为后续 reducer 的验收样本。
3. **审批模型已经纵切到 native 主路径**：不要重新引入 `ApprovalRequest` / `ApprovalParser`；审批状态只通过 `NativeTerminalApproval.state` / `ApprovalState` 表达。
4. **observeOutput 去状态化前先切 streaming**：确保高频路径不再依赖 `TaskWatcher._extractStatus()`，再处理 reconcile 路径。
5. **UI 最后迁移**：等 WorkState 覆盖所有语义后再替换 UI，否则会把状态缺口转移到页面 helper。

### 每个切片的最小验收集

- `flutter analyze` 对改动文件无 error / warning。
- 该切片的单元测试 + 至少一个 AppState 级测试。
- 若影响 UI，增加 widget 测试覆盖首页或详情页。
- 若影响 TTS，断言实际 `TaskSpeechDecision.text`，不能只断言 `shouldSpeak`。
- 若影响 result，必须覆盖“后续 turn + legacy summary 不参与 + 最新 `▪` deliverable”的真实形态。

---

## 半迁移态一致性保障

每次 Step 完成后必须验证两条路径输出一致：

```
旧路径（仍运行）              新路径（正在切换）
══════════════                ══════════════
SSH script grep              RuntimeEventBus event
↓                            ↓
AgentExecutionUpdate          bridgeRuntime.notifyXxx()
↓                            ↓
_taskWithExecutionUpdate      _workStates[taskId]
↓                            ↓
TaskSession.status           WorkState.phase
```

验证方式：在 Step 完成后，选取一个典型任务（safe → balanced → aggressive 各一个），对比旧路径的 `TaskStatus` 与新路径的 `WorkPhase` 在相同输入下是否一致。对不应一致的场景（例如 quota 后已有 deliverable），以新行为门禁为准，旧路径只能作为兼容 fallback。

---

## 移除验证标准

每个旧逻辑的移除必须满足：

1. ✅ 新 RuntimeEventBus 事件流已覆盖该场景
2. ✅ 相关测试在移除后仍然通过
3. ✅ Flutter analyze 0 error
4. ✅ 旧逻辑已无调用者（或调用者已迁移）

---

## 当前共存状态

Phase 2.5 目前处于新旧逻辑的**过渡共存**：

```
新逻辑                          旧逻辑
══════════                      ══════════
RuntimeEventBus (25 events)     TaskWatcher._extractStatus()
bridgeRuntime.notifyXxx()       _bridgeSyncTerminalStatus()（已移除）
ApprovalState enum              ApprovalRequest.status（已移除）
WorkState（UI 语义投影）        TaskStatus（当前可操作状态数据面）
NativeTerminalApproval          TerminalPrompt → NativeTerminalApproval
```

审批和主要 UI 语义已经迁移到 RuntimeEventBus / WorkState / NativeTerminalApproval；`TaskStatus` 与 AppState reducer 仍承担当前可操作状态和兼容校准，不能描述成已经完成的二级 fallback。审批兼容外壳已物理移除；后续不能重新引入 prompt 污染、提前 `turnIdle`、旧结果播报等问题。测试数量不固定，以当前分支 `flutter test` 结果为准。
