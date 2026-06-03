# Semantic IO Integrity

Armin 的输入输出必须遵循 Source of Truth 原则。

## 分层

- `rawInput`：原始语音转写。
- `cleanedInput`：清洗后的输入。
- `draftInput`：用户确认后的任务草稿。
- `rawOutput`：Agent 原生输出。
- `cleanedOutput`：清洗后的输出。
- `displaySnippet`：UI 展示片段。
- `ttsText`：语音播报文本。

## 规则

1. `rawInput` 和 `rawOutput` 永远是 source of truth。
2. `displaySnippet`、`ttsText` 和 `summary` 都是派生物。
3. 派生物不能覆盖原文。
4. 输入清洗不能删除否定词。
5. 输入清洗不能删除不确定性表达。
6. 输出摘要不能声称任务成功。
7. `turnIdle` 不等于 `completed`。
8. 用户确认才是最终 outcome。

## 必须保留的语义词

输入清洗必须特别保留这些词：

```text
不要
先别
别
只分析
可能
好像
怀疑
优先
先
再
不要提交
```

## 派生内容边界

`displaySnippet` 只服务 UI 预览，不能写回历史、不能作为 prompt source，也不能作为 TTS source。`ttsText` 只服务语音播报，不能覆盖 `cleanedOutput` 或 `rawOutput`。摘要可以帮助用户理解输出，但不能替代原始日志审计。
