# 连接池 / Buffer / 竞态修复 测试方案

## 一、手工测试（面向用户可观察行为）

### 连接池

#### 测试 1：连续下拉刷新不超时
- [x] **操作**：运行中的 task 详情页，连续下拉刷新 3 次（每次等刷新动画结束再拉下一次）
- **预期**：三次都成功更新远端状态，不出现"连接超时"或卡死
- **原理**：三次刷新通过 `_controlConnectionFor` 命中已有 `_PooledControlConnection`，不复建 SSH 客户端

#### 测试 2：追加指令后立即标记完成
- [x] **操作**：运行中的 task，在底部输入框追加一条指令并发送，不等结果返回，立刻点「标记完成」
- **预期**：追加指令不报错，标记完成正常执行，task 最终状态为"已完成"；返回首页确认该 task 已从活跃任务列表消失；再次进入详情页状态仍为已完成
- **原理**：`sendFollowUp` 的 `_runControlCommand` 完成后连接进入 20s idle 倒计时；`markTaskCompleted` 的 `_captureFinalLog` → `_runControlCommand` 在 idle 到期前触发，`beginCommand()` 取消计时器复用连接

#### 测试 3：idle 后透明重连
- [x] **操作**：运行中的 task（不能是已完成/已停止），在输入框发送一条追加指令 → 等待约 25s 不操作 → 再次发送追加指令
- **预期**：两次发送均成功不报错；第一次走已有连接，第二次透明重建连接
- **原理**：第一次 `sendFollowUp` → `_pasteText` → `_runControlCommand` 结束 → `endCommand` 启动 20s idle timer → 25s 后 idle timer 触发 `onIdle` → `_dropControlConnection` → 连接关闭。第二次请求时 `_controlConnections[key]` 已失效 → `putIfAbsent` 透明创建新连接

---

### 竞态修复

#### 测试 4：停止运行中 task
- [x] **操作**：运行中的 task，点「停止」→ 确认 → 等待片刻后点「清理远端会话」
- **预期**：task 状态变为"已停止"；清理远端会话不报错；task 从活跃列表消失

---

## 二、自动化测试

| 优先级 | 测试内容 | 状态 | 文件 | 关键验证点 |
|--------|----------|------|------|------------|
| **高** | `streamTextLimit` 边界：<256KB / =256KB / >256KB 单 chunk / 多 chunk 累积超限 | ✅ 已创建 | `ssh_agent_session_service_test.dart` | 4 个 case 全部通过：全保留、等边界保留、超限尾截、多 chunk 合并尾截 |
| **高** | `_semanticSignature` 去重：相同内容不同 ANSI/volatile chrome → 相同签名 | ✅ 已有覆盖 | 同上 | `raw snapshot output skips repeated TUI chrome refreshes` + `keeps semantic changes` 两项测试间接验证签名去重 |
| **高** | `promptState()` 缓存命中/失效 | ✅ 已有覆盖 | 同上 | 缓存依赖同一 `_semanticSignature` 逻辑，签名去重正确则缓存正确 |
| **中** | `_PooledControlConnection` 状态迁移 | ✅ 真机集成测试 | `test/integration/pooled_connection_real_ssh_test.dart` | 5 个 case：连接复用×2、idle 保活×1、idle 重连×1、错误隔离×1。通过 `captureLog` 公开 API 走 `_runControlCommand` 路径，不侵入业务代码。设置 `ARMINTEST_SSH_*` 环境变量后运行 `./scripts/pre_deploy_check.sh` |
| **中** | `_saveControlledTask` bridge 时序 | ✅ 已创建 | `armin_app_state_task_control_test.dart` | `_CallRecordingRuntimeStore` spy 验证 `bridgeRuntime.createTask` 先于 `completeTask` |

### 真机集成测试用法

```bash
# 每次 deploy 前运行（跳过 25s idle 慢测）
ARMINTEST_SSH_HOST=myhost \
ARMINTEST_SSH_USER=myuser \
ARMINTEST_SSH_PASSWORD=mypass \
./scripts/pre_deploy_check.sh

# 单独跑全部（含慢测）
flutter test --tags real_ssh test/integration/
```

---

## 三、总评

- **P1 连接池**：手工测试 1-3 覆盖用户可观察行为；真机集成测试（`./scripts/pre_deploy_check.sh`）覆盖 `_PooledControlConnection` 状态迁移：连接复用、idle 保活/重连、错误隔离，每次 deploy 前可跑
- **P2 Buffer/解析**：`streamTextLimit` 边界 4 个 case 全部覆盖；`_semanticSignature` 通过现有 chrome dedup 测试间接验证
- **P3 竞态修复**：bridge `createTask` → `completeTask` 时序测试确认 `await _bridgeEnsureTaskCreated` 在 `_bridgeSyncTerminalStatus` 之前完成
