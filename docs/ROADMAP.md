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

### 最小交付边界

当前 Phase 2 代码收口以真实执行主链路可供人工验收为边界：

- 保持真实 `DeviceVoiceService` 与 `SSHAgentSessionService`，mock 仅用于测试。
- Host 使用 password 认证并通过安全存储加载；普通历史不保存密码明文。
- 每个任务使用独立 tmux session；`turnIdle` 保留 session，用户终止或确认终态后才 final capture 并 cleanup。
- 文本/语音追加、停止、完成、恢复与重连动作均可从任务详情操作，语音输入进入脱敏审计。
- 输出展示与 TTS 使用清洗/脱敏摘要；端侧小模型 runner、中英文语音品质调优不作为本次最低可验收门槛。

### 人工验收清单

在 Android 真机和已配置 password 的真实 Host 上执行一次低风险任务：

1. 从首页语音或任务页创建任务，选择 Host 与 project path，确认 Agent 能在目标目录启动。
2. 等待任务进入“等待继续”，在电脑侧通过 `tmux attach -t {session}` 确认 session 仍存在且输出与 App 一致。
3. 分别发送一次文本追加和一次语音追加，确认追加进入同一 tmux session，且 App 时间线保留交互轮次。
4. 点击“断开监听”再“重新监听”，确认远端 session 不被误杀、手机可以继续看到输出。
5. 选择“标记完成”或“停止”，确认详情页保存最终日志，电脑侧 `tmux list-sessions` 不再保留对应任务 session。

若任一步失败，记录任务详情的 Raw Log、Host/Agent 配置、tmux session 名和电脑端 capture 输出，作为下一轮修复输入。

## 第三阶段

- 历史任务延续和 Agent resume 能力
- 手动子任务组织
- 委托质量指标仪表板
- 可搜索/可导出的审计历史

## 第四阶段

- 模块级工作器
- 粗略的 fork/join 任务组织
- 扩展更多终端 Agent adapter
- 冲突风险展示，不进行自动冲突合并
