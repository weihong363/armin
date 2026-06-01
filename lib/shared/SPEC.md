# Shared Module Spec

`shared` 放无业务状态的主题、通用 widget 和通用工具。这里的组件应足够稳定，不能依赖某个 feature 的模型或服务。

## 职责

- `theme/armin_theme.dart`：全局视觉 token 和主题。
- `widgets/*`：跨页面复用的轻量 UI。
- `utils/*`：无业务状态的通用工具。

## 边界

- 不依赖 `features/*` 的业务模型。
- 不直接读写 app state、storage、voice 或 agent service。
- 不放只被一个页面使用且含业务语义的组件；这类组件留在对应 feature。

## 修改提示

- 改主题时，检查小屏、键盘弹起、深浅色和状态 badge 对比度。
- 通用 widget API 保持小而明确，避免把业务判断作为参数堆进去。
- 视觉调整优先尊重现有手写风格和克制配色。

## 推荐测试

- `flutter test test/shared`
- `flutter test test/widget_test.dart`
