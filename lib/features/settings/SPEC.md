# Settings Module Spec

`features/settings` 是配置入口聚合层。它负责把主机、项目路径、语音、历史等设置入口组织清楚，不承载各配置项的核心业务逻辑。

## 职责

- `screens/settings_screen.dart`：设置首页和配置入口分组。

## 边界

- 不在 settings 页里直接实现 host/project/voice 的编辑逻辑。
- 不把右下角任务级入口和全局设置入口混为一类。
- 配置分组应帮助用户理解：机器连接、项目目录、语音、历史/审计分别是什么。

## 修改提示

- 改设置分组时，检查首页、右上角设置图标、右下角入口之间的语义一致性。
- 新增入口时，先确认目标模块已有 screen；settings 只做导航。
- 避免把短期实验开关散落在多个页面。

## 推荐测试

- `flutter test test/settings/settings_screen_test.dart`
- 涉及目标模块时追加对应模块测试。
