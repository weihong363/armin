# Phase 3 Loop Runtime 前置设计

Phase 3 的目标是把 Armin 从“可靠执行单个任务”推进到“围绕单任务循环持续推进长任务”。这不是多 Agent 编排，也不是通用 workflow engine。Phase 3 的第一步应复用 Phase 2.6/2.7 已验证的 RuntimeEventBus、WorkState、ApprovalState、TurnDeliverable 和真实 qodercli 主链路。

## 最小闭环

Phase 3 的最小 Loop Runtime 只处理单任务内的循环：

```text
Plan -> Execute -> Observe -> Evaluate -> Adjust -> Verify
```

每一步的产品含义：

- Plan：把用户输入整理成当前 turn 的目标、约束和验收信号。
- Execute：通过现有 SSH/tmux/qodercli/codex 路径执行，不替代 Agent 推理。
- Observe：继续由 RuntimeEventBus、WorkState 和 current-turn evidence 观察状态、审批和结果。
- Evaluate：记录本轮结果是否可验收、等待时间、追加次数、审批次数、结果长度和返工信号。
- Adjust：给下一轮生成更短、更聚焦的上下文建议或 follow-up 草稿。
- Verify：由用户确认完成、继续、拒绝/重做或标记失败。

## Phase 3 起步范围

第一批只做单任务 Loop Runtime 的可恢复事实记录和下一步建议：

1. Loop 事实记录：每个 turn 记录输入长度、输出摘要长度、等待时间、审批次数、重试次数、结果是否存在、用户后续动作。
2. Loop 状态视图：在任务详情中展示当前任务处于“执行中、等待审批、等待用户继续、需要验证、已由用户收尾”等阶段。
3. 下一步建议：基于最新 `TurnDeliverable` 和用户动作，给出继续、验收、重做、补充上下文、标记完成/失败等有限选项。
4. 恢复能力：App 重启后从 SQLite 恢复 task、turn、runtime event、work state、approval 和 deliverable，不从旧 pane 重新猜结果。
5. 通知入口：只在长任务需要用户动作、产生 fresh deliverable 或运行时丢失时通知；不把每个 output chunk 变成通知。

## 复用现有主路径

Phase 3 不重新设计执行链路：

- 状态：继续以 `WorkState` / `TaskStatus` 的归约结果为 UI 语义来源。
- 审批：继续以当前 `WorkState.approval` 为唯一可操作审批来源。
- 结果：继续以 latest turn `TurnDeliverable` 为结果卡片、手动朗读和自动 TTS 来源。
- 输出：`rawOutput` / `cleanedOutput` 仍只作为 resolver evidence 和审计历史，不直接驱动产品结果。
- 事件：继续通过 RuntimeEventBus 发布提交后的结构化事件；需要恢复的事实写入 SQLite。
- reconcile：tmux capture 仍是观察输入和 fallback，不是状态或结果权威。

## 不做的事

Phase 3 起步阶段明确不做：

- 多 Agent 调度、fork/join、任务依赖图。
- 通用 workflow engine 或任意步骤编排器。
- 自动代码合并、自动提交、自动发布。
- Calendar-triggered execution 的完整产品化。
- 安全远端执行器、relay、Noise E2EE、多设备路由。
- 让模型代替用户验收结果。

这些方向可以作为未来能力，但不能早于单任务 Loop Runtime 的真实使用验证。

## 数据与门禁

Loop Runtime 的新增数据必须满足：

- 按 task/turn 关联，不散落到 UI-only 状态。
- 可从 SQLite 恢复。
- 不保存未脱敏秘密。
- 不把 prompt echo、thinking、TUI chrome 或旧 turn 结果当成有效产出。
- 不增加同步 UI 路径中的全文解析、摘要或 TTS 清洗。

最低验收：

- 原有 B01-B10、P01-P07 和 P27 门禁全部继续通过。
- 真实 qodercli smoke、Turn 2 和长任务抽样不回退。
- 新增 Loop 指标不得导致 Tab 卡顿、状态延迟或需要手动刷新。
- 任一 Loop 建议都必须可忽略，用户仍能直接继续输入、标记完成或标记失败。

## 第一批实施顺序

建议按以下顺序进入 Phase 3：

1. 定义 Loop 事实模型：`LoopTurnMetrics` / `LoopEvaluation` / `LoopNextAction`，仅记录事实和建议，不执行自动化。
2. 在现有 task/turn 保存路径中写入轻量指标，避免新增并行状态管线。
3. 在任务详情增加“下一步”语义，不改变现有继续、标记完成、标记失败按钮。
4. 增加 App 重启恢复测试，确认 WorkState、approval、deliverable 和 loop facts 一致。
5. 再评估是否进入调度、提醒或通知，而不是直接做完整 scheduler。
