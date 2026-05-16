# 提示模板

当前任务模板版本：`armin-task-v1`。

## 任务提示

```text
请完成以下任务。执行过程中自行读取文件、修改代码、运行必要测试。
不要频繁询问我，除非遇到高风险操作、信息不足或需要用户决策。

任务：
{task_description}

补充上下文：
{context}

执行约束：
{constraints}

敏感信息：
{secrets_placeholder_only}

要求：
- 优先最小改动。
- 不要进行无关重构。
- 不要自动 git commit / git push，除非用户明确要求。
- 遇到高风险命令必须暂停并请求确认。
- 完成后必须输出结构化结果，格式如下：

TASK_RESULT_START
status: success | failed | need_user_input
summary: ...
changed_files:
- ...
validation:
- ...
risks:
- ...
next_actions:
- ...
TASK_RESULT_END

如果需要用户确认，输出：

NEED_APPROVAL_START
reason: ...
command: ...
risk: low | medium | high
NEED_APPROVAL_END
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

代理在任务完成或无法继续时必须恰好输出一个 `TASK_RESULT_START` / `TASK_RESULT_END` 块。当需要危险命令或用户决策时，代理必须输出 `NEED_APPROVAL_START` / `NEED_APPROVAL_END`。
