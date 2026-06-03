class AgentRuntimeConfig {
  const AgentRuntimeConfig._();

  static const pollInterval = Duration(milliseconds: 500);
  static const turnIdleThreshold = Duration(seconds: 2);
  static const reconnectThreshold = Duration(seconds: 60);
  static const maxRuntime = Duration(minutes: 20);
  static const monitorCaptureLines = 80;
  static const finalCaptureLines = 200;
}
