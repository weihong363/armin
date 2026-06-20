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
- Host、project path 与 JSON 历史存储；password 使用平台安全存储
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

不新增复杂工作流，也不引入多 Agent 编排。Phase 2.6 的收口目标不是“为了合并而合并”，而是在不破坏现有交互体验的前提下，把 Phase 2.5 的任务执行主链路逐步迁移为可度量、可复盘的单任务循环。

迁移执行步骤、半迁移态约束和验收标准统一维护在 [legacy-cleanup-checklist.md](runtime/legacy-cleanup-checklist.md)。Roadmap 只记录方向：RuntimeEventBus + WorkState 逐步成为状态、审批、结果和 TTS 的主路径；parser / tmux capture 在 Runtime 覆盖完整前仍保留为 observation input、自动 reconcile fallback 和审计恢复输入，而不是为了迁移被提前删除。deliverable 继续向 event-linked evidence → resolved summary 演进，任何迁移都不能牺牲任务完成后的自动状态刷新、Tab 切换、结果页首帧、手动朗读和自动 TTS。

当前实现已经具备共享的运行期 `ResolvedDeliverable` resolver/cache：结果卡片、手动朗读和自动 TTS 复用同一来源，规则摘要在后台 isolate 执行，并保留页面级有界缓存、in-flight 去重、首帧后调度和高频 `OUTPUT_UPDATED` memory-only 分发。Phase 2.6 不重复建设这些能力；下一步只在正常 deliverable 真机链路稳定后移除 legacy summary fallback，再补齐 event-linked provenance、Runtime/WorkState 与自动 reconcile 的一致性验收。完整 deliverable SQLite payload、跨重启恢复和 watcher event replay 归入 Phase 3。

所有阶段的核心功能变更统一受 [Armin 核心行为与性能基线](runtime/core-behavior-performance-baseline.md) 约束。状态自动刷新、任务控制、审批、每 turn 结果、朗读同源、Tab 响应、高频输出成本和有界数据增长均属于不可因迁移、重构或架构升级而退化的能力；不满足基线的实现必须暂停并重新评估，而不是继续推进或清理旧路径。

交互效率评估继续记录：

- 记录轻量效率指标：用户输入长度、输出摘要长度、追加次数、审批次数、重试次数、用户等待时间和任务到可验收结果的耗时
- 记录结果符合预期程度：用户是否接受结果、是否继续补充、是否拒绝/重做、是否标记完成
- 观察 token 消耗和有效产出之间的关系，避免为了更长输出牺牲用户每次交互效率
- 引入轻量 Loop Engineering 视角：Plan → Execute → Observe → Evaluate → Adjust → Verify，但只用于任务级评估和提示改进，不做通用 workflow engine

## 第三阶段

Phase 3 的优先级不变，核心是 “Loops > Prompts”：Loop Engine、日历触发执行、任务调度、任务恢复与 resume、审批工作流、自动摘要、长任务管理、结果追踪和通知。

- Runtime 持久化边界收敛到 SQLite：任务、turn、runtime event、work state、approval state、session binding、watcher offset 和 deliverable 可恢复
- Flutter 内 Bridge Runtime 作为过渡实现，支持 App 重启后的状态重建
- 断线/重连后的 watcher offset 与 event replay，避免通过完整 `capture-pane` 重新猜测状态
- `tmux capture-pane` 长期降级为观察输入，不再作为 turn 完成、结果可见或审批已解决的唯一权威；Phase 2.6 过渡期仍保留为自动 reconcile 输入，直到 Runtime event / watcher offset 覆盖迁移前能力
- 历史任务延续
- 任务级上下文延续
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
