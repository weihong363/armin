# Phase 2 RC 收口记录

## 验收状态

Phase 2 的真实设备主链路已通过人工验收：

- Android 真机可以创建真实任务，不回退 mock flow。
- Host 使用 password 认证，任务执行时使用真实 SSH/tmux。
- Codex CLI 与 Qoder CLI 均可作为真实 Agent 执行入口。
- 任务可选择 Host 与 project path，并在目标项目目录启动 Agent。
- 任务进入“等待继续”时不会自动判定完成，远端 tmux session 保留。
- 文本追加与语音追加会进入同一个任务 session。
- 暂停、恢复、断开监听、重新监听、停止、标记完成可用。
- 结果卡片按 turn 隔离输出并倒序展示。
- 小喇叭朗读当前 turn 的清洗后结果内容。
- 终态操作会保存最终输出并清理对应 tmux session。

## 真机回归记录模板

每次发版前至少记录一次 Codex 与 Qoder 的真实任务：

| 项目 | Codex  | Qoder  |
| --- |--------|--------|
| Host password 连接成功 | PASSED | PASSED |
| project path 进入正确目录 | PASSED  | PASSED  |
| 首轮任务进入等待继续 | PASSED    | PASSED    |
| 文本追加进入同一 session | PASSED    | PASSED    |
| 语音追加进入同一 session | PASSED    | PASSED    |
| 暂停后可恢复 | PASSED    | PASSED    |
| 断开监听后可重新监听 | PASSED    | PASSED    |
| 停止或标记完成后 cleanup | PASSED    | PASSED    |
| 结果卡片语义正确 | PASSED    | PASSED    |
| 小喇叭可朗读当前结果 | PASSED    | PASSED    |

建议同时记录：

- App version / build number
- Android 设备型号与系统版本
- Host 类型与 tmux 版本
- Agent command 与版本
- project path
- tmux session 名
- 失败时的 Raw Log 和电脑端 `tmux capture-pane`

## 已知限制

- TTS 仍依赖系统语音引擎；不同 Android ROM、语音包和语言支持会影响音色、语速和英文读法。
- 当前规则摘要可以过滤常见 TUI、tool trace、路径和命令噪音，但复杂长输出不保证抓住全部重点。
- 端侧小模型 runner 已有接口、能力检测、脱敏和 fallback，但生产包尚未捆绑实际模型。
- SSH 网络中断、手机后台回收或远端 shell 异常时，可能需要手动重新监听或清理远端 session。
- Codex/Qoder CLI 的 TUI 文案、ready 状态和输出格式变化，可能影响 idle 检测和结果清洗质量。
- `turnIdle` 只表示当前轮输出暂停，不表示任务成功；最终 outcome 仍由用户标记完成或失败。
- Armin 不是完整 terminal；复杂交互仍建议在电脑端通过 `tmux attach -t {session}` 调试。
- password 不进入普通历史，但 Android 安全存储实现仍需要继续关注备份、迁移和卸载后的凭证行为。

## Phase 2 RC Checklist

代码检查：

- `flutter test`
- `flutter analyze`
- `git diff --check`

真机检查：

- 从首页语音创建任务。
- 从任务页文本创建任务。
- 选择 Host 与 project path。
- Codex 任务可进入等待继续。
- Qoder 任务可进入等待继续。
- 文本追加和语音追加都进入同一 tmux session。
- “读一下结果”会朗读当前任务结果。
- 结果卡片小喇叭只朗读当前 turn 内容。
- 暂停后可恢复。
- 断开监听后远端 session 不被杀，且可重新监听。
- 停止任务后保存 final capture 并 cleanup session。
- 标记完成后保存 final capture 并 cleanup session。
- 历史详情中 raw log、turn 输出、结果卡片和时间线一致。
- JSON 历史、日志、metric、prompt 中不包含 SSH password 明文。

发布判断：

- 若本地检查通过，但 Codex 或 Qoder 其中一个真机任务失败，可继续作为 RC，但必须在本文件记录失败项和复现信息。
- 若 password 泄漏、session cleanup 不可靠、任务无法停止或结果不可读，应阻塞 RC。
