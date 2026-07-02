# 路线图

## 第一阶段

- 模拟语音输入和语音摘要
- 任务草稿、可编辑确认、上下文、约束、密钥和提示预览
- 完整的内存本地历史
- 提示模板构建器
- 结果和批准标记的解析器层
- 秘密信息脱敏
- 指标事件模型和时间线占位符
- 模拟代理流程，涵盖运行、需要批准、完成和失败状态

## 第二阶段：真实交互链路与稳定化（当前）

已落地：

- 真实 SSH/password 与 tmux 会话实现
- 真实 STT/TTS 集成和按住说话
- Host、project path 与 SQLite 任务历史；password 使用平台安全存储
- Codex CLI / Qoder CLI 的可配置真实执行
- 每任务短 tmux session、原生输出清洗观察与 `turnIdle` 状态
- legacy 结构化结果仅保留为摘要输入，不再自动完成任务或清理 session
- 文本/语音追加、停止、暂停/恢复、断开/重连监听、用户确认终态
- 暂停取消当前 observer，恢复重新监听同一任务 session
- 追加面板中的基础语义语音动作：继续、停止、完成、恢复与约束提取
- 运行中语音追加与语音控制输入写入脱敏历史，保留语义审计链路
- Prompt Context Chunking：将任务原话、约束、上下文和 secret 占位符分块，避免长上下文导致核心语义丢失
- 端侧摘要实验开关、runner 接口、能力检测、模型输入脱敏、摘要脱敏和规则 fallback
- `RuntimePolicy` 统一安静检测、最大运行时长和 capture 窗口；终态先保存 final capture 再清理 session
- cleanup 失败会写入任务提示，终态任务可手动重试清理远端 session
- SSH 网络中断保留远端 session 并进入可重新监听状态
- 终态任务可从原 Host/project path 新建重跑草稿；活跃交互任务不会重复启动 session

正在收口：

- 手机与真实主机的完整端到端回归和 runtime cleanup 验证
- 用户语义语音动作的真机验收、短语扩展与历史审计完善
- 结果摘要、自动/手动朗读、中断播报与中英文 TTS 质量
- reconnect 异常的真机验收与更完整的历史任务延续策略
- 接入实际 Android 端侧小模型 runner 与模型分发：只提炼已清洗输出用于展示/TTS，不执行代码任务

已收口：

- 活跃任务数量限制（默认 5）：超限时阻止创建新任务，首页显示活跃计数
- 终端状态统一：`runtimeLost` 归类为终端状态，不再被 reconcile 探测或 bridge 跟踪
- 任务删除范围扩展：`stopped` 和 `runtimeLost` 可删除
- Reconcile 回退机制：连续 6 次 sessionMissing 后自动排除，避免无效 SSH 探测
- 历史任务统计修正：入口显示全部任务数

### Phase 2 收口 Goals

- Goal A（已完成）：多 turn 输出 + TTS 收口。确保结果卡片与时间线按 turn 隔离输出、倒序展示；小喇叭只朗读当前 turn 的清洗后连贯内容；TTS 去除工具噪音和异常空格。
- Goal B（真机验收已通过，保留回归清单）：真实设备 Phase 2 回归验收。Codex/Qoder 各跑一个真实任务，覆盖追加、暂停、断开监听、恢复、停止、标记完成。
- Goal C（已具备接入口）：端侧摘要 runner 设计与接入口。只做接口和 fallback，不立刻塞模型进主流程。
- Goal D（已完成基础闭环）：语音命令层。统一处理继续、停止、标记完成、朗读结果、追加指令等工作语义命令。

### 最小交付边界

当前 Phase 2 代码收口以真实执行主链路可供人工验收为边界：

- 保持真实 `DeviceVoiceService` 与 `SSHAgentSessionService`，mock 仅用于测试。
- Host 使用 password 认证并通过安全存储加载；普通历史不保存密码明文。
- 每个任务使用独立 tmux session；`turnIdle` 保留 session，用户终止或确认终态后才 final capture 并 cleanup。
- 文本/语音追加、停止、完成、恢复与重连动作均可从任务详情操作，语音输入进入脱敏审计。
- Prompt 使用本地规则 chunking 保留用户任务原话和约束；不引入向量数据库、embedding 或自动仓库扫描。
- 输出展示与 TTS 使用清洗/脱敏摘要；端侧小模型 runner、中英文语音品质调优不作为本次最低可验收门槛。

### 人工验收清单

Phase 2 RC 的验收记录、已知限制和发版前检查见 [PHASE2-RC.md](PHASE2-RC.md)。

在 Android 真机和已配置 password 的真实 Host 上执行一次低风险任务：

1. 从首页语音或任务页创建任务，选择 Host 与 project path，确认 Agent 能在目标目录启动。
2. 等待任务进入“等待继续”，在电脑侧通过 `tmux attach -t {session}` 确认 session 仍存在且输出与 App 一致。
3. 分别发送一次文本追加和一次语音追加，确认追加进入同一 tmux session，且 App 时间线保留交互轮次。
4. 点击“断开监听”再“重新监听”，确认远端 session 不被误杀、手机可以继续看到输出。
5. 选择“标记完成”或“停止”，确认详情页保存最终日志，电脑侧 `tmux list-sessions` 不再保留对应任务 session。

若任一步失败，记录任务详情的 Raw Log、Host/Agent 配置、tmux session 名和电脑端 capture 输出，作为下一轮修复输入。

### Phase 2.5：认知与使用行为验证

不优先做复杂多 Agent、完整 Task Call、长期记忆或通用工作平台。先验证 Agent 使用者是否存在管理成本问题。

Phase 2.5 的优先级不变，继续围绕可用性和可靠性收口：ASR 准确率、中英文混合语音输入、原生 TTS 质量、长时间 tmux session 可靠性、Bridge state 同步、token 使用监控，以及面向长任务编排的 Runtime Brain。

记录和观察以下指标：

- 每日创建任务数
- 并行活跃任务数
- 用户离开电脑后的查看次数
- 文本/语音追加次数
- 暂停、恢复、停止、标记完成次数
- 任务进入等待继续后的用户响应时间
- 用户是否从“盯着 Agent”转向“委派任务后离开”

Survey / 社区验证方向：

- Codex / Claude Code / Cursor Agent 用户多久查看一次 Agent 状态？
- 执行期间是在等待、继续工作、刷网页，还是离开电脑？
- 一天会同时运行几个 Agent 任务？
- 最烦的是等待、审批、查看状态、补充指令、上下文丢失，还是结果不可读？
- 如果 Agent 需要你时主动通知，而不是你主动查看，你是否愿意？

### Phase 2.6：Runtime 收口与交互效率评估

不新增复杂工作流，也不引入多 Agent 编排。Phase 2.6 直接把 Phase 2.5 的任务执行主链路收口为可度量、可复盘的单任务循环；功能和性能由全阶段基线保证，出现回归时回滚版本，不并行维护旧实现。

当前状态：Phase 2.6 迁移收口和自动化门禁已经完成。Runtime 状态串行提交、event-linked deliverable、WorkState 当前审批来源、结果/TTS fallback 移除、semantic settled 收敛、TTS 单次自动播报和高频输出节流均已落地；`ARMIN_DIAG` 仅保留启动指纹和异常路径诊断。后续变更必须继续以核心行为与性能基线作为门禁，不能重新引入旧数据兼容 fallback 或新旧双线并行。

迁移执行步骤和验收标准统一维护在 [legacy-cleanup-checklist.md](runtime/legacy-cleanup-checklist.md)。RuntimeEventBus + WorkState 是状态、审批和结果事件的主路径；parser / tmux capture 只提供当前观察窗口的新证据和 reconcile 输入，不形成第二套状态或结果路径。

当前结果卡片、手动朗读和自动 TTS 只使用持久化的 current-turn `TurnDeliverable`；没有 evidence 时不从 `summary` / `shortSummary` 补造结果。`DELIVERABLE_UPDATED` 在结果持久化后发布并携带 turn id 与 evidence fingerprint，高频 `OUTPUT_UPDATED` 经过节流且只在内存分发。Watcher event replay 归入 Phase 3。

真实 qodercli 验收状态：`emulator-5554` 已完成真实 `$HOME/.local/bin/qodercli` smoke、项目简介、final sync、同 session Turn 2 和长任务/回归抽样验证。已确认远端最终输出返回后 Armin 可自动进入 `turnIdle`，结果卡片来自最新 turn，不需要手动刷新即可继续输入下一轮；自动 TTS 绑定 fresh deliverable，一轮新结果只触发一次，重复事件和重进详情不重播旧结果。

所有阶段的核心功能变更统一受 [Armin 核心行为与性能基线](runtime/core-behavior-performance-baseline.md) 约束。状态自动刷新、任务控制、审批、每 turn 结果、朗读同源、Tab 响应、高频输出成本和有界数据增长均属于不可因迁移、重构或架构升级而退化的能力；不满足基线的实现必须暂停并重新评估，而不是继续推进或清理旧路径。

交互效率评估继续记录：

- 记录轻量效率指标：用户输入长度、输出摘要长度、追加次数、审批次数、重试次数、用户等待时间和任务到可验收结果的耗时
- 记录结果符合预期程度：用户是否接受结果、是否继续补充、是否拒绝/重做、是否标记完成
- 观察 token 消耗和有效产出之间的关系，避免为了更长输出牺牲用户每次交互效率
- 引入轻量 Loop Engineering 视角：Plan → Execute → Observe → Evaluate → Adjust → Verify，但只用于任务级评估和提示改进，不做通用 workflow engine

### Phase 2.7：任务体验修整与真实长任务验收

Phase 2.7 不新增 Runtime 架构、不引入多 Agent 编排、不提前实现 Phase 3 Loop Engine。目标是在 Phase 2.6 已收口的单任务主链路上，打磨真实使用中的结果可读性、状态一致性、TTS 体验和长任务观察体验。

当前状态：Phase 2.7 的核心体验修整已经完成一轮可验收收口。真实 qodercli 路径覆盖了短任务 smoke、项目简介、Turn 2 连续输入和长任务抽样；自动化覆盖了 Runtime Gate、结果/TTS 去重、Tab 响应和 AppState 状态控制。后续同类问题应作为回归处理，而不是重新拆出迁移分支。

低成本 Agent 或外部执行者跑回归时，必须使用 [低可靠 Agent 验收模板](runtime/low-reliability-agent-verification-template.md)。模板固定 `emulator-5554`、真实 qodercli、禁止改配置、禁止把 `qodercli-test` 当真实验收，并要求输出结构化 JSON 报告。

优先级：

1. 结果卡片完整性：结果卡片必须完整呈现 latest turn deliverable 的关键内容，不丢首段、尾段或最终结论；不得混入 prompt echo、thinking、TUI chrome、旧 turn 或 reconnect snapshot。
2. 状态展示一致性：任务列表卡片、详情状态卡、动态 timeline、结果页和底部操作区必须消费同一任务状态语义；`running`、`turnIdle`、`needApproval`、`paused`、`userCompleted`、`userFailed` 不得互相矛盾。
3. TTS 自动播报体验：自动 TTS 只在本轮新 deliverable 首次生成时播报一次；进入详情页、切 Tab、手动刷新、重连或恢复旧任务不得重播旧结果。手动朗读继续使用同一 latest turn deliverable source。
4. 长任务观察体验：真实 qodercli / aggressive 模式下，3-5 分钟任务执行期间不得提前进入 waiting；完成后无需手动刷新即可继续输入下一轮；动态页展示有意义进展但不被 spinner / thinking 高频刷屏污染。
5. UI 性能门禁：任何展示完整结果、状态统一或 TTS 调整都不得牺牲 Tab 响应和任务控制可用性；不得把 summary、TTS 清洗或全文扫描放回同步 UI 路径。

Phase 2.7 验收门禁：

- P27-R01：结果卡片完整显示 latest turn deliverable，包含最终输出关键段落。
- P27-R02：多 turn 结果不串轮，Turn 2/3 不显示旧 turn 结果。
- P27-S01：列表、详情、timeline、结果页和操作区状态一致。
- P27-S02：完成后无需手动刷新即可继续输入下一轮。
- P27-TTS01：自动 TTS 每个 turn 的新结果只播报一次。
- P27-TTS02：进入详情页、重连、切 Tab 或手动刷新不重播旧结果。
- P27-LT01：真实 qodercli 长任务 3-5 分钟内不提前 waiting，完成后自动收敛。
- P27-PERF01：动态 / 产出 / 高级 Tab 连续切换无明显卡顿，无 ANR。

用户路径验收已经按以下主链路收口：

1. 新建任务：选择真实 host、项目和 qodercli 后，任务进入 `running`，任务列表、详情状态卡、timeline 和操作区显示一致。
2. 执行中：远端仍在工作时 Armin 保持 `running` / `needApproval` / `needAttention` 等真实状态，不因 prompt echo、thinking、pane 静默或 reconnect snapshot 提前进入 waiting。
3. 结果生成：当前 turn 出现有效 evidence 后异步生成 `TurnDeliverable`，结果卡片显示最新 turn 的 display summary，自动 TTS 只在 fresh deliverable 首次出现时播报一次。
4. 继续输入：`turnIdle` 表示本轮等待用户继续，不等于任务完成；用户可直接发送 Turn 2，复用同一 `armin-*` session，Turn 2 结果不得显示 Turn 1 的 deliverable。
5. 用户收尾：标记完成、标记失败、停止、暂停/恢复、断开/重新监听均保留既有任务控制语义；终态 cleanup 不影响已持久化结果。

长任务体验基线：

- 长任务执行期间，首页和详情页都必须优先表达“远端仍在运行”，不能为了更快显示结果而提前进入 waiting。
- 动态页可以展示原始 timeline、thinking 和 TUI chrome 作为审计信息，但结果卡片和 TTS 只能消费 resolved `TurnDeliverable`。
- 完成后应在无需手动刷新的情况下自动收敛到 `turnIdle`，并允许继续输入下一轮。
- 结果摘要、TTS 清洗和全文扫描不得进入同步 UI 路径；Tab 切换和任务控制响应优先级高于展示更长原文。

## 第三阶段

Phase 3 的优先级不变，核心是 “Loops > Prompts”：Loop Engine、日历触发执行、任务调度、任务恢复与 resume、审批工作流、自动摘要、长任务管理、结果追踪和通知。

Phase 3 起步必须遵守 [Phase 3 Loop Runtime 前置设计](runtime/phase-3-loop-runtime-prep.md)：先做单任务 Loop Runtime 的事实记录、下一步建议和恢复能力，不直接进入多 Agent 调度、通用 workflow engine 或完整 scheduler。

- Runtime 持久化边界收敛到 SQLite：任务、turn、runtime event、work state、approval state、session binding、watcher offset 和 deliverable 可恢复
- Flutter 内 Bridge Runtime 作为过渡实现，支持 App 重启后的状态重建
- 断线/重连后的 watcher offset 与 event replay，避免通过完整 `capture-pane` 重新猜测状态
- `tmux capture-pane` 长期降级为观察输入，不再作为 turn 完成、结果可见或审批已解决的唯一权威；Phase 2.6 过渡期仍保留为自动 reconcile 输入，直到 Runtime event / watcher offset 覆盖迁移前能力
- 历史任务延续
- 任务级上下文延续
- Loop 事实记录：输入长度、输出摘要长度、等待时间、审批次数、重试次数、用户后续动作
- 下一步建议：继续、验收、重做、补充上下文、标记完成/失败
- 手动子任务组织
- 委托质量和注意力成本指标
- token 消耗、结果符合预期程度和用户返工次数的综合评估
- 基于历史任务循环反馈优化下一次任务提示和上下文组织
- 可搜索/可导出的审计历史

## Phase 4+（未来）

Phase 4+ 用于记录长期架构方向，不改变 Phase 2.5 和 Phase 3 的开发优先级。用户采纳和任务完成率比基础设施复杂度更重要；在实现安全远端执行器前，Armin 必须先验证用户会稳定使用语音任务创建、采用 Loop-based 工作流、运行长生命周期编码任务，并确实需要多设备远程访问。

### Secure Remote Executor Infrastructure

目标：为运行在用户自有机器上的 Codex、Claude Code 或其他编码 Agent 提供安全远程访问能力。

潜在能力：

- Executor Identity
- Device Authentication
- 基于 Noise 的端到端加密
- Authenticated Relay Channels
- Permission Profiles
- Audit Logs
- Multi-Device Synchronization
- Multi-Executor Routing
- Secure Session Management

示例架构：

```text
Mobile App
↓
Encrypted Relay
↓
Executor
↓
Codex / Claude Code / Other Agents
```

Relay 应被视为不可信组件。长期上，所有敏感通信都应由 Mobile App 与 Executor 之间的端到端加密保护。

### Session Manager Daemon

在远端部署独立 Go 后台 daemon 管理 terminal session 生命周期，Armin 不再直接操作 tmux。设计决策记录见 [Session Manager Daemon 设计](runtime/session-manager-daemon.md)。

优先级排序：

1. **attach + kill**（最高优先级）：WebSocket 实时输出流替代 `pipe-pane` + `capture-pane` 轮询；可靠清理 + 自动 GC 杜绝残留 session。
2. **create / send / probe / list**（完整替换）：逐步替换 SSH shell 脚本生成逻辑。
3. **自建 PTY 管理**（可选终极方案）：完全替代 tmux，实现终端复用器选型自由。

### 其他未来方向

- 远端 Bridge Runtime daemon 探索：在远端机器持有 watcher、event reducer 和 SQLite store，Mobile App 只作为查看和控制客户端
- 模块级工作器
- 手动任务关系整理，不做 fork/join runtime
- 扩展更多终端 Agent adapter
- 冲突风险展示，不进行自动冲突合并
