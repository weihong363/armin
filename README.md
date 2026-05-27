# Armin

Armin 是一个移动优先、语音优先的 shell，用于将编码工作委托给在您的计算机上运行的基于终端的 AI 编码代理。

它不是 Codex Mobile 的替代品，也不是一个完整的终端应用。Armin 专注于交互层：捕获意图，让用户编辑和确认，通过 SSH/tmux 驱动远端 Agent，观察原生输出，并保留完整的本地审计跟踪。

> **Armin 的目标不是统一 AI 工具，而是统一用户的工作语义：让用户用自己的语言描述、约束、推进、恢复、停止和确认工作，再由不同 Agent 去执行。**

## 它是什么

- 一个语音/文本任务草稿界面
- 一个提示预览和确认层
- 到 Codex CLI、Qoder CLI 及后续终端 Agent 的 shell 级别桥接
- 每个任务的本地历史和审计跟踪
- 未来用于调试人与代理委托质量的指标表面

## 它不是什么

- 不是官方的 Codex Mobile 远程控制替代品
- 不是完整的终端模拟器
- 不是复杂的多代理调度器
- 不是 fork/join 运行时
- 不是自动代码合并或 git commit 系统
- 不是 SaaS 后端或云同步产品

## 当前 Phase 2 能力

- 设备端按住说话输入、可编辑草稿和运行中语音追加
- 任务草稿编辑器，包含上下文、错误日志、文件路径、命令输出和约束芯片
- SSH password 认证；密码使用平台安全存储，不写入普通 JSON 历史
- Host、project path、tmux/PATH 环境和 Agent 命令配置
- 真实 SSH/tmux 执行：Codex CLI 使用 `-C`，Qoder CLI 使用 `-w`
- 每个任务独立的短 tmux session，支持断开监听与重新连接
- 原生输出观察和清洗：输出暂停进入“等待继续”，不自动判定完成
- 继续追加、暂停、恢复、停止、标记完成和标记失败
- 追加面板中的基础语义语音动作：继续、停止、完成、恢复和约束提取
- 清洗脱敏后的显示摘要和 TTS 播报，保留折叠原始日志用于审计
- 实验性的端侧摘要增强开关与安全 fallback 接入口；模型 runner 尚待接入
- 任务队列主页屏幕
- 任务详情审计视图，包含交互轮次、结果、提示、原始日志和指标时间线

旧的结构化结果/批准解析器仅保留为兼容代码和测试，不是当前真实执行主流程的完成判据。

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

- [规范](docs/SPEC.md)
- [架构](docs/ARCHITECTURE.md)
- [提示模板](docs/PROMPT_TEMPLATE.md)
- [路线图](docs/ROADMAP.md)

## 路线图

第一阶段证明了模拟委托循环、解析器层、历史、提示预览和指标事件。

第二阶段正在收口真实 SSH/tmux、真实 STT/TTS、原生输出观察、任务级 session 生命周期以及用户语义驱动的持续交互。

接下来的 Phase 2 工作包括真机端到端验收、语义语音动作扩词与审计、输出摘要与中英文 TTS 提升，以及为实验开关接入实际端侧小模型 runner。小模型只提炼适合展示和播报的重点，不替代远端 Agent 执行代码任务。

后续阶段再考虑历史任务延续、更多 Agent adapter 和委托质量度量；Armin 仍不负责复杂规划、自动合并或 fork/join runtime。
