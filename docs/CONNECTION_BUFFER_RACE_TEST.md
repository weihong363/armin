# 连接池 / Buffer / 竞态修复 测试方案

## 一、手工测试（可立即执行）

### P1 — 连接池

#### 测试 1：连续下拉刷新连接复用
- **场景**：在正在运行的 task 详情页，连续执行 3 次下拉刷新（同步远端状态）
- **预期**：三次都应成功，不应出现连接超时
- **验证点**：`_runControlCommand` 内部 `_controlConnectionFor` 应复用已有 `_PooledControlConnection`（`_controlConnections[key]` 命中），不创建新 SSH 客户端

#### 测试 2：追加指令 + 立即标记完成
- **场景**：在 task 详情页，先追加一条指令（`sendFollowUp`），然后立即点「标记完成」（`markTaskCompleted`）
- **预期**：先后两次 control command 应复用同一 SSH 连接，不应卡住
- **验证点**：
  - `sendFollowUp` → `_runControlCommand` → `beginCommand` / `endCommand`（启动 idle timer）
  - `markTaskCompleted` → `_captureFinalLog`（内部 `captureLog` → `_runControlCommand`）
  - 由于 `sendFollowUp` 完成后连接进入 idle 倒计时（`_controlConnectionIdleTimeout`），而 `markTaskCompleted` 在同一时序中快速触发 → `beginCommand` 取消 idle timer → 复用连接

#### 测试 3：idle close 后透明重连
- **场景**：等待 20s 不操作后，再次下拉刷新
- **预期**：应透明地建立新连接（旧连接已被 idle close 回收）
- **验证点**：idle timer 触发 `onIdle` → `_dropControlConnection` → `connection.close()` → `closed = true`。下次请求时 `_controlConnections[key]` 不存在或已 closed → `_controlConnectionCreates.putIfAbsent` 创建新连接

---

### P2 — Buffer/解析

#### 测试 4：长输出 buffer 裁剪
- **场景**：创建一个长时间运行的 task（让 Agent 输出超过 256KB），等任务进入 turnIdle
- **预期**：buffer 不应无限增长导致 OOM，`_streamText` 始终 ≤ 256KB
- **验证点**：`_ExecutionOutputState._appendStreamText` → `streamTextLimit = 256 * 1024`（262144 字节）→ 超出时取尾部 substring
- **准备**：可构造一个让 Agent 输出大量结构化的 prompt，例如"逐个列出 /usr/share/dict/words 中的所有单词"或"输出一个 500 行的 JSON 数据"

#### 测试 5：输出稳定时 promptState 缓存
- **场景**：在 task 输出稳定（hash 不变）时观察日志
- **预期**：`promptState()` 不应重复调用 approval/terminal parser
- **验证点**：`_semanticSignature(observed)` 过滤 ANSI 和 volatile chrome 行 → 生成签名 → `_lastPromptParseSignature` 缓存 → 签名相同时直接返回 `_lastPromptParseResult`

---

### P3 — 竞态修复

#### 测试 6：标记完成 → Bridge Runtime 状态同步
- **场景**：运行中的 task 点「标记完成」
- **预期**：Bridge Runtime 正确收到 terminal status（WorkPhase 从 working 切换到 completed）
- **验证点**：
  - `markTaskCompleted` → `_saveControlledTask(..., status: TaskStatus.userCompleted, completed: true)` → `_bridgeSyncTerminalStatus(task.id, TaskStatus.userCompleted, ...)`
  - → `bridgeRuntime.completeTask(taskId, summary, now)`

#### 测试 7：页面切换时计时器不泄漏
- **场景**：反复快速在 task 详情页和首页之间切换
- **预期**：计时器不应在后台继续 tick（`_PooledControlConnection._idleTimer`、poll timer 等应在 dispose 时取消）
- **验证点**：页面 dispose 时 `_PooledControlConnection.close()` → `_idleTimer?.cancel()`

---

## 二、自动化测试（建议补充）

| 优先级 | 测试内容 | 文件 | 关键验证点 |
|--------|----------|------|------------|
| **高** | `streamTextLimit` 边界测试：写入 <256KB、=256KB、>256KB 后 buffer 被裁剪 | `ssh_agent_session_service_test.dart` | `streamTextLimitForTest` 入口；`streamTextForChunksForTest` 可注入 chunks 验证 `streamText` 始终 ≤ 262144 |
| **高** | `_semanticSignature` 对相同语义内容的去重 | 同上 | 相同语义不同 ANSI/volatile chrome → 相同签名；不同内容 → 不同签名 |
| **高** | `promptState()` 缓存命中/失效 | 同上 | 连续相同签名 → 只解析一次；签名变化 → 重新解析 |
| **中** | `_PooledControlConnection` 的 `beginCommand`/`endCommand`/idle close 状态迁移 | 新增单元测试 | begin 取消 idle timer → activeCommands++ → end 递减 → idle timer 启动 → 超时触发 onIdle |
| **中** | `_saveControlledTask` 中 `await _bridgeEnsureTaskCreated` 的时序 | `armin_app_state_task_control_test.dart` | `_bridgeEnsureTaskCreated` 先于 `_bridgeSyncTerminalStatus`；`_bridgeCreateTaskIfMissing` 中 bridge 查询先于 create |

---

## 三、总评

四块改动实现完整，核心逻辑没有明显遗漏：

- **P1 连接池**：需要真机验收才能确认 dartssh2 的连接复用行为（SSHClient 在 `client.run()` 后是否保持可用）
- **P2 Buffer/解析**：可以直接在现有 task 上验证；buffer 裁剪逻辑简单可靠，`_semanticSignature` 的 volatile chrome 过滤列表需关注是否遗漏
- **P3 竞态修复**：`_saveControlledTask` 的 `await _bridgeEnsureTaskCreated` 后再 `_bridgeSyncTerminalStatus` 的顺序已保证；idle timer 取消路径完整

**优先级最高的自动化测试是 buffer 裁剪和语义签名缓存**，因为它们直接影响长任务的内存稳定性。
