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
| Turn settled 收敛 | 已完成 | 稳定 pane 发布 `__ARMIN_SETTLED_CANDIDATE__`；Observer 复核强信号后提交 `turnIdle`，attach-only 同样检查静止快照 |
| 启动状态旁路 | 已移除 | `running` 由统一 Runtime 状态同步触发 `startTask` |
| Observer stream-close 推断 | 已移除 | stream 结束不直接判 `runtimeLost`，由持续 reconcile 使用新增证据判定 |
| 高频输出事件 | 已完成 | 250ms 节流，仅发布 memory-only `OUTPUT_UPDATED` |
| Event-linked deliverable | 已完成 | 只解析一次 current turn，先持久化 `TurnDeliverable`，再发布 turn id 与 evidence fingerprint |
| 首页刷新 | 已完成 | 仅消费 `homeSnapshot`，不再额外订阅 EventBus `setState` |
| 结果/TTS fallback | 已移除 | 结果卡、手动朗读和自动 TTS 只读取同一 `TurnDeliverable`；无结果时保持空白或静默 |
| 当前审批来源 | 已完成 | 当前审批卡、命令和 TTS 读取 `WorkState.approval`；历史记录不可重新激活审批 |
| 持久化 | 已完成 | `WorkState` 嵌入 `runtime_tasks` 聚合；独立 `runtime_work_states` 表和 JSON Store 已删除 |
| 自动化验证 | 已完成 | `flutter analyze` 通过；`flutter test` 396 passed、5 skipped（仅跳过缺少 SSH 环境变量的真实连接测试） |
| 模拟器验证 | 部分完成 | APK 安装、冷启动、新 SQLite 空任务库、Host/Project fixture 加载通过；远程执行等待测试 SSH 凭据 |

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

- [x] `flutter test`（396 passed，5 skipped；跳过项为缺少测试 SSH 环境变量的真实连接测试）
- [x] `flutter analyze`
- [x] `git diff --check`
- [ ] `emulator-5554`：状态自动收敛且不手动刷新
- [ ] `emulator-5554`：Turn 2 不复用 Turn 1 结果
- [ ] `emulator-5554`：动态/产出/高级 Tab 连续切换无冻结
- [ ] `emulator-5554`：审批、暂停、恢复、断开监听和重新监听可操作
- [ ] 人工听取：结果卡片、手动朗读和自动 TTS 同源
