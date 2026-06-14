# Armin

Armin 是面向本地与中国内地友好 AI Agent 的语言优先工作委派 Shell。

以任务为中心的异步 Agent 工作协作层。用户把任务交给本地 Agent 后可以离开电脑，任务继续在远端推进，通过手机查看进展、追加指令、暂停/恢复、停止或确认完成。

Armin 专注于把用户的自然语言转成可追踪的工作语义，并把执行交给本地或中国内地友好的 AI Agent（Codex CLI、Qoder CLI 等）。

> **Armin 的目标不是统一 AI 工具，而是统一用户的工作语义：让用户用自己的语言描述、约束、推进、恢复、停止和确认工作，再由不同 Agent 去执行。**

长期方向上，Armin 希望让用户像"给任务打电话"一样和工作本身交互：围绕某个任务持续补充上下文和做决策，而不关心具体是哪一个 Agent、session 或终端窗口。当前实现基于任务详情页、语音/文本追加、SSH/tmux session 和任务审计链路。

## 代码架构

Armin 采用模块化 Flutter 架构，目录结构：

```
lib/
├── core/                       # 核心层：状态管理、存储、共享模型
│   ├── models/                 # 跨功能共享值类型（如 TaskStatus）
│   ├── services/               # ArminAppState 全局状态
│   └── storage/                # JSON 持久化、安全密码存储、内存实现
├── features/                   # 功能模块层
│   ├── agent/                  # Agent 会话抽象、SSH/tmux 执行、输出清洗与观察
│   │   ├── models/             # AgentExecutionUpdate 等
│   │   ├── parsers/            # Legacy 结果/批准/终端提示解析器
│   │   └── services/           # SSHAgentSessionService、AgentOutputCleaner、RuntimePolicy
│   ├── history/                # 任务历史审计详情视图
│   ├── hosts/                  # Host 配置管理与 UI
│   ├── projects/               # Project path 配置与选择
│   ├── runtime/                # BridgeRuntime、SessionManager、TaskWatcher
│   ├── settings/               # 设置页面
│   ├── tasks/                  # 任务核心：模型、服务、页面、组件
│   │   ├── models/             # 任务草稿、约束、输出摘要等
│   │   ├── screens/            # TaskHomeScreen、TaskDetailScreen
│   │   ├── services/           # PromptGovernor、OutputSummaryProvider、ConstraintExtractor 等
│   │   └── widgets/            # 任务相关小组件
│   └── voice/                  # STT/TTS 抽象与设备语音服务
└── shared/                     # 跨模块共享层
    ├── theme/                  # ArminTheme 主题配置
    └── widgets/                # 通用 UI 组件
```

应用入口位于 `lib/main.dart`，通过 `ArminAppState.run()` 初始化并加载持久化数据。`ArminApp` 使用 `AppStateScope` 向下提供全局状态。

## 它是什么

- 一个任务中心的异步工作入口
- 一个语音/文本任务草稿界面
- 一个提示预览和确认层
- 一个围绕任务持续追加指令和确认结果的交互层
- 到 Codex CLI、Qoder CLI 及后续终端 Agent 的 shell 级别桥接
- 每个任务的本地历史和审计跟踪
- 一个观察 Agent 管理成本、异步协作负担和用户注意力成本的实验表面
- 未来用于调试人与代理委托质量的指标表面

## 它不是什么

- 不是飞书、Slack 或微信这类人与人的协作 IM
- 不是官方的 Codex Mobile 远程控制替代品
- 不是单纯的手机聊天客户端
- 不是让用户在手机上写代码
- 不是让语音替代所有输入方式
- 不是完整的终端模拟器
- 不是复杂的多代理调度器
- 不是 fork/join 运行时
- 不是自动代码合并或 git commit 系统
- 不是 SaaS 后端或云同步产品

## 当前 Phase 2 能力

**语音与输入**
- 设备端按住说话输入、可编辑草稿和运行中语音追加
- 语音命令层：继续、停止、标记完成、朗读结果、追加指令等工作语义命令
- STT 语音转写修正规则引擎，支持近音声学错误处理
- TTS 朗读清洗后结果，支持中文多音字处理

**任务草稿与提示构建**
- 任务草稿编辑器，包含上下文、错误日志、文件路径、命令输出和约束芯片
- Prompt Context Chunking：将任务原话、约束、上下文和 secret 占位符分块
- PromptGovernor 统一管理执行模式约束与提示长度
- 秘密信息脱敏与敏感值过滤

**执行与运行时**
- SSH password 认证；密码使用平台安全存储，不写入普通 JSON 历史
- Host、project path、Agent 命令配置
- 真实 SSH/tmux 执行：Codex CLI 使用 `-C`，Qoder CLI 使用 `-w`
- 每任务独立短 tmux session，支持断开监听与重新连接
- 原生输出观察和清洗：输出暂停进入"等待继续"，不自动判定完成
- Bridge Runtime 架构：SessionManager、TaskWatcher、RuntimeEventBus 异步解耦
- Runtime 原则：tmux 只作为传输和承载层，不作为结构化事实来源。Armin 会优先消费 RuntimeEventBus 中的结构化事件来更新任务状态、注意力状态、审批状态和结果摘要；终端原始输出只作为审计和 fallback，不直接作为任务完成或审批成功的唯一依据。

**交互与控制**
- 文本/语音追加、暂停、恢复、停止、标记完成和标记失败
- 暂停取消当前 observer，恢复重新监听同一 session
- 断开监听只移除手机侧 observer，远端 session 继续运行
- SSH 网络中断保留远端 session，进入可重新监听状态
- 终态任务可从原 Host/project path 新建重跑草稿

**输出与审计**
- 清洗脱敏后的显示摘要和 TTS 播报，保留折叠原始日志用于审计
- 结果卡片按 turn 隔离输出并倒序展示
- 端侧摘要增强实验开关与安全 fallback 接入口；生产包尚未捆绑实际模型
- 任务详情审计视图，包含交互轮次、结果、提示、原始日志和指标时间线

旧的结构化结果/批准解析器（`features/agent/parsers/`）仅保留为兼容代码和测试，不决定任务完成或触发 session cleanup。

## Runtime 设计原则

1. tmux 是 transport，不是 truth
2. 每个 task 独立 session
3. RuntimeEventBus 承载结构化事件
4. raw log 只用于审计/fallback
5. approval 分为 terminal approval 和 review decision
6. UI 消费 work state，不直接消费 raw terminal state

## 开发设置

此仓库是一个 Flutter 应用。在安装了 Flutter 的机器上：

```bash
flutter pub get
flutter test
flutter run
```

如果缺少平台文件夹，在保留现有 Dart 文件的同时添加 Android 脚手架：

```bash
flutter create --platforms=android .
```

## 文档

- [产品定位](docs/PRODUCT-POSITIONING.md)
- [规范](docs/SPEC.md)
- [架构](docs/ARCHITECTURE.md)
- [路线图](docs/ROADMAP.md)
- [Phase 2 RC 验收记录](docs/PHASE2-RC.md)
- [提示模板](docs/PROMPT_TEMPLATE.md)
- [语义输入输出完整性](docs/SEMANTIC-IO-INTEGRITY.md)
- [长任务测试](docs/LONG_RUNNING_TASK_TEST.md)
- [Tmux/Codex QA](docs/TMUX_CODEX_QA.md)

## 路线图

**第一阶段**：模拟委托循环、解析器层、历史、提示预览和指标事件。

**第二阶段**（已完成）：真实 SSH/tmux、真实 STT/TTS、原生输出观察、任务级 session 生命周期与用户语义驱动交互。Phase 2 真机主链路已通过人工验收，详见 [Phase 2 RC 记录](docs/PHASE2-RC.md)。

**第三阶段**：历史任务延续、任务级上下文延续、手动子任务组织、委托质量与注意力成本指标、可搜索/可导出的审计历史。

**第四阶段**：模块级工作器、手动任务关系整理（不做 fork/join runtime）、更多 Agent adapter、冲突风险展示。

Armin 始终不负责复杂规划、自动代码合并或 fork/join runtime。
