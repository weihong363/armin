# Projects Module Spec

`features/projects` 管某台 host 下的可执行项目路径。它是任务发送前选择工作目录的配置模块。

## 职责

- `models/project_path_config.dart`：项目路径配置和 JSON schema。
- `screens/project_path_list_screen.dart`：项目路径列表和选择/管理入口。

## 边界

- 不验证项目里的业务代码，不读取远端仓库内容。
- 不保存 secret 或 SSH 密码。
- 不决定使用哪个 CLI；CLI 来自 host 或任务执行 request。

## 修改提示

- 新增字段时同步更新 JSON store 和相关 UI 展示。
- 路径显示要优先清晰、紧凑，避免小屏 overflow。
- 与 host 设置合并展示时，仍保持数据模型分离：host 是机器，project path 是工作目录。

## 推荐测试

- `flutter test test/storage/json_task_history_store_test.dart`
- 如新增项目路径 UI 测试，放在 `test/projects/` 或相关 settings 测试中。
