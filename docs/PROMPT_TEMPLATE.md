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

## User task
{task_description}

## User constraints
{constraints}

## Context chunk 1
{highest_priority_context}

## Secret placeholders
{redacted_secret_placeholders}
```

任务中可包含用户编辑后的上下文、约束和脱敏后的 secret 占位符。Armin 不要求 Agent 返回私有结构化协议。

## Prompt Context Chunking

为避免长上下文挤掉用户原始意图，`PromptTemplateBuilder` 先把输入拆成本地规则 chunks，再交给 `PromptGovernor`：

- `User task`：用户任务原话，最高优先级，不因上下文过长而裁剪。
- `User constraints`：约束芯片，例如最小改动、只分析、不提交 Git，必须保留。
- `Secret placeholders`：只保留脱敏占位符，不传 secret 明文。
- `Context chunk N`：补充上下文按段落/行分块，并用错误、失败、文件路径、expected/actual 等信号排序。

这是轻量 RAG 风格的 prompt chunking，不做 embedding、不引入向量库、不扫描仓库，也不自动读取项目文件。它只负责在已有草稿内容中保留核心语义，并在字符预算内优先传递高价值上下文。

## 运行时追加

```text
{instruction}
```

用户追加的文本或语音转写会直接发送到当前 Agent 会话，以保留 Agent 原生交互方式。

## 输出观察

Armin 保存原始 terminal output，并清洗 TUI 噪音生成可展示和可播报的摘要。当输出在阈值内不再变化时，任务进入 `turnIdle`，等待用户继续或确认结束；`turnIdle` 不等于任务成功。旧的 `TASK_RESULT` / `NEED_APPROVAL` parser 外壳已移除，结果摘要来自当前 turn/output，审批来自原生终端提示。
