# Armin 产品定位

Armin 是面向本地与中国内地友好 AI Agent 的语言优先工作委派 Shell。

Armin 不应被定义为手机端 Codex 客户端、移动端 Agent Session Client、远程控制 Codex 的 App 或手机 SSH Terminal。它的核心不是复刻某个 Agent 的移动端界面，而是把用户的自然语言转成可追踪的工作语义，再把执行交给本地或中国内地友好的 AI Agent，例如 Codex CLI、Qoder、Aider、OpenCode、Ollama/Qwen、DeepSeek、Gemini CLI 或自定义本地 Agent。

Armin 统一的不是工具，而是工作语义。

Armin 要统一的是新建任务、补充上下文、添加约束、先计划、继续刚才的任务、暂停、停止、恢复、追加指令、请求确认、标记完成、标记失败、查看结果、查看日志、压缩上下文、限制读取范围、只运行相关测试和不要提交 Git。

## 核心定位

Armin 不是“手机端 Agent 聊天工具”，而是“任务优先的异步 Agent 工作协作层”。

它的第一公民不是 Agent，也不是聊天消息，而是 Task。

对比：

- 飞书 / Slack：人和人的协作，Conversation-first。
- Codex Mobile / litter：人和 Agent session 的协作，Agent-session-first。
- Armin：人围绕任务与执行过程协作，Task-first。

## 当前可验证价值

当前 Phase 2 已经能验证一个核心假设：

“用户离开电脑后，任务是否仍能继续推进，并且用户能否通过手机完成查看、追加、暂停、恢复、停止和确认完成。”

这比“语音是否足够炫酷”更重要。

## 与 litter 的差异

litter 更像多 Agent 的移动端 Session Client。它强调多 Agent、移动端连接、SSH / P2P / 本地发现、Realtime Voice 以及 Session / Thread continuation。

Armin 不正面复制 litter 的方向。Armin 更强调语言优先、中文工作语义、低成本语音交互、中国内地友好 Agent 生态、本地优先、Context Governance、原生输出观察、任务审计与 Metrics，以及用户自定义语音快捷词。

litter 统一的是 Agent Session。Armin 统一的是 Work Semantics。

## 语音原则

Armin 默认语音交互不应依赖 OpenAI Realtime API。语音首先要低成本、可控、中文友好。Realtime Voice 可以作为可选增强，但不能作为产品地基。

语音不是 Armin 的品类定义，而是降低异步交互成本的一种输入方式。Armin 必须同时支持语音和文字。用户在任何任务上下文中都应该能快速追加一句话，而不是被迫进入单独的聊天页面。

## 未来隐喻：给任务打电话

“给任务打电话”是长期方向，不是当前已完成能力。

含义：

- 用户不是找某个 Agent，而是找某件事。
- 每个任务拥有自己的上下文、历史、输出、状态和审计链路。
- 用户可以随时围绕任务追加约束、确认方案、暂停、恢复或验收。
- 系统未来可以自己决定调用哪个 Agent 或 session，但当前 Phase 2 不实现复杂路由。

## 当前需要验证的风险

短期风险：

- 用户可能仍把 Armin 理解成飞书、远程控制、手机 SSH 或 Codex Mobile。
- 用户可能并没有足够强的“Agent 管理成本”痛点。
- 语音在公共场合可能不是高频输入方式。
- 如果用户只运行单个任务，Armin 会更像 remote control；如果用户同时管理多个任务，Armin 才更像 Agent workspace。

因此当前阶段要重点验证：

- 用户是否会创建第二个任务。
- 用户是否会同时挂多个任务。
- 用户是否会离开电脑后回来查看。
- 用户最常用的是查看进度、追加指令、审批/确认，还是停止/恢复。
- Agent 是否真的增加了用户的同步协作负担和注意力负担。
