# Armin Phase 2.5 Wireframe

本文档用于低保真表达 Phase 2.5 的信息架构和页面布局。它不讨论 Flutter 实现，不使用具体组件类名，不进入视觉细节。重点是页面结构、信息优先级，以及用户第一眼看到什么。

## 1. 线框图设计目标

Phase 2.5 wireframe 的目标：

- 从 Agent Session First 转向 Task First。
- 从大麦克风首页转向 Task Inbox。
- 从运行时控制台转向任务进展与决策面板。
- 从主动查看日志转向响应任务请求。
- 从“操作 Agent”转向“管理工作”。

核心判断标准：用户打开 App 后，是否能先理解“哪些工作需要我”，而不是先理解“哪个 session 在跑”。

## 2. 首页/任务收件箱线框图

### 方案 A：任务收件箱优先

```text
┌────────────────────────────────┐
│ Armin                          │
│ Your task inbox for AI agents. │
│ 2 need attention · 3 running   │
├────────────────────────────────┤
│ Needs Attention                 │
│ ┌────────────────────────────┐ │
│ │ Payment refactor            │ │
│ │ Needs your decision         │ │
│ │ Choose fix strategy         │ │
│ │ [Review]                    │ │
│ └────────────────────────────┘ │
│ ┌────────────────────────────┐ │
│ │ Login cleanup               │ │
│ │ Waiting for next instruction│ │
│ │ Tests failed after patch    │ │
│ │ [Continue]                  │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ In Progress                     │
│ ┌────────────────────────────┐ │
│ │ Log analysis                │ │
│ │ Running · 12 min            │ │
│ │ Last update: found parser...│ │
│ │ [Open]                      │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ Recently Completed              │
│ ┌────────────────────────────┐ │
│ │ PRD draft                   │ │
│ │ Completed · Ready to review │ │
│ │ [View result]               │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ [ + New Task ]   [ Hold to Talk]│
└────────────────────────────────┘
```

第一眼传达的心智：Armin 是一个任务收件箱，先显示需要用户注意的工作，再显示正在推进和已完成的工作。

适合用户：同时运行多个 Agent 任务、需要快速分配注意力、希望离开电脑后回来处理工作的人。

风险：如果用户只运行单个任务，分区可能显得过重；如果任务数量少，首页需要有很好的空态和轻量密度。

### 方案 B：今日工作优先

```text
┌────────────────────────────────┐
│ Armin                          │
│ Work keeps moving.             │
│ Today: 5 tasks · 2 waiting     │
├────────────────────────────────┤
│ Waiting for you                 │
│ ┌────────────────────────────┐ │
│ │ Payment refactor            │ │
│ │ Needs approval              │ │
│ │ Approve shell command?      │ │
│ │ [Decide]                    │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ Today's active work             │
│ ┌────────────────────────────┐ │
│ │ API cleanup                 │ │
│ │ Running · checking tests    │ │
│ │ Last update 3 min ago       │ │
│ └────────────────────────────┘ │
│ ┌────────────────────────────┐ │
│ │ Docs update                 │ │
│ │ Waiting for next instruction│ │
│ │ Draft generated             │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ Done today                      │
│ ┌────────────────────────────┐ │
│ │ Release checklist           │ │
│ │ Completed · 11:42           │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ [ + New Task ]   [ Add Context ]│
└────────────────────────────────┘
```

第一眼传达的心智：Armin 是今天的 Agent 工作面板，重点是“今天哪些工作在推进、哪些需要我”。

适合用户：把 Armin 当作日常工作流的一部分、每天多次打开、需要按当天工作状态扫描的人。

风险：容易偏向日报/工作台心智；如果没有“今天”之外的任务入口，历史任务和长期任务可能被弱化。

### 推荐

优先采用方案 A：任务收件箱优先。它最直接支持 Phase 2.5 的核心转向：把用户注意力先给到 Needs Attention，而不是当前 session、麦克风或日志。

## 3. 任务卡片线框图

任务卡片一级信息必须突出：

- 任务标题
- 人类可读状态
- 最新进展
- 是否需要用户处理
- 下一步动作

host、tmux、SSH、CLI、raw logs、runtime lost、cleanup session 不作为主层级信息。

### Needs Attention

```text
┌────────────────────────────────┐
│ Payment refactor               │
│ Needs your decision            │
│                                │
│ Agent found two possible fixes.│
│ Choose whether to patch minimal│
│ logic or refactor shared helper│
│                                │
│ Next: Review strategy          │
│ [Review]        [Add context]  │
└────────────────────────────────┘
```

### In Progress

```text
┌────────────────────────────────┐
│ Log analysis                   │
│ Running · 12 min               │
│                                │
│ Last update: identified noisy  │
│ polling events in metrics path │
│                                │
│ No action needed now           │
│ [Open]          [Pause]        │
└────────────────────────────────┘
```

### Completed

```text
┌────────────────────────────────┐
│ PRD draft                      │
│ Completed · ready to review    │
│                                │
│ Draft created and checklist    │
│ added. Validation not run.     │
│                                │
│ Next: Accept or continue       │
│ [View result]   [Continue]     │
└────────────────────────────────┘
```

## 4. 任务详情线框图

任务详情页目标：

> 任务进展 + 决策界面

而不是：

> 运行时控制台

### 方案 A：摘要优先

适合快速检查。

```text
┌────────────────────────────────┐
│ Payment refactor               │
│ In Progress · 18 min           │
├────────────────────────────────┤
│ Status Summary                 │
│ Agent is checking refund flow  │
│ and comparing duplicate logic. │
├────────────────────────────────┤
│ What changed since last check  │
│ - Found duplicated logic       │
│ - Test failed in refund flow   │
│ - Opened minimal patch path    │
├────────────────────────────────┤
│ Next Action                    │
│ No action needed now           │
│ [Pause] [Stop]                 │
├────────────────────────────────┤
│ Add Context                    │
│ [Hold to Talk] [Type a note]   │
├────────────────────────────────┤
│ Activity Timeline              │
│ 09:20 Started                  │
│ 09:24 Read files               │
│ 09:31 Found issue              │
├────────────────────────────────┤
│ Result / Deliverable           │
│ Latest output summary...       │
│ [Read aloud] [Expand]          │
├────────────────────────────────┤
│ Advanced / Debug               │
│ Logs, tmux, reconnect...       │
└────────────────────────────────┘
```

用户第一眼看到：任务标题、状态、当前正在做什么、最近发生了什么。

被降级的信息：logs、metrics、tmux commands、host、SSH、reconnect、cleanup session、raw runtime details。

被提升的操作：Add Context、Pause、Stop、Result review。

### 方案 B：决策优先

适合需要用户审批或选择方案的任务。

```text
┌────────────────────────────────┐
│ Payment refactor               │
│ Needs your decision            │
├────────────────────────────────┤
│ Next Action                    │
│ Choose fix strategy            │
│                                │
│ Option A: minimal patch        │
│ Option B: shared helper refactor│
│                                │
│ [Choose A] [Choose B]          │
│ [Add context]                  │
├────────────────────────────────┤
│ Why this is needed             │
│ Agent found two valid paths.   │
│ Minimal patch is safer today;  │
│ refactor may reduce future risk│
├────────────────────────────────┤
│ What changed since last check  │
│ - Located refund duplication   │
│ - Confirmed tests affected     │
├────────────────────────────────┤
│ Status Summary                 │
│ Waiting for your decision      │
├────────────────────────────────┤
│ Result / Current output        │
│ Summary of current findings... │
├────────────────────────────────┤
│ Advanced / Debug               │
│ Logs, tmux, reconnect...       │
└────────────────────────────────┘
```

用户第一眼看到：任务正在等自己做什么决定。

被降级的信息：运行中日志、tmux、host、CLI、raw output、metrics。

被提升的操作：审批、方案选择、追加上下文。

### 推荐

任务详情应根据状态切换重点：

- 普通运行中任务优先摘要优先模式。
- Needs Attention / Need Approval / Waiting Continue 优先决策优先模式。

## 5. 追加上下文流程线框图

原则：

- 聊天不应该是独立页面。
- 追加上下文应该是全局能力。
- 用户可以在首页、任务详情、语音、文字入口中追加。

### Flow A: 从任务详情追加

```text
Task Detail
-> Hold to Talk / Type
-> Confirm target task
-> Send
-> Task timeline updates
```

Low-fidelity layout:

```text
┌────────────────────────────────┐
│ Add context to Payment refactor│
├────────────────────────────────┤
│ Target                         │
│ Payment refactor               │
├────────────────────────────────┤
│ Say or type one instruction    │
│ ┌────────────────────────────┐ │
│ │ Please keep changes minimal │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ [Hold to Talk]      [Send]     │
└────────────────────────────────┘
```

任务详情中通常可以自动使用当前任务，但仍应在 sheet/header 中显示目标任务，避免用户误以为在和通用机器人对话。

### Flow B: 从首页追加

```text
Home
-> Hold to Talk
-> Select target task if needed
-> Send
-> Task card updates
```

Low-fidelity layout:

```text
┌────────────────────────────────┐
│ Add context                    │
├────────────────────────────────┤
│ Which task is this for?        │
│ ○ Payment refactor · waiting   │
│ ○ Log analysis · running       │
│ ○ PRD draft · completed        │
├────────────────────────────────┤
│ Instruction                    │
│ ┌────────────────────────────┐ │
│ │ Also avoid changing schema. │ │
│ └────────────────────────────┘ │
├────────────────────────────────┤
│ [Cancel]              [Send]   │
└────────────────────────────────┘
```

什么时候需要选择目标任务：

- 有多个活跃任务。
- 首页没有明确选中任务。
- 语音内容没有明确指向某个任务。
- 当前任务已完成，但用户可能想继续另一个任务。

什么时候可以自动使用当前任务：

- 用户从任务详情页发起。
- 首页只有一个活跃任务。
- 用户从某张任务卡片的 Add Context 入口发起。
- 系统已经明确显示“将追加到：任务标题”。

如何避免用户以为自己在和通用聊天机器人对话：

- 每个输入面板都显示目标任务。
- 文案使用“Add context to this task”，不使用“Ask Armin anything”。
- 发送后更新任务时间线和任务卡片，而不是进入聊天线程。
- 语音按钮旁边显示任务名或当前目标。

## 6. 调试/高级面板线框图

普通用户默认看不到复杂运行时细节；开发者排障时仍能找到 SSH、host、tmux、raw logs、reconnect、cleanup session、runtime status。

```text
┌────────────────────────────────┐
│ Advanced / Debug               │
│ Hidden by default              │
├────────────────────────────────┤
│ ▸ Runtime details              │
└────────────────────────────────┘
```

Expanded:

```text
┌────────────────────────────────┐
│ Advanced / Debug               │
│ For troubleshooting only       │
├────────────────────────────────┤
│ Runtime status                 │
│ Connection paused              │
│                                │
│ Execution method               │
│ Codex on configured host       │
│                                │
│ Remote session                 │
│ tmux: armin-task-123           │
│                                │
│ Raw logs                       │
│ [View logs]                    │
│                                │
│ Recovery                       │
│ [Reconnect] [Cleanup session]  │
└────────────────────────────────┘
```

关键点：Debug 是“可找到”，不是“主叙事”。

## 7. 首次使用状态

首次打开 App 时不应先展示复杂配置。目标是让用户理解：

> Create a task, let it run, come back when it needs you.

### 空首页

```text
┌────────────────────────────────┐
│ Armin                          │
│ Work keeps moving after you    │
│ leave.                         │
├────────────────────────────────┤
│ No active tasks yet            │
│                                │
│ Create a task, send it to your │
│ local or China-friendly Agent, │
│ then come back when it needs   │
│ your input.                    │
│                                │
│ [Create first task]            │
├────────────────────────────────┤
│ Setup                          │
│ Execution environment not ready│
│ [Configure when needed]        │
└────────────────────────────────┘
```

第一次创建任务入口：

```text
┌────────────────────────────────┐
│ What should keep moving?       │
├────────────────────────────────┤
│ ┌────────────────────────────┐ │
│ │ Describe the task...        │ │
│ └────────────────────────────┘ │
│                                │
│ [Type] [Hold to Talk]          │
│                                │
│ Setup can be completed before  │
│ sending the task.              │
└────────────────────────────────┘
```

配置主机/项目路径的低干扰提示：

```text
┌────────────────────────────────┐
│ Ready to send?                 │
├────────────────────────────────┤
│ Armin needs one execution host │
│ and project folder before this │
│ task can run.                  │
│                                │
│ [Set up execution] [Save draft]│
└────────────────────────────────┘
```

原则：先让用户理解任务委派，再在发送前提示必要配置。

## 8. 线框图总结

推荐优先采用：

- Home: Option A, Task Inbox First。
- Task Detail: 状态自适应，运行中使用 Summary First，需要用户处理时使用 Decision First。

必须先改的页面：

- Home / Task Inbox。
- Task Card variants。
- Task Detail top section。
- Add Context entry。
- Advanced / Debug collapse。

可以保留的内容：

- 当前任务详情中的结果、时间线、日志、指标能力。
- 语音输入和语音播报。
- SSH/tmux 真实执行链路。
- 主机和项目目录设置。

必须降级的信息：

- host
- tmux
- SSH
- CLI
- raw logs
- metrics
- runtime lost
- reconnect
- cleanup session
- prompt preview

必须提升的交互：

- Needs Attention review。
- Add Context。
- Next Action。
- Accept / Continue / Pause / Stop。
- What changed since last check。

Phase 2.5 的线框图方向不是把 Armin 变成项目管理工具，而是让真实 Agent 执行能力被一个更清晰的任务收件箱和任务决策界面包住。
