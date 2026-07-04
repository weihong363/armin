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

第一批只做单任务 Loop Runtime 的可恢复事实记录和状态可见性：

1. Loop 事实记录：每个 turn 记录输入长度、输出摘要长度、等待时间、审批次数、重试次数、结果是否存在、用户后续动作。
2. Loop 状态视图：在任务详情中展示当前任务处于“执行中、等待审批、等待用户继续、需要验证、已由用户收尾”等阶段。
3. 恢复能力：App 重启后从 SQLite 恢复 task、turn、runtime event、work state、approval 和 deliverable，不从旧 pane 重新猜结果。
4. 通知入口：只在长任务需要用户动作、产生 fresh deliverable 或运行时丢失时通知；不把每个 output chunk 变成通知。

“下一步建议”在过渡阶段可以先做规则型验收辅助，但不能做状态按钮重复。状态型建议（继续、验收、完成、失败、处理审批）只是现有操作按钮的重复，产品价值不足。高价值规则建议必须基于最新 `TurnDeliverable`、用户原始目标、约束和 loop facts，指出具体缺口或风险，并给出可直接发送的 follow-up 草稿；不得基于 thinking、prompt echo、TUI chrome、旧 turn 或 reconnect snapshot。

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

1. 定义 Loop 事实模型：`LoopTurnMetrics` / `LoopEvaluation`，仅记录事实，不执行自动化。
2. 在现有 task/turn 保存路径中写入轻量指标，避免新增并行状态管线。
3. 在任务详情增加 Loop 状态视图，不改变现有继续、标记完成、标记失败按钮。
4. 增加 App 重启恢复测试，确认 WorkState、approval、deliverable 和 loop facts 一致。
5. 再评估是否进入规则型验收辅助建议、AI follow-up 草稿、提醒或通知，而不是直接做完整 scheduler。

## 当前落地状态

- 已定义 `LoopTurnMetrics`、`LoopEvaluation`，表达单 turn 的事实和评估结果；当前代码不包含下一步建议字段。
- 已在 latest turn deliverable 保存点写入 `loop_evaluated` metric event；事实与结果卡片同源，避免 prompt echo、thinking、旧 turn 或 reconnect snapshot 参与评估。
- 已记录关键用户动作 `loop_user_action`：继续下一轮、标记完成、标记失败，并绑定 task、turn、next turn、输入长度和来源。
- 当前写入复用 `TaskSession.metricEvents`，随现有 task 持久化路径保存和恢复；不新增数据库表、不新增并行状态管线。
- 已补充单元测试，覆盖 turn settle 后生成 deliverable 时同步写入 loop facts、用户动作 facts、AppState 重建恢复 deliverable/facts/approval WorkState，并确认当前 payload 不包含下一步建议。
- 已新增规则型验收辅助建议纯服务，覆盖补测试证据、收敛阻塞、补修改清单、确认完成度、校验约束等高价值 follow-up 草稿；当前不接 UI、不自动发送。
- 尚未启用自动下一步执行、AI follow-up 草稿、scheduler 或通知策略；下一步进入任务详情 Loop 状态视图与更完整的恢复门禁。

## 当前可执行部分

当前可以继续执行的内容：

1. 完善 Loop facts：补充拒绝/重做等尚未产品化的用户动作事件。
2. 任务详情 Loop 状态视图：只展示事实状态，例如执行中、等待审批、等待用户验证、运行时丢失、用户已收尾。
3. App 重启恢复测试：继续补充 SQLite runtime store 的设备级恢复一致性；代码级 RuntimePersistenceStore 契约已覆盖 approval 和 WorkState。
4. 指标门禁：确认 loop facts 写入不会影响 Tab 切换、状态自动刷新、结果卡片和 TTS。
5. 规则型验收辅助建议 UI 接入：当前服务和测试已完成，后续只展示草稿，不自动发送。

## Phase 2.7 指标门禁

Loop facts 属于 Phase 2.7 收尾与 Phase 3 前置数据，不得改变 Phase 2.6/2.7 主链路。每次修改后至少确认：

- 状态同步：任务执行完成后自动进入 `turnIdle`，不需要手动刷新；执行中不得提前 waiting。
- 结果卡片：仍只读取 latest turn `TurnDeliverable`，不能从 loop facts、`summary`、prompt echo 或 raw snapshot 补造结果。
- TTS：自动 TTS 仍只在 fresh deliverable 首次出现时播报一次；loop facts 写入不得触发播报。
- UI 性能：loop facts 写入不得增加同步 UI 路径中的全文扫描、摘要、TTS 清洗或大字符串解析。
- 持久化：loop facts 复用 task 保存路径，不能新增并行状态管线或双重持久化。

建议执行的自动化验证：

- `flutter test test/core/armin_app_state_task_control_test.dart`
- `flutter test test/features/voice/services/task_speech_policy_test.dart`
- `flutter analyze`
- `git diff --check`

Flutter 测试和分析命令必须串行执行。当前 Flutter native assets 构建会复用 `build/native_assets`，并发运行多个 `flutter test` 或 `flutter analyze` 可能出现 `objective_c.dylib`、`native_assets.json` 或 `NativeAssetsManifest.json` 缺失。这类失败先按工具链并发产物冲突处理，单独重跑同一命令；单独重跑仍失败才算门禁失败。

真机或模拟器抽样只用于补充确认真实 qodercli 路径没有回归，不能替代上述代码级门禁。

## 规则型验收辅助建议设计

规则型建议的目标不是解释状态，也不是重复按钮，而是帮助用户快速判断本轮结果是否可验收、下一轮应补什么证据。建议必须同时满足：

- 来源可信：只读取用户原始目标、约束、latest turn `TurnDeliverable`、loop facts 和可验证状态。
- 指向明确：必须指出具体缺口、风险或验收动作，不能输出“可以继续/可以完成”这类空泛建议。
- 可直接发送：建议应包含一段可编辑 follow-up 草稿，用户确认后才能发送。
- 可忽略：不改变任务状态，不自动执行，不隐藏原有继续、完成、失败按钮。
- 可测试：每条规则必须有 fixture，验证触发条件、非触发条件和跨 turn 隔离。

建议优先覆盖以下高价值规则：

| 触发信号 | 建议意图 | follow-up 草稿示例 |
| --- | --- | --- |
| 结果没有测试命令、测试结果或验证证据 | 补验证 | `请运行与本次修改相关的最小测试，并输出测试命令、结果和仍未覆盖的风险。` |
| 结果出现 blocked、auth、permission、cannot、failed 等阻塞词 | 先收敛阻塞 | `请先说明当前阻塞原因、最小解除步骤，以及是否需要我确认或提供信息。不要扩大任务范围。` |
| 结果很短，或只描述项目/计划，没有交付内容 | 区分已完成与未完成 | `请明确列出已完成内容、未完成内容、下一步最小动作，以及当前是否可验收。` |
| 结果提到修改/实现，但没有文件清单 | 补审计证据 | `请输出本轮修改的文件列表、每个文件的作用，以及如何验证这些修改。` |
| 多轮连续继续但没有完成判断 | 收敛剩余工作 | `请基于当前状态列出剩余 TODO，按优先级给出下一步，并说明完成标准。` |
| 用户约束包含“不修改文件/只读/不要提交”，但结果暗示执行实现或修改 | 校验约束 | `请确认本轮是否修改了文件、是否提交了 Git，以及是否违反我给出的约束。` |
| 结果中有“应该/可能/建议”但没有实际执行证据 | 要求落地证据 | `请把建议转成已执行动作或明确的未执行原因，并给出可验证结果。` |

明确禁止的建议：

- `当前已完成，可以继续或标记完成。`
- `需要审批，请处理审批。`
- `任务失败，可以重试。`
- 任何只复述 `TaskStatus` 或现有按钮的文案。
- 任何自动发送、自动继续、自动标记完成/失败的行为。

## AI 建议前置边界

AI 下一步建议不是规则型过渡层的前提。未来开启前必须先满足：

- 输入边界：只能读取用户原始目标、约束、latest turn `TurnDeliverable`、loop facts 和可验证状态；不得读取 thinking、prompt echo、旧 turn deliverable、TUI chrome 或 reconnect snapshot。
- 输出边界：只能生成可编辑的 follow-up 草稿或验收提示，不得改变任务状态，不得自动发送，不得自动标记完成或失败。
- 质量边界：建议必须提供建设性判断，例如缺少测试、结果不完整、阻塞未解决、范围扩大、需要验收证据；不能只是重复现有按钮。
- 安全边界：涉及高风险操作、提交、删除、发布、凭证、远程执行扩权时，建议只能要求用户明确确认。
- 验证边界：AI 建议上线前必须有 fixture 测试，覆盖完整结果、部分完成、失败阻塞、无测试证据、跨 turn 隔离和 prompt echo 污染。
