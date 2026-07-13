# Phase 3 临时执行计划

> 本文用于 Phase 3 启动阶段的临时执行跟踪。正式产品边界仍以 `docs/ROADMAP.md`、`docs/SPEC.md` 和 `docs/runtime/phase-3-loop-runtime-prep.md` 为准。

## Phase 3 总目标

Phase 3 从 Phase 2.6/2.7 已验证的单任务可靠执行继续推进到轻量 Loop Runtime。它的核心是让长任务可恢复、可追踪、可调度、可复盘，而不是引入多 Agent 编排、通用 workflow engine 或安全远端执行器基础设施。

当前阶段的原则：

- 继续复用 RuntimeEventBus、WorkState、ApprovalState、latest turn `TurnDeliverable` 和真实 qodercli 主链路。
- 结果、TTS 和验收判断不得来自 prompt echo、thinking、TUI chrome、旧 turn 或 reconnect snapshot。
- `turnIdle` 表示本轮等待用户继续，不等于整个任务已经完成。
- 新增 Loop 数据只能记录事实或生成用户可编辑草稿，不能自动替用户验收或继续执行。
- 任一 Phase 3 改动都必须继续满足核心行为与性能基线。

## Roadmap

### Phase 3.0：基线冻结与 Loop 合同

目标：确认 Phase 2.7 的任务执行主链路作为 Phase 3 的不可回退基线，并定义 Loop Runtime 的最小合同。

范围：

- 冻结 Runtime Gate、真实 qodercli smoke、TTS 单次播报、结果卡片 latest turn source。
- 明确 Loop Runtime 建立在现有 Runtime 主路径之上，不替代 RuntimeEventBus / WorkState。
- 定义最小 Loop 合同：目标、当前 turn、结果、用户动作、审批、恢复状态、完成判断。
- 明确 Phase 3 起步不做 scheduler 完整产品化、不做多 Agent、不做 AI 自动继续执行。

完成标准：

- 文档记录 Phase 3.0 的边界、基线和下一步执行顺序。
- Phase 2.7 当前已完成能力被列为 Phase 3 门禁，而不是可被重构放宽的历史实现。
- 后续 Phase 3 改动必须引用受影响基线并提供验证证据。

### Phase 3.1：Loop Facts 完整化

目标：先记录事实，不做自动决策。

执行内容：

- 补齐用户动作 facts：继续、标记完成、标记失败、重做、接受结果、拒绝结果。
- 记录任务事实：等待时间、审批次数、重试次数、turn 数、deliverable 生成时间。
- 在任务详情展示 Loop 事实状态，不展示伪建议。
- 继续复用 `TaskSession.metricEvents`，不新增并行持久化管线。

当前状态：

- 已补齐接受结果、拒绝/重做、继续、标记完成、标记失败的 `loop_user_action` 事实。
- 接受结果和拒绝/重做只记录 facts，不改变 task status，不发送 follow-up，不触发远端 agent。
- 任务详情 Loop 事实已展示接受和重做计数。
- 已补充 AppState 重建恢复测试，确认接受/重做 facts 恢复后不触发远端控制或自动 TTS。

验收：

- App 重启后 facts 不丢。
- facts 不影响状态同步、结果卡片、TTS 和 Tab 性能。

### Phase 3.2：Loop Session / Loop Step 最小模型

目标：让长任务从多个 turn 升级为一个可追踪 Loop。

执行内容：

- 一个 task 对应一个 LoopSession。
- 一个 LoopSession 下有多个 LoopStep / Turn。
- 状态保持简单：`running`、`waitingUser`、`needApproval`、`blocked`、`completed`、`failed`。
- 仍然只支持单任务循环。

验收：

- 多 turn 结果严格隔离。
- 当前 Loop 状态可从 SQLite 恢复。
- 手动刷新、重新监听、App 重启后状态一致。

### Phase 3.3：恢复与续跑

目标：解决真实长任务中的断连、重启和 observer 丢失问题。

执行内容：

- App 重启后恢复 task、turn、approval、deliverable、loop facts。
- observer detached 后可重新连接原 tmux session。
- 远端仍在执行时 Armin 保持 running。
- 远端已完成时 Armin 自动收敛到 waiting。

当前状态：

- 已有代码级门禁覆盖 AppState 重建后恢复 task、turn、approval、deliverable 和 loop facts。
- 已补充 observer detached 重启恢复测试，确认 App 重启后仍可重新 attach 到原 `armin-*` tmux session。
- 已有 remote snapshot / reconcile 测试覆盖远端仍在执行时保持 running，以及远端完成后自动收敛到 `turnIdle` 并生成 latest turn deliverable。
- 已有 Runtime Gate 覆盖 pause / resume / disconnect / reconnect 保持同一 tmux session。

验收：

- 不出现远端还在执行但 UI 已 waiting。
- 不出现远端已完成但 UI 永远 running。
- 不依赖手动刷新才能恢复状态。

### Phase 3.4：任务调度 MVP

目标：支持最小的“之后执行”能力。

执行内容：

- 支持单次定时任务。
- 到时间后复用现有 startTask / sendFollowUp 主链路。
- 支持取消、改时间和查看下一次执行时间。
- 暂不做复杂 recurrence 和日历完整产品化。

验收：

- 到点自动进入现有 Runtime 主链路。
- App 重启后调度任务仍存在。
- 调度任务结果仍走 event-linked deliverable。

当前状态：

- 已完成代码级 MVP：`TaskSession.scheduledFor` 持久化到现有 task 数据，不新增并行调度表。
- `ArminAppState` 已支持单次 schedule / reschedule / cancel，并在 load 时恢复 pending 调度 timer。
- 到点启动复用现有 `startTaskExecution` 和 Runtime 主链路；调度动作本身不发布 deliverable、不触发 TTS。
- 任务卡片和任务详情会展示 pending 调度任务的下一次执行时间，避免误显示为已运行。
- 已补充单元测试覆盖 due-on-load、reschedule 后启动、cancel 后不启动。
- 已实现有限 recurrence：新建任务页可创建单次、daily / weekly 计划；模板在到点后创建独立 occurrence task 并推进下次时间；不补跑遗漏周期、不复用旧 tmux / turn / deliverable。日历产品化、通知策略或自动继续执行仍不由 scheduler 决定。

### Phase 3.5：审批工作流增强

目标：让长任务审批可恢复、可追踪、可审计。

执行内容：

- 审批进入 Loop facts。
- pending 审批状态 App 重启后可恢复。
- 审批通过、拒绝、补充指令均记录。
- aggressive 模式只尊重用户显式选择，不做隐式自动批准。

验收：

- balanced / aggressive 不回归；安全模式已从产品执行模式中移除。
- 审批状态不丢。
- 审批后任务能继续收敛。

当前状态：

- 已新增结构化 `loop_approval_event` fact，记录审批请求、通过、拒绝、终端选项选择和补充指令长度。
- 审批 facts 复用 `TaskSession.metricEvents`，不新增审批表、不改变 WorkState approval 作为唯一可操作审批来源。
- 任务详情 Loop 事实视图已展示审批请求、审批处理和补充指令计数。
- 已补充单元测试覆盖 approval request、approve / reject、terminal option、自定义补充指令，以及 AppState 重建后 approval WorkState 与 approval facts 一致。
- aggressive 模式不做隐式自动批准；所有审批处理仍来自用户显式选择。

### Phase 3.6：自动摘要与结果追踪

目标：让长任务多轮结果可读、可验收。

执行内容：

- 每轮 deliverable 保持独立。
- Loop 级摘要只基于正式 deliverable。
- 记录用户接受、继续、拒绝、重做、标记完成。
- 支持查看当前可验收结果和历史 turn 结果。

验收：

- 多 turn 不串结果。
- 最新结果卡片总是 latest turn。
- 摘要和 TTS 不受 prompt echo、thinking 或 CLI chrome 污染。

当前状态：

- 已新增结构化 `loop_result_summary` fact，聚合正式 deliverable 的结果数量、latest turn、latest evidence fingerprint、用户验收动作计数和 Loop 级摘要文本。
- Loop 级摘要只读取 `TurnDeliverable.displaySummary`，不读取 prompt、thinking、raw snapshot、CLI chrome 或旧 task summary。
- 多 turn 结果追踪保留每个正式结果的 turnId、turnIndex、summaryLength 和 evidenceFingerprint。
- 任务详情 Loop 事实视图会展示最新 Loop 级摘要；结果 / 产出卡片仍只展示 latest/current turn deliverable 与历史 deliverable，不从 loop facts 补造结果。
- 已补充单元测试覆盖单 turn deliverable 生成 summary、多 turn deliverable 隔离、AppState 重建后 result summary 恢复且不触发自动 TTS。

### Phase 3.7：通知与用户反馈

目标：让用户无需一直盯着任务详情页。

执行内容：

- 本地通知：需要审批、等待用户、任务完成、任务失败。
- 通知点击回到对应任务。
- 自动 TTS 只在 fresh deliverable 首次出现时触发一次。

验收：

- 通知不重复。
- TTS 不重复。
- 通知状态和任务状态一致。

当前状态：

- 已新增轻量 `TaskNotificationService` 作为唯一通知入口；Android 已实现系统通知权限、通知渠道、展示和点击跳回对应任务。当前不接 push、不改变 TTS。
- AppState 已把 RuntimeEventBus 事件映射为本地通知请求：需要审批、等待用户指示、fresh deliverable 结果可验收、运行连接丢失、任务完成和任务失败。
- 结果通知只在正式 `DELIVERABLE_UPDATED` 且当前 turn 内存在同 fingerprint 的 `TurnDeliverable` 时触发；旧 deliverable、恢复数据、reconnect snapshot、prompt echo、thinking 和 TUI chrome 不会补发通知。
- 通知按 task / kind / turn / evidence fingerprint 去重；审批按 approval id 去重；状态通知按当前 task status 二次确认，避免 paused、runtimeLost、turnIdle 混淆。
- 已补充 AppState 单元测试覆盖旧结果不通知、新结果只通知一次、审批通知只通知一次、等待输入和 runtimeLost 通知状态一致；`flutter test test/core/armin_app_state_task_control_test.dart` 已通过。
- 通知状态只来自已提交的 RuntimeEventBus 事件；系统通知、权限和点击跳转都不能写入或覆盖 Runtime 状态。

### Phase 3.8：AI 辅助 Loop Evaluation

目标：最后再接 AI，且先做辅助，不做自治。

当前状态：已完成首轮只读接入。

- Android 侧已接入 llama.cpp native runtime，`native_slm_smoke_test.dart` 可验证本地 GGUF 真模型生成。
- 已新增 `LoopEvaluationAssistant`，输入限定为 runtime status、latest `TurnDeliverable`、`loop_evaluated`、`loop_user_action`、`loop_approval_event`。
- 已新增 `LoopNextAction` 与 `LoopActionPolicyGate`：AI/规则层可以提出辅助 action，但只有正式 deliverable 中的结构化 `CONTINUE + next_action` 可以进入 Autopilot。
- 已新增 `ArminAppState.runAutopilotNextAction` Runtime 入口：只接受 `autoAllowed` action，写入 `loop_auto_action` fact，按 turn / evidence / action 去重，并复用现有 `sendFollowUp` 主链路创建下一轮 Turn。
- 已将 Autopilot 绑定到 `aggressive` / YOLO 执行模式：fresh deliverable 为 `CONTINUE` 时可执行协议中的具体下一步；`DONE` / `BLOCKED` 不续跑。native terminal approval 可自动 approve，但仍先记录 requested fact，再走现有 approval resolution 路径。
- 已接入任务详情「动态」Tab 的 `辅助判断` 卡片，展示辅助判断、下一步 action 和执行策略；不绕过 `sendFollowUp` 主链路，不触发 TTS。
- 模型不可用、超时、空输出或异常时回落到规则判断；fallback 不影响结果卡片、状态刷新或继续输入。

本轮执行记录（2026-07-10）：Phase 3.8 聚焦回归 183/183、完整 Runtime Gate 14/14 通过；native SLM、真实 qodercli deliverable/Turn 2、真实 qodercli YOLO 审批与自动 follow-up 通过。spinner 收敛、session cleanup、终态合同、SSH teardown、自动审批 Runtime 状态和 notifier 生命周期问题均已修复。动态页视觉和真实音频仅保留为发布前人工抽样。

产品化增强记录（2026-07-12）：计划任务已有独立管理页并按首次执行日期排序，编辑/取消不新增第二写路径；Android 通知权限由设置页显式申请，通知事件不再隐式弹权限；高风险 Autopilot 草稿可编辑、取消和确认，确认动作写入 `loop_auto_action/confirmed` 后统一走 `sendFollowUp`。

产品化增强第二批（2026-07-12）：端侧模型设置页可检查 llama.cpp runtime、模型路径、空间占用和降级原因，并可安全删除默认模型；Loop quality 直接聚合 `loop_evaluated`、`loop_user_action` facts，展示结果、接受、返工、重试和等待指标；审计历史支持结构化搜索与 JSON 导出。三者均为只读消费或显式用户动作，不写入 Runtime 状态、不参与 deliverable/TTS。

产品化增强第三批（2026-07-12）：新增发布代码/设备门禁命令；Runtime 持久事件支持 archive id cursor 增量读取和显式 callback replay。Replay 不广播到 live EventBus，因而不能重复触发通知、语音和 UI 状态。跨重启恢复继续以 Runtime aggregate 和 session binding 为事实源，watcher checkpoint 只用于观察去重。

产品化增强第四批（2026-07-13）：Android 使用 AlarmManager + 开机恢复 + foreground headless Flutter Runtime 处理后台到期计划，仍调用同一 `_startScheduledTask`；系统日历由 `calendarSyncEnabled` 事实投影，创建、改期和取消均经过 `saveTask`；SLM 支持 HTTPS + SHA-256 可信安装到应用私有目录。iOS 工程及通知、EventKit、计划提醒、SLM 管理通道已加入，但 iOS 计划提醒不承诺精确后台执行，llama.cpp decode 尚未达到 Android 等价能力。

发布验收（2026-07-13）：代码门禁 `222/222`、analyze、Android debug build 通过；设备上产品化门禁、完整 Runtime Gate、真实 qodercli deliverable/Turn 2 回归依次通过。门禁不写设备 Host/项目配置。启动阶段有 Choreographer 跳帧日志，P06 运行时 Tab 响应通过，真实音频仍需人工听取。

验收拆成三层：

- Runtime 层：真实 qodercli P38 抽样验证 Turn 1 / Turn 2 自动收敛、deliverable 隔离和 loop facts 写入。
- UI 层：`test/history/task_detail_screen_loop_test.dart` 和 `task_detail_screen_approval_test.dart --plain-name "loop evaluation assistant"` 验证 `Loop 事实`、`辅助判断`、来源显示和污染词过滤。
- Native SLM 层：`native_slm_smoke_test.dart` 验证模型文件存在、native runtime 可加载、真模型可生成。

限制：

- 当前 AI 可以生成结构化下一步 action；Autopilot 只能在 YOLO 模式下执行 `LoopActionPolicyGate` 允许的低风险 action。
- 当前 AI 不直接审批；只有 YOLO 模式下的 Runtime Policy Gate 可以自动 approve native terminal approval，且不能标记完成/失败或替代用户最终验收。
- 生产构建通过 `ARMIN_SLM_MODEL_URL` + `ARMIN_SLM_MODEL_SHA256` 下载并校验模型；`.models/slm/Qwen3-0.6B-Q4_K_M.gguf` 和 `push-gguf-model.sh` 仅保留为本地开发入口，不提交 GGUF。
- 端侧生成耗时约 18 秒，不能放入同步 UI 关键路径。

## Phase 3.0 完成记录

状态：已完成文档级收口。

已冻结的 Phase 2.7 基线：

- Runtime Gate、真实 qodercli smoke、Turn 2 连续输入、真实长任务抽样继续作为 Phase 3 回归门禁。
- 结果卡片、手动朗读和自动 TTS 继续只消费 latest turn `TurnDeliverable`。
- 自动 TTS 只在本轮 fresh deliverable 首次出现时播报一次。
- 任务执行中不得提前 waiting；完成后不得依赖手动刷新进入 waiting。
- Loop facts、规则型草稿或未来 AI 评估不得进入同步 UI 全文解析路径。

Phase 3.0 的结论：

- Phase 3 可以开始，但第一批只能做 Loop facts、状态可见性和恢复门禁。
- 调度、通知和 AI 辅助必须在恢复与结果门禁稳定后再进入。
- Secure Remote Executor Infrastructure 仍属于 Phase 4+，不进入 Phase 3 起步实现。

## 下一步执行顺序

1. Phase 3.1：补齐 Loop facts 的用户动作和恢复测试。
2. Phase 3.2：定义最小 LoopSession / LoopStep 模型，并映射现有 task / turn。
3. Phase 3.3：补齐 App 重启、observer 断连、tmux 仍运行和远端已完成的恢复门禁。
4. Phase 3.4：在恢复门禁稳定后实现单次调度 MVP。
5. Phase 3.5：增强审批事实和审批恢复。
6. Phase 3.6：实现 Loop 级摘要和结果追踪。
7. Phase 3.7：接入通知和用户反馈。
8. Phase 3.8：最后接入 AI 辅助评估，且只提供可编辑草稿。
