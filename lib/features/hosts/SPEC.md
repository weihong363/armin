# Hosts Module Spec

`features/hosts` 管远端主机配置。它描述如何连接机器，不负责选择具体项目目录，也不负责执行任务。

## 职责

- `models/host_config.dart`：主机、认证、CLI、tmux、shell wrapper、PATH 配置。
- `screens/host_list_screen.dart`：主机列表、默认主机、入口。
- `screens/host_form_screen.dart`：主机新增、编辑、连接测试。
- `services/*`：主机相关辅助能力。

## 边界

- Host password 只在运行时和安全存储中存在，不能写进普通 JSON 历史。
- Project path 属于 `features/projects`，不要混在 host 表单里扩展复杂项目管理。
- 连接测试只验证基础可用性，不启动真实任务。

## 修改提示

- 改认证字段时，同步检查 `SecurePasswordStore`、`HostConfig.toSafePersistedCopy` 和 JSON store。
- 改 agent command 或 PATH 时，确认 `SSHAgentSessionService` 的 request 字段仍被正确传递。
- 删除主机或改默认主机时，检查关联 project path 和任务历史展示是否仍可读。

## 推荐测试

- `flutter test test/hosts/host_config_test.dart`
- `flutter test test/hosts/host_form_screen_test.dart`
- `flutter test test/hosts/host_list_screen_test.dart`
- `flutter test test/runtime`
