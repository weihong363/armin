class AgentRuntimeConfig {
  const AgentRuntimeConfig._();

  static const pollInterval = Duration(milliseconds: 500);
  static const turnIdleThreshold = Duration(seconds: 2);
  static const reconnectThreshold = Duration(seconds: 60);
  static const maxRuntime = Duration(minutes: 20);
  static const monitorCaptureLines = 80;
  static const finalCaptureLines = 200;

  /// 手机端持续监听的最长时长。超过此时长后自动断开监听以节省
  /// 手机性能和电量，远端 tmux 会话继续运行。用户可随时重新监听。
  /// 设为 Duration.zero 可禁用自动断开。
  static const autoDetachDuration = Duration(minutes: 3);
}
