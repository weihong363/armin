# 提示模板

当前任务模板版本：`armin-task-v1`。

## 任务提示

```text
Armin context governance:
- Only inspect files directly related to the task.
- Never scan the entire repository.
- Avoid reading docs/ and README unless necessary.
- Keep edits minimal and focused.
- Run only targeted tests.
- Keep command output short.

{task_description}
```

任务中可包含用户编辑后的上下文、约束和脱敏后的 secret 占位符。Armin 不要求 Agent 返回私有结构化协议。

## 运行时追加

```text
{instruction}
```

用户追加的文本或语音转写会直接发送到当前 Agent 会话，以保留 Agent 原生交互方式。

## 输出观察

Armin 保存原始 terminal output，并清洗 TUI 噪音生成可展示和可播报的摘要。当输出在阈值内不再变化时，任务进入 `turnIdle`，等待用户继续或确认结束；`turnIdle` 不等于任务成功。旧的 `TASK_RESULT` / `NEED_APPROVAL` parser 仅用于 legacy 兼容测试。
