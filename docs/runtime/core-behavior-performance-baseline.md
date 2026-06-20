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
