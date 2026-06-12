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

## 第三阶段

- Runtime 持久化边界收敛到 SQLite：任务、turn、runtime event、work state、approval state、session binding、watcher offset 和 deliverable 可恢复
- Flutter 内 Bridge Runtime 作为过渡实现，支持 App 重启后的状态重建
- 断线/重连后的 watcher offset 与 event replay，避免通过完整 `capture-pane` 重新猜测状态
- `tmux capture-pane` 降级为观察输入，不再作为 turn 完成、结果可见或审批已解决的权威信号
- 历史任务延续
- 任务级上下文延续
- 手动子任务组织
- 委托质量和注意力成本指标
- 可搜索/可导出的审计历史

## 第四阶段

- 远端 Bridge Runtime daemon 探索：在远端机器持有 watcher、event reducer 和 SQLite store，Mobile App 只作为查看和控制客户端
- 模块级工作器
- 手动任务关系整理，不做 fork/join runtime
- 扩展更多终端 Agent adapter
- 冲突风险展示，不进行自动冲突合并
