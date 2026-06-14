# 长任务真机测试用例

## 运行时参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `maxRuntime` | 20 min | 远端脚本最大轮询时长 |
| `turnIdleThreshold` | 2 s | 输出静默判定 turn idle |
| `autoDetachDuration` | 3 min | 手机端持续监听上限 |
| `reconnectThreshold` | 60 s | 重连判定超时 |

---

## 测试 Case 汇总

所有 case 都从空目录开始，由 Agent 从项目初始化到完整实现，模拟真实开发流程。

| # | 项目类型 | 场景 | 耗时 | 优先级 |
|---|---------|------|------|--------|
| 1 | Python CLI | 文件批量重命名工具 | 10-15 min | P0 |
| 2 | Go Web | 短链接服务 | 15-20 min | P0 |
| 3 | Node.js API | Todo REST API + 文件存储 | 12-18 min | P1 |
| 4 | Flutter App | 倒计时小组件集合 | 15-20 min | P1 |
| 5 | Python 数据分析 | CSV 报表生成脚本 | 8-12 min | P2 |

---

## Case 1：Python CLI 文件批量重命名工具（P0）

**项目初始化**：在 Host 上新建空目录，从零开始。

**任务描述**：
```
在 /home/user/projects/file-renamer 目录下用 Python 写一个命令行文件批量重命名工具。

要求：
1. 支持递归遍历目录
2. 支持按正则表达式匹配文件名
3. 支持替换、添加前缀/后缀、序号重命名三种模式
4. 支持 --dry-run 预览模式
5. 用 argparse 做参数解析
6. 包含完整的单元测试
7. 有 README 说明用法
```

**操作流程**：
```
1. 创建任务，选 Host + project path = /home/user/projects/file-renamer
2. [只分析不修改] 首轮让 Agent 先出设计方案和文件结构   输出结果只有中间的表格内容
3. 追加 "按方案开始写代码，先实现核心重命名逻辑 + 测试"   输出结果只去阅读代码变更
4. 首轮完成后，追加 "加上 CLI 入口和参数解析"
5. 再追加 "写 README，包含所有使用示例"
6. 暂停 1 分钟，恢复后追加 "运行全部测试确认通过"
7. 标记完成
```

**验证点**：
- 从空目录成功初始化项目结构
- 多轮追加每次进入同一 session
- Agent 理解跨轮上下文（不会忘记前面的设计）
- 最终产物可运行：`python -m pytest` 通过
- auto-detach 触发后重连看到完整输出

---

## Case 2：Go 短链接服务（P0）

**项目初始化**：在 Host 上新建空目录，从零开始。

**任务描述**：
```
在 /home/user/projects/shortlink 目录下用 Go 写一个短链接服务。

要求：
1. 用 net/http 标准库，不引入第三方框架
2. POST /shorten 接收长链接，返回短码
3. GET /{code} 重定向到原始链接
4. 短码生成用 base62 + 自增 ID
5. 数据存内存 map（后续可切换存储）
6. 包含完整的单元测试
7. 有 README 和 Makefile
```

**操作流程**：
```
1. 创建任务，选 Host + project path = /home/user/projects/shortlink
2. [最小改动] [修改后运行测试] 发送任务
3. 首轮完成后，在电脑端 curl 验证 POST + GET 是否正常
4. 追加 "加一个 GET /stats/{code} 返回访问次数统计"
5. 追加语音 "读一下当前进度"
6. 断网 30 秒，确认自动进入 observerDetached
7. 重新监听，追加 "写 README 和 Makefile"
8. 标记完成
```

**验证点**：
- 从零搭建 Go 项目结构（go mod init + 代码）
- 网络中断后自动进入 observerDetached，不丢 session
- 重连后输出连贯
- 电脑端可独立验证 API 功能
- 完成后 session cleanup 正常

---

## Case 3：Node.js Todo REST API（P1）

**项目初始化**：在 Host 上新建空目录，从零开始。

**任务描述**：
```
在 /home/user/projects/todo-api 目录下用 Node.js + Express 写一个 Todo REST API。

要求：
1. CRUD 完整：创建、列表、更新、删除
2. JSON 文件持久化存储
3. 输入校验（标题必填、状态枚举值）
4. 错误处理中间件
5. CORS 支持
6. 包含 API 测试（用 supertest）
7. 有 README 和 package.json scripts
```

**操作流程**：
```
1. [允许修改] [修改后运行测试] 发送任务
2. 首轮后追加 "把标题不能为空改为至少 3 个字符"
3. 暂停，等 2 分钟恢复
4. 追加 "加一个按状态筛选的查询参数 ?status=done"
5. 追加语音 "跑一下测试"
6. 标记完成
```

**验证点**：
- npm init + 安装依赖 + 项目结构
- 暂停恢复后 session 不丢，输出连续
- 语音追加 "跑一下测试" 正确触发 npm test
- 约束修改被遵守

---

## Case 4：Flutter 倒计时小组件集合（P1）

**项目初始化**：在 Host 上用 `flutter create` 初始化。

**任务描述**：
```
在 /home/user/projects/countdown_widgets 目录下创建一个 Flutter package，包含一组倒计时小组件。

要求：
1. 圆形倒计时（CircularCountdown）
2. 线性进度条倒计时（LinearCountdown）
3. 数字翻页倒计时（FlipCountdown）
4. 每个组件支持自定义时长、颜色、尺寸
5. 回调 onFinished
6. 包含 widget 测试
7. 有 example app 展示所有组件
8. README 带截图说明
```

**操作流程**：
```
1. [最小改动] [修改后运行测试] 发送任务
2. 首轮完成后追加 "先只做圆形和线性两个，做完等我确认"
3. 等待进入 idle，追加 "圆形组件加个动画效果"
4. 再追加 "现在做数字翻页，用 Stack + AnimatedSwitcher"
5. 中途锁屏 3 分钟，解锁后确认 auto-detach 已触发
6. 重新监听，追加 "写 example app 和 README"
7. 标记完成
```

**验证点**：
- flutter create 初始化 + 依赖配置
- 锁屏后 auto-detach 触发，解锁重连正常
- 多轮追加跨轮上下文保持
- widget 测试可运行通过

---

## Case 5：Python CSV 报表生成脚本（P2）

**项目初始化**：在 Host 上新建空目录，从零开始。

**任务描述**：
```
在 /home/user/projects/csv-reporter 目录下用 Python 写一个 CSV 数据报表生成器。

要求：
1. 读取 CSV 文件，自动检测列类型
2. 按指定列分组聚合（sum/count/avg/min/max）
3. 输出格式化的文本表格
4. 输出 Markdown 表格
5. 生成简单柱状图（ASCII art）
6. 包含单元测试和示例 CSV
7. 有 README
```

**操作流程**：
```
1. [只分析不修改] 首轮让 Agent 出设计方案
2. 追加 "按方案实现，先建好项目结构和一个示例 CSV"
3. 追加 "实现读取和聚合功能 + 测试"
4. 追加 "加 Markdown 输出格式"
5. 追加 "加 ASCII 柱状图，用 █ 字符"
6. 追加语音 "完成了吗？跑一下测试"
7. 标记完成
```

**验证点**：
- 多阶段渐进式开发
- 首轮只分析不修改的约束生效
- 语音追加正确进入 session
- 最终产物：`python main.py sample.csv --group-by category --agg sum --output markdown` 可运行

---

## 推荐执行顺序

1. **Case 1**（Python CLI）— 最轻量，快速跑通完整闭环
2. **Case 2**（Go 短链接）— 覆盖网络中断 + 重连
3. **Case 3**（Node.js API）— 暂停恢复 + 语音操作
4. **Case 4**（Flutter 组件）— 锁屏 + auto-detach 验证
5. **Case 5**（Python 报表）— 渐进式多轮开发

---

## 回归记录模板

| 项目 | Codex | Qoder |
|------|-------|-------|
| Host password 连接成功 |  |  |
| 从空目录初始化项目 |  |  |
| 首轮任务进入等待继续 |  |  |
| 多轮追加进入同一 session |  |  |
| 跨轮上下文保持（不忘记前面的设计） |  |  |
| auto-detach 3min 触发 |  |  |
| 断开后重连 session 不丢 |  |  |
| 网络中断自动进入 observerDetached |  |  |
| 锁屏后重连正常 |  |  |
| 暂停后可恢复 |  |  |
| 语音追加正确执行 |  |  |
| "读一下进度" TTS 正常 |  |  |
| 停止后 cleanup |  |  |
| 标记完成后 cleanup |  |  |
| 最终产物可运行/测试通过 |  |  |
| 结果卡片语义正确 |  |  |
| 小喇叭朗读当前结果 |  |  |

- App version / build number:
- Android 设备型号与系统版本:
- Host 类型与 tmux 版本:
- Agent command 与版本:
- project path:
- 失败时 Raw Log 与 `tmux capture-pane`:
