# Armin 核心行为与性能基线

> 本文是 Armin 所有开发阶段的不可回退验收契约。Phase 2.6 首次系统固化这些基线，但其适用范围不限于 Phase 2.6：任何涉及核心功能、Runtime、状态、observer、reconcile、审批、deliverable、UI、TTS、持久化或交互性能的变更都必须经过本文门禁。

具体阶段的迁移步骤由对应 Roadmap / checklist 维护；本文只定义跨阶段持续成立的核心行为、性能结果和验证要求。后续架构可以变化，但不得在没有明确产品决策和等价证据的情况下改变这些基线。

## 基线门禁

1. 任一阶段的代码逻辑变更、迁移或重构不得以架构统一、技术升级或清理遗留逻辑为理由降低现有功能、交互效率或稳定性。
2. 触及相关链路的变更必须列出受影响的基线编号，并提供自动化、模拟器或真机证据。
3. 任一适用基线不满足时，该方案不能视为完成；应暂停继续清理旧路径，定位回归并重新考虑实现方案。
4. 不得为了让新实现通过而放宽基线。确需改变产品行为时，必须先明确记录旧行为、新行为、用户影响和决策理由。
5. parser、tmux capture、TaskStatus fallback 等现有路径只有在替代路径满足全部相关基线后才能移除。
6. 新阶段开始、核心架构变更和发布候选版本都必须重新核对适用基线；不能因为上一阶段曾通过就跳过验证。

## 行为基线

| 编号 | 不可回退行为 | 验收标准 |
|------|--------------|----------|
| B01 | 状态自动收敛 | 任务执行后可自动从 `running` / `Agent started` 进入 `turnIdle`、`needAttention`、`needApproval`、`runtimeLost` 或终态；不能依赖手动刷新。活动 observer 应在一个检测窗口内更新，fallback reconcile 应在一个 reconcile 周期内校准。 |
| B02 | Follow-up 连续性 | 追加指令继续使用同一 tmux session；已有 observer 不被无意义替换；快速到达的审批、等待或结果事件不能被后写入的 `running` 覆盖。 |
| B03 | 审批可操作 | safe / balanced / aggressive 模式下审批 prompt 可识别、选项可发送，`pending → resolving → resolved/failed` 与 UI、历史状态一致。 |
| B04 | 任务控制完整 | 暂停、恢复、断开监听、重新监听、停止、标记完成、标记失败和 cleanup 保持可用；断开监听不杀死远端任务，停止/终态 cleanup 失败必须可见并可重试。 |
| B05 | Reconcile 不复活旧证据 | reconnect、refresh 和 reconcile 只消费当前基线后的新增证据；旧 prompt、旧 exit marker、旧审批和旧结果不得重新触发状态或 deliverable。 |
| B06 | 每 turn 结果正确 | 结果卡片显示对应 turn 的有效产出，不得使用初始 prompt、prompt echo、thinking、旧 turn、running/reconnect snapshot 冒充结果。没有 evidence 时显示暂无结果或状态提示。 |
| B07 | 结果与朗读一致 | 结果卡片、手动朗读和自动 TTS 面向同一 latest turn deliverable；审批和注意提示不能重播旧 turn 结果；最终播报文本不包含 CLI chrome、quota 文案或拼音提示泄漏。 |
| B08 | Runtime issue 分类正确 | quota/usage limit 前已有 deliverable 时保留结果并进入可继续状态；没有 deliverable 时提示运行时问题，不能伪装成普通任务结果。 |
| B09 | UI 不抢占用户 | Runtime/output/resume 事件不得强制切 Tab、重置滚动或阻止返回；只有用户显式操作才能切换到产出页。 |
| B10 | 数据与安全边界不回退 | SSH 密码不进入普通 JSON 历史；任务、turn、审批、状态和审计记录保持可读取。旧数据兼容范围由当前发布阶段单独声明，但不得以兼容为由污染新任务主路径。 |

## 性能基线

| 编号 | 不可回退性能 | 验收标准 |
|------|--------------|----------|
| P01 | 高频输出不做重持久化 | 高频输出不得逐条触发重持久化。当前基准实现中 `OUTPUT_UPDATED` 只走内存 EventBus，500 次连续输出事件持久化数量为 0；未来若改为 checkpoint/batch，必须证明写入有界且交互性能不退化。状态、审批和 deliverable 等语义事件继续可靠持久化。 |
| P02 | 纯进度不触发全局刷新 | 普通 progress 不写完整任务 JSON、不追加空日志/指标、不触发全局 AppState 或首页重建；状态变化才执行完整保存。 |
| P03 | 同步候选选择轻量 | Candidate lookup 只能检查 turn 元数据，不切割大输出、不运行摘要、不扫描完整 raw log。 |
| P04 | 结果解析不阻塞首帧 | 结果切片、过滤和摘要不得阻塞首帧或 Tab。当前基准实现使用后台 isolate、相同 signature 的 in-flight 合并、有界缓存和首帧后调度；替代实现必须提供等价或更好的响应证据。 |
| P05 | 数据增长有界 | 指标使用 merge/cap，空 polling 不新增节点；结果/最近输出只读取有界窗口；页面缓存和历史展示数量有明确上限。 |
| P06 | 交互保持响应 | 任务运行、输出稳定和状态切换期间，动态/产出/高级 Tab、返回和审批按钮必须可操作；模拟器连续切换不得出现超过 1 秒的可见冻结或 Android ANR。 |
| P07 | 状态与性能解耦 | 为降低卡顿不得丢失状态事件、延迟审批或要求手动刷新；为提高状态准确性也不得把全文解析、summary 或 TTS 放回同步 UI 路径。 |

## 模拟器验收判定规则

以下规则适用于 B01、B02、B03、B04、B06、B07 和 P06。执行 Agent 不得自行降低条件或用相邻能力代替目标能力。

### 通用规则

1. 固定记录 `requested_device`、`actual_device`、应用包名、任务 id、tmux session、Agent 类型、approval mode 和测试开始/结束时间。指定 `emulator-5554` 时，实际设备不一致直接记为 `BLOCKED`。
2. `PASS` 表示全部前置条件成立、全部步骤执行完成、全部必需证据可核对；缺少任一项只能是 `BLOCKED` 或 `FAIL`，不能“部分通过后整体 PASS”。
3. `FAIL` 表示测试环境可用且已触发目标场景，但 Armin 行为不符合门禁。`BLOCKED` 仅用于认证、网络、音频或无法触发审批等外部条件导致目标行为未被执行。`BLOCKED` 不得计入完成率。
4. 状态和结果验证必须同时保留 Armin UI 证据与远端 tmux/Agent 证据，并使用时间戳或唯一 marker 建立先后关系。只看其中一侧不能判定通过。
5. 禁止点击刷新、重新进入详情页、切换后台再返回或重启 App 来促成状态变化，除非用例本身验证 reconnect/re-entry。任何非用例要求的手动刷新都会使 B01/B02 判为 `FAIL`。
6. “进程存活、无 crash、无 ANR、Tab 可点击一次、时间线出现输出、tmux 中出现结果”都只是辅助证据，不能单独证明本节任一门禁通过。
7. timeline 的原始输出可以保留 prompt、thinking 和 TUI chrome；它只用于审计。正式结果是否正确必须检查 `TurnDeliverable` 对应的结果卡片和朗读来源。
8. `Thinking...` 既可能是 Agent 仍在工作，也可能是完成结果后的残留或动态 TUI chrome。必须结合远端唯一最终 marker、后续语义输出、Armin 状态变化和观察时间判断，不能仅凭该行下结论。
9. 固定出现的 `Credits exhausted. Use /usage...` 文案不等于本轮额度耗尽。只有当前 turn 的行为、退出状态或新增 Runtime issue 证据明确关联该文案时，才可将其作为阻塞原因。
10. 每个用例必须使用唯一 marker，例如 `P26-B01-D1-<timestamp>`；不得复用旧任务、旧 turn 或旧截图作为当前证据。

### B01 状态自动收敛

**前置条件**

- Agent 已认证并能完成一个返回唯一最终 marker 的短任务。
- 任务确实进入过 `running`，测试期间 App 保持前台且 observer 未被人工断开。
- 记录当前 approval mode。默认检测阈值为 safe 2 秒、balanced 10 秒、aggressive 60 秒；允许额外 5 秒用于事件提交和 UI 更新。fallback reconcile 按配置周期加 probe timeout，再允许 5 秒。

**步骤**

1. 创建只读短任务，要求最终答案包含唯一 marker。
2. 记录 Armin 首次显示 `running` 的时间。
3. 在远端确认最终 marker 已完整出现并记录时间；不要操作 Armin。
4. 等待一个对应 observer 检测窗口。若 observer 已 detached，则等待一个 fallback reconcile 窗口。
5. 记录 Armin 自动离开 `running` 的目标状态和时间。

**PASS 必须同时满足**

- 远端出现当前任务的唯一最终 marker。
- Armin 无手动刷新地进入 `turnIdle`、`needAttention`、`needApproval`、`runtimeLost` 或终态。
- 状态变化发生在对应检测窗口内，且之后至少观察一个检测窗口没有被旧 `running` 覆盖。
- UI 状态、latest turn 状态和 WorkState 语义一致。

以下情况必须判为 `FAIL`：远端已产生最终 marker 但 Armin 超时仍为 `working/Agent started`；重新进入页面后才更新；只在 tmux 完成而 App 未收敛；用静止 pane 或 stream close 直接伪造完成。

### B02 Follow-up 连续性

**前置条件**

- B01 已通过，Turn 1 已进入可追加状态。
- 记录 Turn 1 的 task id、turn id、tmux session 和 observer attach/detach 事件。

**步骤**

1. Turn 1 输出唯一 marker `D1` 并自动收敛。
2. 从 Armin 追加包含唯一 marker `D2` 的指令。
3. 在发送前后分别记录 tmux session；观察 Turn 2 的 `running → settled` 全过程。
4. Turn 2 收敛后继续观察一个检测窗口，检查是否出现迟到的 `running` 回写。

**PASS 必须同时满足**

- task id 和 tmux session 全程不变，只新增一个 turn。
- 没有非用户触发的 observer 替换、session 重建或重复发送。
- Turn 2 能自动进入 `running` 并自动收敛；快速到达的审批、等待或结果状态不被后续 `running` 覆盖。
- D2 在远端只执行一次，重新进入详情页后状态和 turn 数保持一致。

新建了 session、追加后永远 `running`、出现重复 D2、或状态先 settled 后退回 `running` 均为 `FAIL`。仅看到“上下文更新输出 2”不能判定通过。

### B03 审批可操作

**前置条件**

- 使用可稳定触发原生终端审批的问题；问题和选项必须带当前任务唯一 marker。
- safe、balanced、aggressive 三种 mode 分别执行，不能用一个 mode 代替全部模式。

**步骤**

1. 触发审批，记录远端问题和所有选项。
2. 确认 Armin 自动进入 `needApproval`，当前审批卡内容与远端一致。
3. 在 Armin 选择一个明确选项，记录发送时间和远端收到的输入。
4. 观察 `pending → resolving → resolved/failed`，并检查任务继续执行或明确失败。
5. 重新进入详情页，确认已解决审批只存在于历史，不重新成为当前审批。

**PASS 必须同时满足**

- 三种 mode 均完成完整流程。
- 当前审批来自 WorkState，问题和选项没有被旧 prompt 或历史审批替换。
- 选择只发送一次，远端收到的选项与用户选择一致。
- UI、WorkState 和审批历史的最终状态一致；失败时原因可见且可重试。

只识别出 prompt、只显示按钮、或点击后没有远端发送证据都不能 PASS。无法触发审批应记 `BLOCKED`，不能改测普通输入后宣告通过。

### B04 任务控制完整

使用独立任务分别验证，避免停止或终态 cleanup 破坏后续步骤：

| 子用例 | 必须验证的结果 |
|---|---|
| 暂停/恢复 | 暂停后手机 observer 停止，远端 session 保留；恢复监听同一 session，并继续自动同步状态。 |
| 断开/重新监听 | 断开只产生 `observerDetached`，远端继续运行；重新监听同一 session，自动同步断开期间的新证据。 |
| 停止 | 保存 final capture，状态变为 stopped，目标 tmux session 被清理；cleanup 失败时 UI 明确显示失败且提供重试。 |
| 标记完成 | 保存 final capture 和用户决定，状态持久化，目标 session 按产品规则清理。 |
| 标记失败 | 保存 final capture 和失败决定，状态持久化，目标 session 按产品规则清理。 |

每个子用例都必须提供操作前后 Armin 状态、tmux session 是否存在、相关时间线/Runtime 事件以及重新进入后的持久化状态。全部子用例 PASS 才能将 B04 标记为 PASS；任一未执行则整体 `BLOCKED`，任一行为错误则整体 `FAIL`。

### B06 每 turn 结果正确

**步骤**

1. Turn 1 要求最终只返回唯一内容 `D1_RESULT`，等待自动收敛并记录结果卡片。
2. 追加 Turn 2，要求最终只返回不同内容 `D2_RESULT`，等待自动收敛。
3. 检查最新结果、历史 turn 结果、原始输出展开和重新进入详情页后的结果。

**PASS 必须同时满足**

- Turn 1 结果卡片包含 D1，不包含 prompt echo、thinking 或 D2。
- Turn 2 结果卡片包含 D2，不包含 D1、Turn 1 prompt、Turn 2 prompt、thinking 或 reconnect snapshot。
- 每个结果关联自己的 turn id 和非空 evidence fingerprint；重新进入后保持一致。
- running turn 在正式 deliverable 尚未持久化时显示“暂无正式结果”或状态提示，不把最近输出 preview 当结果。

时间线原始输出含有 D1/D2 或 thinking 不代表结果污染；必须以结果卡片和持久化 deliverable 判定。任务未收敛、没有正式结果时记 `BLOCKED`，不能因为原始输出看起来正确而 PASS。

### B07 结果与朗读一致

**前置条件**

- 使用包含中文、英文、数字和一个不会被语音清洗删除的唯一短语的 completed/turnIdle deliverable。
- 自动 TTS 已开启且设备确实具备音频输出；无人听取且没有可靠录音转写时，音频部分记 `BLOCKED`。

**步骤与 PASS 条件**

1. 记录最新 turn id、evidence fingerprint、结果卡片 `displaySummary` 和持久化 `speechSummary`。
2. 记录自动 TTS 实际朗读内容；随后点击手动朗读，记录实际内容。
3. 自动和手动 TTS 必须读取同一 turn、同一 evidence fingerprint，并朗读相同的 `speechSummary`；`speechSummary` 为空时，两者都使用同一清洗后的 `displaySummary`。
4. 朗读必须保留结果关键事实和唯一短语，不包含 prompt、thinking、旧 turn、审批问题、CLI chrome、固定 quota 文案或拼音提示。
5. 新 turn 尚无 deliverable 时不得重播旧 turn；审批/注意事件也不得触发旧结果播报。

“听到有声音”、结果卡片文本正确、或只有手动朗读正确都不足以 PASS。模拟器无法可靠采集音频时，应保留代码级 `TaskSpeechDecision.text` 证据并将最终音频判为 `BLOCKED`。

### P06 交互保持响应

**前置条件**

- 分别覆盖高频 streaming、settled/deliverable 解析、状态切换三个时段。
- 测试任务必须产生足够输出，不能用空任务、静态首页或已完成且无日志的任务代替。

**步骤**

1. 每个时段连续完成 5 轮“动态 → 产出 → 高级 → 动态”切换。
2. 在 streaming 期间执行一次返回列表并重新进入；在审批场景点击一次可操作按钮。
3. 对每次 tap 记录发送时间和目标页面可交互元素出现时间，同时检查 Flutter/logcat 的 ANR、fatal exception 和 frame 异常。

**PASS 必须同时满足**

- 每次交互在 1 秒内出现目标页面或操作反馈，5 轮全部完成。
- 没有 Tab 被 Runtime 事件强制切换、滚动位置无异常重置、返回操作不被阻塞。
- streaming、deliverable 解析和状态保存没有造成可见冻结、ANR 或 crash。
- 重新进入后状态和结果保持正确；性能通过不能以丢事件、延迟审批或手动刷新为代价。

只完成一次 Tab 切换、只证明无 ANR、只验证静态页面，或无法给出 tap/响应时间，都不能判定 P06 PASS。

### 强制报告字段

每个门禁至少输出以下结构；不得省略 `manual_refresh_used` 和双侧证据：

```json
{
  "gate_id": "B01",
  "status": "PASS|FAIL|BLOCKED",
  "requested_device": "emulator-5554",
  "actual_device": "emulator-5554",
  "task_id": "...",
  "turn_ids": ["..."],
  "tmux_session": "...",
  "approval_mode": "safe|balanced|aggressive|not_applicable",
  "manual_refresh_used": false,
  "remote_evidence": "包含 marker 和时间戳的远端证据",
  "armin_evidence": "包含状态/结果和时间戳的 UI 或数据库证据",
  "elapsed_ms": 0,
  "observed": "实际行为",
  "failure_or_block_reason": ""
}
```

总体验收只能在 B01、B02、B03、B04、B06、B07、P06 全部为 `PASS` 时标记 `PASS`。存在任一 `BLOCKED` 时整体为 `BLOCKED`，存在任一 `FAIL` 时整体为 `FAIL`。

## 证据要求

| 变更范围 | 最低证据 |
|----------|----------|
| Runtime 状态、observer、reconcile | 对应单元测试 + AppState 测试 + 可用模拟器/设备上的自动状态切换验证（当前开发环境可使用 `emulator-5554`） |
| Streaming、持久化、指标 | 高频事件测试 + SQLite 事件类型/数量核对 |
| 结果卡片、deliverable、Tab | source/service 测试 + widget 测试 + 模拟器 Tab/首帧验证 |
| 手动朗读、自动 TTS | `TaskSpeechDecision.text` 精确断言 + 模拟器/真机最终播报路径 |
| SSH/tmux 与审批 | SSH service 测试 + 同一 session/选项发送现场验证 |
| 新阶段/核心架构变更 | 适用基线清单 + 变更前后证据 + 至少一次模拟器核心流程 |
| 发布前完整回归 | `flutter test`、`flutter analyze`、`git diff --check` + 真机核心流程 |

Android `gfxinfo` 可能无法覆盖 Flutter SurfaceView 的实际帧；没有有效帧数据时，不得用 `0 jank` 作为通过证据。应结合 Flutter frame timing、自动化交互响应、ANR、事件写入数量和用户可见冻结判断。

## 变更检查模板

每次核心功能相关变更至少记录：

```text
变更范围：
受影响基线：Bxx / Pxx
变更前证据：
变更后自动化证据：
模拟器/真机证据：
已知限制：
结论：通过 / 需要重新评估方案
```

只有所有适用项通过，迁移步骤才能标记完成并继续删除旧逻辑。
