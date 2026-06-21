# Core Module Spec

`core` 放跨 feature 的应用状态、基础模型和存储接口。它可以依赖 feature 的数据模型，但不应该包含具体页面 UI。

## 职责

- `models/task_status.dart`：任务状态枚举和状态语义。
- `services/armin_app_state.dart`：应用状态编排层，负责加载、保存、任务执行控制、语音播报入口和运行中订阅。
- `storage/*`：历史、主机、项目路径的持久化接口和实现。

## 边界

- 不在 `core` 里实现具体屏幕交互。
- 不在 storage 层做语义摘要、终端清洗或语音规则。
- `ArminAppState` 可以协调 agent、voice、tasks，但具体算法应留在对应 feature service。
- 密码和 secret 不应进入普通 JSON 历史；新增字段时同步检查 `TaskSession.toJson` 和 store 测试。

## 修改提示

- 改任务生命周期：先看 `TaskStatusMachine`，再改 `ArminAppState`。
- 改持久化 schema：同步更新 SQLite schema 与对应 Runtime/Store 测试。
- 改运行控制：检查 `AgentSessionService` 契约、history 详情页按钮、对应 app state 测试。

## 推荐测试

- `flutter test test/core/armin_app_state_task_control_test.dart`
- `flutter test test/runtime`
- `flutter test test/tasks/task_status_machine_test.dart`
