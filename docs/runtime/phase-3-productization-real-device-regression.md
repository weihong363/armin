# Phase 3 产品化真实设备抽样

目的：在不重置模拟器、不替换 Host、不使用 `qodercli-test` 的前提下，确认产品化能力仍走同一条 Runtime 主路径。设备为 `emulator-5554`，Agent 为真实 `$HOME/.local/bin/qodercli`，项目使用已配置的 `countdown_widgets`，全程不手动刷新。

## 执行前提

- Armin 已安装当前 APK，Host、项目路径、SSH 密码和真实 qodercli 已配置。
- 不执行 seed/reset，不改 Host/IP/Agent Command，不写临时脚本。
- 每个 case 使用新建任务；完成后只记录观察结果，不清理或修改其他历史任务。
- 除非 case 明确要求，保持 `aggressive` 执行模式。

## P3P-01：一次性计划任务

1. 新建任务，输入：

   ```text
   Read pubspec.yaml only. Do not modify files. Final answer must include: ARMIN_SCHEDULE_ONCE status=PASS files_changed=0
   ```

2. 选择“计划执行”，首次时间设为 2-3 分钟后，重复选择“仅一次”，创建计划。
3. 到点前确认：任务为 pending/计划中，没有新 `armin-*` tmux session，没有 Turn 1。
4. 到点后确认：出现一个新的 `armin-*` session；Armin 进入 running，远端结束后自动进入 waiting/turnIdle；结果卡片包含 `ARMIN_SCHEDULE_ONCE status=PASS`。

通过标准：不手动刷新、不提前启动、结果来自该任务最新 Turn。

## P3P-02：重复模板与独立 occurrence

1. 新建任务，输入：

   ```text
   Read pubspec.yaml only. Do not modify files. Final answer must include: ARMIN_SCHEDULE_DAILY status=PASS files_changed=0
   ```

2. 选择“计划执行”，首次时间设为 2-3 分钟后，重复选择“每天”，创建计划。
3. 到点前确认：模板显示“之后每天重复”，且不占首页“活跃”执行名额。
4. 到点后确认：模板的下一次时间已推进到明天；另有一个新 occurrence 任务和新 `armin-*` session；occurrence 完成后有独立 Turn 1 与结果卡片。

通过标准：模板不复用 occurrence 的 tmux、Turn 或 deliverable；不补跑旧周期。

## P3P-03：计划管理

1. 对 P3P-01 或新建的未来计划任务，在详情页右上角菜单选择“调整执行时间”。
2. 选择新的未来时间，确认详情页和首页时间同步变化。
3. 再次打开菜单选择“取消计划”，在确认框中确认。

通过标准：任务进入完成，`scheduledFor` 清除，关联系统日历事件被删除，没有启动远端 session；不会误触发 TTS 或结果通知。

## P3P-03B：后台触发与系统日历同步

1. 新建 2-3 分钟后执行的一次性计划，开启“同步到系统日历”，授予日历权限。
2. 在系统日历确认存在带 `[ARMIN_TASK_ID:<taskId>]` 标记的日程；回到 Armin 调整时间，确认同一日程被更新而不是重复新增。
3. 将 Armin 切到后台并锁屏，等待触发；确认 Android 显示“正在启动计划任务”前台服务通知，并创建真实 `armin-*` session。
4. 再创建一个未来计划并取消，确认任务进入完成，Alarm 与日历事件均删除。

通过标准：后台触发、前台触发使用同一任务和 Runtime 执行入口；无重复 session、重复日历事件或第二份状态。

## P3P-03C：端侧模型可信安装

1. 使用带 `ARMIN_SLM_MODEL_URL` 和 `ARMIN_SLM_MODEL_SHA256` 的 APK，打开“设置 → 端侧模型”。
2. 删除已有模型后点击“安装端侧模型”，确认下载结束后模型位于应用私有目录并显示大小。
3. 使用错误 SHA-256 的测试构建重复安装，确认明确失败，原有可用模型不被错误文件替换。

通过标准：仅接受 HTTPS 和 64 位 SHA-256；安装失败不影响 Runtime、结果、TTS 或规则降级。

## P3P-04：真实结果与端侧辅助判断

1. 新建即时任务，输入：

   ```text
   Read pubspec.yaml and provide a concise Chinese project introduction. Do not modify files. Final answer must include: ARMIN_EVAL_REAL status=PASS files_changed=0
   ```

2. 等待自动收敛后，在“产出”确认结果卡片包含 marker，且没有 prompt echo、Thinking、TUI chrome 或旧 Turn 文本。
3. 打开“动态”，检查“辅助判断”：
   - 模型可用时显示“来源 端侧模型”；
   - 模型缺失、超时或失败时显示“来源 规则判断”及“端侧模型 已降级：...”原因；
   - 两种情况下均不改变任务状态、不自动改写结果卡片或触发额外 TTS。

通过标准：结果/TTS 仍只取 latest-turn deliverable；SLM 仅辅助 Loop Evaluation。

## P3P-05：通知抽样

1. Android 通知权限已允许时，运行一个需要人工审批的真实 qodercli 任务。
2. 后台 Armin，等待审批通知；点击通知。
3. 确认只打开对应任务详情，任务状态和当前 Tab 不被通知重置；处理审批后不重复收到同一审批通知。

通过标准：通知是 RuntimeEventBus 的只读投影，不改变状态、不造成重复语音播报。

## 统一取证格式

```json
{
  "report_type": "ARMIN_PHASE_3_PRODUCTIZATION_REAL_DEVICE",
  "device": "emulator-5554",
  "agent": "real_qodercli",
  "manual_refresh_used": false,
  "cases": [
    {"id": "P3P-01", "status": "PASS|FAIL|BLOCKED", "evidence": ""}
  ],
  "fatal_or_anr": false,
  "notes": ""
}
```

## 发布门禁

代码门禁不依赖设备配置：

```bash
make release-gate
```

设备门禁要求 `emulator-5554` 已配置真实 qodercli、Host、项目和密码；命令不会 seed、reset 或改写环境：

```bash
make release-device-gate
```

自动化通过后仍保留两项发布前人工抽样：听取 fresh deliverable 自动播报仅一次并确认手动朗读内容；真实长任务执行期间滚动动态/产出/高级页面，确认局部更新不改变滚动位置且无主观卡顿。

## 1-8 产品化门禁记录

2026-07-13 在 `emulator-5554` 完整执行 `make release-device-gate`：`productization_device_gate_test.dart`、完整 Runtime Gate 和真实 qodercli 两轮 deliverable 回归依次 PASS，真实任务证据 session 为 `armin-rqd-1783924266540245`，全程未手动刷新。同日 `make release-gate` 通过 `222/222`、analyze 和 Android debug build。真实音频内容和主观滚动手感仍属于人工感知项。
