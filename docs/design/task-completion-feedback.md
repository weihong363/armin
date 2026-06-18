# 任务完成反馈：振动 + 自定义提示音

> 状态：设计阶段  
> 目标：任务执行完成或失败时，通过振动和自定义提示音通知用户

---

## 功能概述

当 Agent 上报任务完成（或用户手动标记完成/失败）时，触发两项反馈：

1. **振动**：`HapticFeedback.heavyImpact()`，Flutter SDK 内置，零额外依赖
2. **自定义提示音**：播放本地 MP3 音频文件（`assets/sounds/` 目录）

两项反馈独立触发，后续可通过设置页分别开关。

---

## 触发路径

任务进入终端状态有 4 条路径，全部需要触发：

| 路径 | 触发点 | 目标状态 |
|------|--------|----------|
| A. Agent 上报完成 | `armin_app_state.dart` `startTaskExecution` 流式回调 L1027 | `TaskStatus.completed` |
| B. 用户手动标记完成 | `markTaskCompleted()` L920 | `TaskStatus.userCompleted` |
| C. Agent 上报失败 | `startTaskExecution` `onError` L1057 | `TaskStatus.failed` |
| D. 用户手动标记失败 | `markTaskFailed()` L951 | `TaskStatus.userFailed` |

每条路径在状态变更 + 持久化完成后触发反馈，与 TTS 语音播报（`_queueTaskSpeech`）同级插入。

---

## 架构设计

### 新增文件

```
lib/shared/task_sound_player.dart    # 音频播放工具类（单例）
assets/sounds/task_complete.mp3      # 完成提示音
assets/sounds/task_failed.mp3        # 失败提示音（可选，可复用完成音效）
```

### TaskSoundPlayer 设计

```dart
class TaskSoundPlayer {
  // AudioPlayer 单例，避免重复创建播放器
  // playComplete() — 播放 assets/sounds/task_complete.mp3
  // playFailed()   — 播放 assets/sounds/task_failed.mp3
  // dispose()      — 释放资源
}
```

**为什么抽成独立类**：
- `AudioPlayer` 创建/销毁有成本，单例复用
- 避免 `armin_app_state.dart` 直接依赖音频细节
- 未来换包或改文件名只改一处

### 调用方式

在 `_notifyTaskCompletion` 方法中统一处理：

```
检测到完成/失败状态
  → HapticFeedback.heavyImpact()        // 振动
  → TaskSoundPlayer.playComplete()      // 提示音（完成）
  或 TaskSoundPlayer.playFailed()       // 提示音（失败）
```

---

## 依赖变更

### pubspec.yaml

```yaml
dependencies:
  audioplayers: ^6.1.0   # 播放自定义音频

flutter:
  assets:
    - assets/sounds/      # 新增音频资源目录
```

### 选型理由

- `audioplayers`：轻量、API 简单、社区活跃，适合短提示音播放
- `HapticFeedback`：Flutter SDK 内置，不需要任何包

---

## 音频文件要求

| 属性 | 要求 |
|------|------|
| 格式 | MP3（兼容性好）或 WAV |
| 时长 | 1–3 秒，不宜过长 |
| 音量 | 适中，与系统通知音量一致 |
| 存放 | `assets/sounds/` 目录 |

音频文件由开发者自行准备（或从免费音效素材获取），代码侧只负责加载和播放。

---

## 改动范围汇总

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `pubspec.yaml` | 修改 | 加 `audioplayers` 依赖 + `assets/sounds/` 资源声明 |
| `assets/sounds/task_complete.mp3` | 新增 | 完成提示音 |
| `assets/sounds/task_failed.mp3` | 新增 | 失败提示音 |
| `lib/shared/task_sound_player.dart` | 新增 | 音频播放工具类 |
| `lib/core/services/armin_app_state.dart` | 修改 | 在 4 条完成/失败路径中插入振动 + 音效调用 |

---

## 平台兼容性

| 平台 | 振动 | 提示音 |
|------|:---:|:---:|
| Android 真机 | ✅ | ✅ |
| iOS 真机 | ✅ | ⚠️ 需检查音频会话权限 |
| 模拟器 | 静默 | 静默 |
| 测试环境 | 空操作 | 空操作（单例可 mock） |

`HapticFeedback` 在非真机环境自动降级为空操作。`audioplayers` 在无法播放时抛出异常，`TaskSoundPlayer` 内部捕获并静默处理。

---

## 后续扩展

| 方向 | 说明 |
|------|------|
| 设置页开关 | 振动开关 + 提示音开关，持久化到偏好存储 |
| 多场景音效 | 审批需要处理、任务暂停等场景各自配置不同音效 |
| 自定义音效 | 让用户从文件选择器导入自己的音频替换默认音效 |
| 防重复 | 同一任务短时间内多次回调时去重，避免连续振动/播放 |
