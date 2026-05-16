# Armin

Armin 是一个移动优先、语音优先的 shell，用于将编码工作委托给在您的计算机上运行的基于终端的 AI 编码代理。

它不是 Codex Mobile 的替代品，也不是一个完整的终端应用。Armin 专注于交互层：捕获意图，让用户编辑和确认，构建可靠的提示，通过 SSH/tmux 发送，解析结果，并保留完整的本地审计跟踪。

## 它是什么

- 一个语音/文本任务草稿界面
- 一个提示预览和确认层
- 到 Codex CLI、Claude Code、Aider、Gemini CLI 及类似代理工具的 shell 级别桥接
- 每个任务的本地历史和审计跟踪
- 未来用于调试人与代理委托质量的指标表面

## 它不是什么

- 不是官方的 Codex Mobile 远程控制替代品
- 不是完整的终端模拟器
- 不是复杂的多代理调度器
- 不是 fork/join 运行时
- 不是自动代码合并或 git commit 系统
- 不是 SaaS 后端或云同步产品

## MVP 功能

- 带有可编辑 STT 文本的模拟语音输入
- 任务草稿编辑器，包含上下文、错误日志、文件路径、命令输出和约束芯片
- 密钥输入，具有脱敏历史和仅占位符的提示预览
- 桌面代理的固定提示模板
- 模拟代理执行，涵盖运行、需要批准、完成和失败状态
- `TASK_RESULT` 和 `NEED_APPROVAL` 块的结构化解析器
- 任务队列主页屏幕
- 任务详情审计视图，包含提示、结果、原始日志、批准记录和指标时间线

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

第一阶段证明模拟委托循环、解析器层、历史、提示预览和指标事件。

第二阶段添加真实的 SSH/tmux、真实的 STT/TTS、主机配置持久化和正在运行的任务控制。

第三阶段扩展跟进追加、中止指令、手动子任务组织和指标仪表板。

第四阶段探索模块级工作器、粗略的 fork/join 组织以及多个终端代理，同时不让 Armin 负责自动冲突合并。
