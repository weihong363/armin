# Runtime 迁移收口清单

> Phase 2.6 的迁移执行与验收入口。行为和性能门禁见 [Armin 核心行为与性能基线](core-behavior-performance-baseline.md)。

## 决策

- 当前应用尚未发布，不迁移、不读取、不兼容旧任务数据。
- 新实现出现问题时回滚代码版本，不在生产路径中并行保留新旧实现。
- 保留的是基线定义的产品行为，不是旧代码、旧字段或旧数据 fallback。
- parser 与 tmux capture 仅负责把当前新增终端证据转换为 Runtime observation；它们不是第二套状态、结果或 UI 数据源。

## 完成标准

迁移只有同时满足以下条件才算完成：

1. 一个状态只有一个有序 Runtime 提交队列，不存在旁路直调和无序双写。
2. UI 每个页面只有一个状态刷新来源；首页和详情使用 snapshot，详情仅用 Runtime 事件更新独立的低频 progress notifier。
3. `OUTPUT_UPDATED` 仅为节流后的内存事件，不写 SQLite、不触发首页重建。
4. `DELIVERABLE_UPDATED` 只在 current-turn evidence 解析为正式结果后发布，并携带 turn id 与 evidence fingerprint。
5. 结果卡片、手动朗读和自动 TTS 不读取 `task.summary` / `shortSummary` 作为 deliverable fallback。
6. 当前审批 UI、命令提交和 TTS 只读取 `WorkState.approval`；`TaskSession` 中的审批记录只用于审计历史。
7. 生产持久化只使用 `armin_runtime.db`；JSON Store、旧 schema 测试和迁移入口均不存在。
8. B01-B10、P01-P07 的适用门禁全部通过。

## 实施状态

| 项目 | 状态 | 当前实现 |
|---|---|---|
| Runtime 状态提交 | 已完成 | `saveTask` 将状态变化加入 per-task 串行队列；任务执行不等待 Runtime I/O |
| Turn settled 收敛 | 已完成 | 远端 monitor 使用过滤 TUI chrome 后的 semantic hash 判断稳定；settled candidate 由 Observer 复核后进入 `turnIdle`，避免 spinner/footer 阻塞状态收敛 |
| 启动状态旁路 | 已移除 | `running` 由统一 Runtime 状态同步触发 `startTask` |
| Observer stream-close 推断 | 已移除 | stream 结束不直接判 `runtimeLost`，由持续 reconcile 使用新增证据判定 |
| 高频输出事件 | 已完成 | 250ms 节流，仅发布 memory-only `OUTPUT_UPDATED` |
| Event-linked deliverable | 已完成 | 只解析一次 current turn，先持久化 `TurnDeliverable`，再发布 turn id 与 evidence fingerprint |
| 首页刷新 | 已完成 | 仅消费 `homeSnapshot`，不再额外订阅 EventBus `setState` |
| 结果/TTS fallback | 已移除 | 结果卡、手动朗读和自动 TTS 只读取同一 `TurnDeliverable`；无结果时保持空白或静默 |
| 当前审批来源 | 已完成 | 当前审批卡、命令和 TTS 读取 `WorkState.approval`；历史记录不可重新激活审批 |
| 持久化 | 已完成 | `WorkState` 嵌入 `runtime_tasks` 聚合；独立 `runtime_work_states` 表和 JSON Store 已删除 |
| 自动化验证 | 已完成 | B01/B02/B03/B04/B06/P06 Runtime Gate 已通过；最小回归测试和 `flutter analyze` 已通过；B07 音频同源仍按人工听取或可靠录音转写验收 |
| 真实 qodercli 验证 | 已完成 | `emulator-5554` 已完成真实 qodercli smoke、项目简介、final sync、同 session Turn 2 和长任务/回归抽样；验证结果卡片来自 latest turn、完成后自动 `turnIdle`、无需手动刷新继续输入 |
| 模拟器验证 | 已完成 | `emulator-5554` 可完成构建启动；Runtime Gate 自动化覆盖真实 SSH/tmux 路径，真实 qodercli 抽样覆盖 Phase 2.7 用户路径 |

## 不得重新引入

- EventBus 与 `ValueNotifier` 对同一页面重复触发重建。
- 每个 output chunk 同时发布 output 和 deliverable 事件。
- 用状态短文案、prompt echo、旧 turn 或 reconnect snapshot 构造结果。
- 通过 `unawaited` 发起互相无序的同 task 状态转换。
- SSH stream 关闭后立即把任务判为失败或 Runtime 丢失。
- 等待 SSH monitor 到达最长运行时才调用 `observeSettled()`。
- 在结果卡、手动朗读或自动 TTS 内再次调用摘要器。
- 从历史 `TaskSession.nativeApprovalRequests` 恢复当前审批。
- JSON/SQLite 双写、旧 schema 读取或“为了旧任务可读”的 fallback。

## 验证清单

执行 Agent 必须遵守 [模拟器验收判定规则](core-behavior-performance-baseline.md#模拟器验收判定规则)。`BLOCKED` 不计为通过；无 ANR、进程存活、单次 Tab 可点击或远端 tmux 出现结果都不能代替对应门禁证据。报告必须包含实际设备、task/turn id、tmux session、双侧时间戳证据和 `manual_refresh_used`。

- [x] `flutter test`（400 passed，5 skipped；跳过项为缺少测试 SSH 环境变量的真实连接测试）
- [x] `flutter analyze`
- [x] `git diff --check`
- [x] `emulator-5554`：冷启动无 crash、DB schema 正确、logcat 无 Armin 异常
- [x] `emulator-5554`：状态自动收敛且不手动刷新（B01）— 远端最终 marker 与 Armin 自动状态变化必须分别取证
- [x] `emulator-5554`：同 session follow-up 连续执行且状态不回退（B02）— Turn 1/2、session 和 observer 事件必须可关联
- [x] `emulator-5554`：safe/balanced/aggressive 审批完整可操作（B03）— 识别、发送、解决和历史一致性缺一不可
- [x] `emulator-5554`：暂停/恢复、断开/重新监听、停止、标记完成、标记失败和 cleanup（B04）— 使用独立任务覆盖全部子用例
- [x] `emulator-5554`：Turn 2 不复用 Turn 1 结果（B06）— 以结果卡片和持久化 deliverable 判定，不以原始 timeline 判定
- [x] `emulator-5554`：真实 qodercli smoke、项目简介、final sync 和同 session Turn 2 — 记录 `task_id`、`armin-*` session、两轮 marker 和 latest turn deliverable
- [x] `emulator-5554`：真实 qodercli 长任务/回归抽样 — 执行中不提前 waiting，完成后自动 `turnIdle`，无需手动刷新继续输入
- [x] 代码级 TTS 去重：fresh deliverable 自动播报一次，重复 event、重进详情、手动刷新不重播旧结果
- [ ] 人工听取或可靠录音转写：结果卡片、手动朗读和自动 TTS 同源（B07）— 仅“有声音”不能通过
- [x] `emulator-5554`：streaming、settled 和状态切换期间各完成 5 轮 Tab 循环（P06）— 每次响应小于 1 秒且不能以丢状态换性能
