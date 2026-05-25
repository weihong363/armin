# 提示模板

当前任务模板版本：`armin-task-v1`。

## 任务提示

```text
任务：{task_description}。上下文：{context}。敏感信息占位：{secrets_placeholder_only}。完成后只输出 TASK_RESULT_START 块，字段为 status、summary、changed_files、validation、risks、next_actions，并以 TASK_RESULT_END 结束；如需用户确认，只输出 NEED_APPROVAL_START 块，字段为 reason、command、risk，并以 NEED_APPROVAL_END 结束。
```

## 运行时更新提示

```text
RUNTIME_UPDATE:
用户更新了任务约束。

新指令：
- {instruction}

保留之前的发现。除非必要，否则不要重新启动整个任务。
```

## 批准提示

当远程代理发出批准块时，Armin 会在任务历史中显示原因、命令、风险和状态。第二阶段将支持通过向 tmux 会话发送明确的用户决策来解决批准问题。

## 结果格式

代理在任务完成或无法继续时必须恰好输出一个 `TASK_RESULT_START` / `TASK_RESULT_END` 块。当需要用户决策时，代理必须输出 `NEED_APPROVAL_START` / `NEED_APPROVAL_END`。
