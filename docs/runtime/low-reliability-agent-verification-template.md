# 低可靠 Agent 验收模板

本文用于把 Armin 的模拟器/真实 qodercli 验收交给低可靠 Agent 执行。执行者必须机械执行，不得扩展任务范围、改配置、写额外脚本或把自动化替代项当成真实验收。

## 固定前提

- 设备：`emulator-5554`
- 应用包名：`com.ironion.armin`
- 项目：`countdown_widgets`
- 项目路径：`/Users/ironion/workspace/armin-test/countdown_widgets`
- 真实 Agent：`$HOME/.local/bin/qodercli`
- 审批模式：`aggressive`
- tmux session：必须是 Armin 创建的 `armin-*`，不能是手写的 `armin-medium-*`、`test-*` 或其他自造 session。

## 禁止事项

执行者不得做以下动作：

- 不得重置模拟器、清空 App 数据、删除已有 host/project 配置，除非用户明确要求。
- 不得修改 `scripts/armin_config.json`、host、SSH 密码、项目路径、Agent command 或 approval mode。
- 不得把 `qodercli-test` 当作真实 qodercli 验收；`qodercli-test` 只用于 Runtime Gate 自动化。
- 不得新增长期保留的测试脚本、临时工具或配置文件。若为验证临时创建文件，结束前必须删除。
- 不得因为 `Not Login Please Auth`、`Initializing... Prompts will be queued.` 或固定的 `Credits exhausted. Use /usage...` 文案直接判定失败；必须结合下方真实执行证据。
- 不得通过手动刷新、重进详情、重启 App 或重新监听来促成状态变化，除非用例明确验证该行为。
- 不得把 timeline 原始输出当作结果卡片验收；正式结果必须以 latest turn `TurnDeliverable` / 结果卡片为准。

## 开始前检查

只允许做以下检查：

1. 确认设备在线：

```sh
adb devices
```

期望看到 `emulator-5554 device`。

2. 确认 App 可启动或已运行。
3. 确认任务使用真实 qodercli：新建任务时选择 `qodercli` / host 中 agent command 为 `$HOME/.local/bin/qodercli`。
4. 如果 SSH 或 host 配置缺失，直接报告 `BLOCKED`，不要自行改配置。

## 必跑用例

### P27-REAL-01：真实 qodercli smoke

目标：确认真实 qodercli 短任务能自动完成并生成结果。

任务内容：

```text
Do not modify files.
Read pubspec.yaml only.
Final answer only:
ARMIN_REAL_SMOKE_<timestamp> status=PASS project=countdown_widgets files_changed=0
```

通过条件：

- Armin 创建真实 `armin-*` tmux session。
- 远端 tmux 中出现唯一 marker。
- Armin 无手动刷新自动进入 `turnIdle`。
- 结果卡片包含该 marker 或其清洗后的等价结果。
- 结果卡片不包含 `Thinking`、prompt echo、TUI chrome 或旧 turn 结果。

### P27-REAL-02：Turn 2 连续输入

目标：确认完成 Turn 1 后可以不刷新直接发送 Turn 2，并复用同一 session。

Turn 1：

```text
Do not modify files.
Read pubspec.yaml only.
Final answer only:
ARMIN_REAL_TURN1_<timestamp> status=PASS turn=1 project=countdown_widgets files_changed=0
```

Turn 2：

```text
Do not modify files.
Read pubspec.yaml only.
Final answer only:
ARMIN_REAL_TURN2_<timestamp> status=PASS turn=2 project=countdown_widgets files_changed=0
```

通过条件：

- Turn 1 自动进入 `turnIdle`。
- 发送 Turn 2 前没有手动刷新。
- Turn 2 使用同一个 `armin-*` tmux session。
- Turn 2 完成后自动进入 `turnIdle`。
- Turn 2 结果卡片包含 Turn 2 marker，不包含 Turn 1 marker。
- Turn 1 结果卡片不包含 Turn 2 marker。

### P27-REAL-03：真实 qodercli 长任务抽样

目标：确认长任务过程中不提前 waiting，完成后自动收敛。

任务内容：

```text
Do not modify files.
Read the countdown_widgets project and output a concise but complete project introduction in Chinese.
Run for long enough to inspect pubspec.yaml, lib/, test/, and README if present.
Final answer must include:
1. 项目定位
2. 技术栈
3. 核心组件
4. 测试覆盖
5. 下一步建议
6. ARMIN_LONG_TASK_<timestamp> status=PASS files_changed=0
```

通过条件：

- 远端仍在执行时，Armin 保持 `running`，不得提前 `turnIdle` / waiting。
- 若出现审批，状态必须切到 `needApproval`，不能卡在普通 running。
- 远端最终输出出现后，Armin 无手动刷新自动进入 `turnIdle`。
- 结果卡片包含最终结论和唯一 marker。
- 结果卡片不只显示中间 thinking 或工具调用。
- 完成后可以继续输入下一轮。

### P27-TTS-01：自动播报去重

目标：确认 fresh deliverable 自动播报一次，旧结果不重播。

说明：模拟器无法可靠听取音频时，允许用代码级或测试服务记录 `speech_count`；真实音频听感仍按 B07 人工/录音转写判定。

通过条件：

- 新 turn 的 fresh deliverable 触发一次自动播报。
- 重进详情、切 Tab、手动刷新、重复 `DELIVERABLE_UPDATED` 事件不会增加自动播报次数。
- 手动朗读仍读取 latest turn 的同一 `speechSummary` / `displaySummary` 来源。

### P38-LEA-REAL-01：AI 辅助 Loop Evaluation 抽样

目标：确认真实 qodercli、Loop Runtime、latest turn deliverable、loop facts 和端侧模型辅助判断可以一起工作。

开始前必须先推送本地模型缓存；不得重新下载模型：

```sh
DEVICE=emulator-5554 ./scripts/slm/push-gguf-model.sh .models/slm/Qwen3-0.6B-Q4_K_M.gguf
```

Turn 1：

```text
Read pubspec.yaml. Do not modify files.

Final answer only:
ARMIN_LOOP_EVAL_D1 status=PASS project=countdown_widgets files_changed=0 next=WAIT
```

Turn 2：

```text
Continue from the previous result. Do not modify files.

Final answer only:
ARMIN_LOOP_EVAL_D2 status=PASS previous_case_repeated=false files_changed=0 next=COMPLETE
```

通过条件：

- Turn 1 自动 `running -> turnIdle`，不手动刷新。
- Turn 1 结果卡片包含 `ARMIN_LOOP_EVAL_D1`、`status=PASS`、`files_changed=0`。
- 发送 Turn 2 前不手动刷新；Turn 2 执行期间回到 `running`。
- Turn 2 自动 `running -> turnIdle`，不手动刷新。
- Turn 2 最新结果卡片包含 `ARMIN_LOOP_EVAL_D2`、`previous_case_repeated=false`、`files_changed=0`。
- Turn 2 最新结果不得把 Turn 1 作为当前结果。
- `loop_evaluated` 每个 turn 至少写入一次；继续动作写入 `loop_user_action`。
- 若可通过 UI 自动化或人工截图确认，任务详情「动态」Tab 必须显示 `Loop 事实` 和 `辅助判断`。
- `辅助判断` 来源应为 `端侧模型`；若显示 `规则判断`，Runtime 层可 PASS，但 AI UI 层为 FAIL。
- `辅助判断` 内容不得包含 `Thinking`、`qodercli`、`Final answer only`、用户 prompt 原文或旧 turn marker。

说明：如果 `flutter drive` 安装测试 APK 后清空了历史任务，不能把“无法打开旧任务”判为 Runtime 失败；此时必须用代码级 UI 测试和 native smoke 补齐 UI / AI 层证据。

## 报告格式

执行完成后只输出一个 JSON。不要写散文总结，不要夹带未执行的推测。

```json
{
  "report_type": "ARMIN_LOW_RELIABILITY_AGENT_VERIFICATION",
  "report_version": 1,
  "device": {
    "requested": "emulator-5554",
    "actual": "emulator-5554",
    "connected": true
  },
  "environment_modified": false,
  "manual_refresh_used": false,
  "agent": {
    "type": "real_qodercli",
    "command": "$HOME/.local/bin/qodercli",
    "approval_mode": "aggressive"
  },
  "cases": [
    {
      "id": "P27-REAL-01",
      "status": "PASS | FAIL | BLOCKED",
      "task_id": "",
      "tmux_session": "",
      "turn_ids": [],
      "remote_evidence": "",
      "armin_evidence": "",
      "observed": "",
      "failure_or_block_reason": ""
    }
  ],
  "phase38": {
    "runtime_layer": "PASS | FAIL | BLOCKED | NOT_RUN",
    "ui_layer": "PASS | FAIL | BLOCKED | NOT_RUN",
    "native_slm_layer": "PASS | FAIL | BLOCKED | NOT_RUN",
    "ai_source": "端侧模型 | 规则判断 | missing | NOT_RUN",
    "manual_ui_inspection_used": false
  },
  "overall": "PASS | FAIL | BLOCKED",
  "failed_case_ids": [],
  "blocked_case_ids": [],
  "notes": ""
}
```

## 判定规则

- 任一用例触发目标场景后行为不符合预期，记 `FAIL`。
- 因设备离线、SSH 不可用、host 缺失、真实 qodercli 不可启动等无法触发目标场景，记 `BLOCKED`。
- `BLOCKED` 不得计入通过。
- 只有所有必跑用例均为 `PASS`，整体才是 `PASS`。
- 如果执行者改了环境、换了 Agent、用了 `qodercli-test` 或手动刷新促成状态变化，整体必须记 `FAIL`。
