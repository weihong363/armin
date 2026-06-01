# Voice Module Spec

`features/voice` 管设备 STT/TTS、语音设置、播报策略和语音能力降级。任务语义命令解析不在这里，而在 `features/tasks/services/voice_task_command_processor.dart`。

## 职责

- `services/voice_service.dart`：语音能力抽象。
- `services/device_voice_service.dart`：真实设备 STT/TTS 实现。
- `services/task_speech_policy.dart`：决定什么任务事件需要播报，以及播报文本如何取得。
- `screens/voice_settings_screen.dart`：语音风格设置和预览。
- `widgets/*`：语音输入相关 UI。

## 边界

- 不直接操作任务状态或远端会话；任务动作通过 `ArminAppState`。
- 播报内容应使用页面展示文本或任务摘要管线再清洗精炼，不直接读原始日志。
- 设备 TTS/STT 失败要显式抛出或展示错误，不要静默成功。
- 中英文混读优化应保留可测试的清洗文本路径，方便 IDE 内迭代。

## 修改提示

- 改播报内容：先确认 `TaskSpeechPolicy` 和 `OutputSummaryProvider` 的输入输出。
- 改声音风格：保证预览失败不 crash，并保留手动设置可更新。
- 改语音命令词：去 `VoiceTaskCommandProcessor`，不要把任务动作塞进设备语音服务。

## 推荐测试

- `flutter test test/features/voice/services/task_speech_policy_test.dart`
- `flutter test test/features/voice/screens/voice_settings_screen_test.dart`
- `flutter test test/features/voice/services/device_voice_service_test.dart`
- `flutter test test/voice/mock_voice_service_test.dart`
