import CryptoKit
import EventKit
import Flutter
import UIKit
import UserNotifications

enum ArminPlatformChannels {
  static func register(messenger: FlutterBinaryMessenger) {
    TaskNotifications(messenger: messenger).register()
    SystemCalendar(messenger: messenger).register()
    ScheduledTaskWake(messenger: messenger).register()
    NativeSlm(messenger: messenger).register()
  }
}

enum ArminNotificationBridge {
  static var active: TaskNotifications?

  static func handle(response: UNNotificationResponse) {
    guard let taskId = response.notification.request.content.userInfo["taskId"] as? String else {
      return
    }
    active?.open(taskId: taskId)
  }
}

final class TaskNotifications {
  private let channel: FlutterMethodChannel
  private var pendingTaskId: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.ironion.armin/task_notifications",
      binaryMessenger: messenger
    )
    ArminNotificationBridge.active = self
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "permissionStatus": self.permissionStatus(result)
      case "requestPermission": self.requestPermission(result)
      case "show": self.show(call, result)
      case "consumePendingTaskId":
        result(self.pendingTaskId)
        self.pendingTaskId = nil
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  func open(taskId: String) {
    pendingTaskId = taskId
    channel.invokeMethod("opened", arguments: ["taskId": taskId])
  }

  private func permissionStatus(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings {
      result($0.authorizationStatus == .authorized || $0.authorizationStatus == .provisional)
    }
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, _ in result(granted)
    }
  }

  private func show(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let taskId = args["taskId"] as? String,
          let title = args["title"] as? String else {
      result(FlutterError(code: "invalid_notification", message: "Missing task notification fields.", details: nil))
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = args["body"] as? String ?? ""
    content.userInfo = ["taskId": taskId]
    let request = UNNotificationRequest(
      identifier: args["id"] as? String ?? taskId,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      error == nil ? result(nil) : result(FlutterError(code: "notification_failed", message: error?.localizedDescription, details: nil))
    }
  }
}

private final class SystemCalendar {
  private let channel: FlutterMethodChannel
  private let store = EKEventStore()
  private let defaultsKey = "armin.calendar.eventIds"

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.ironion.armin/system_calendar",
      binaryMessenger: messenger
    )
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "permissionStatus": result(self.isAuthorized)
      case "requestPermission": self.requestPermission(result)
      case "upsertEvent": self.upsert(call, result)
      case "removeEvent": self.remove(call, result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private var isAuthorized: Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) { return status == .fullAccess }
    return status == .authorized
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    if #available(iOS 17.0, *) {
      store.requestFullAccessToEvents { granted, _ in result(granted) }
    } else {
      store.requestAccess(to: .event) { granted, _ in result(granted) }
    }
  }

  private func upsert(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard isAuthorized,
          let args = call.arguments as? [String: Any],
          let taskId = args["taskId"] as? String,
          let title = args["title"] as? String,
          let startMillis = args["startAtMillis"] as? NSNumber else {
      result(false)
      return
    }
    var links = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    let event = links[taskId].flatMap(store.event(withIdentifier:)) ?? EKEvent(eventStore: store)
    event.calendar = store.defaultCalendarForNewEvents
    event.title = title
    event.notes = "[ARMIN_TASK_ID:\(taskId)]\nArmin 计划任务\n\(args["description"] as? String ?? "")"
    event.startDate = Date(timeIntervalSince1970: startMillis.doubleValue / 1000)
    event.endDate = event.startDate.addingTimeInterval(30 * 60)
    event.recurrenceRules = recurrence(args["recurrence"] as? String)
    do {
      try store.save(event, span: .thisEvent, commit: true)
      links[taskId] = event.eventIdentifier
      UserDefaults.standard.set(links, forKey: defaultsKey)
      result(true)
    } catch {
      result(FlutterError(code: "calendar_write_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func remove(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard isAuthorized,
          let args = call.arguments as? [String: Any],
          let taskId = args["taskId"] as? String else {
      result(nil)
      return
    }
    var links = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    if let id = links.removeValue(forKey: taskId), let event = store.event(withIdentifier: id) {
      try? store.remove(event, span: .futureEvents, commit: true)
    }
    UserDefaults.standard.set(links, forKey: defaultsKey)
    result(nil)
  }

  private func recurrence(_ value: String?) -> [EKRecurrenceRule]? {
    let frequency: EKRecurrenceFrequency
    switch value {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    default: return nil
    }
    return [EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)]
  }
}

private final class ScheduledTaskWake {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.ironion.armin/scheduled_tasks",
      binaryMessenger: messenger
    )
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "initialize": result(nil)
      case "schedule": self.schedule(call, result)
      case "cancel": self.cancel(call, result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func schedule(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let taskId = args["taskId"] as? String,
          let millis = args["scheduledAtMillis"] as? NSNumber else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = "Armin 计划任务"
    content.body = "计划执行时间已到，打开 Armin 继续任务。"
    content.userInfo = ["taskId": taskId]
    let interval = max(1, millis.doubleValue / 1000 - Date().timeIntervalSince1970)
    let request = UNNotificationRequest(
      identifier: "armin.schedule.\(taskId)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    )
    UNUserNotificationCenter.current().add(request) { error in result(error == nil) }
  }

  private func cancel(_ call: FlutterMethodCall, _ result: FlutterResult) {
    if let args = call.arguments as? [String: Any], let taskId = args["taskId"] as? String {
      UNUserNotificationCenter.current().removePendingNotificationRequests(
        withIdentifiers: ["armin.schedule.\(taskId)"]
      )
    }
    result(nil)
  }
}

private final class NativeSlm {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.ironion.armin/native_slm",
      binaryMessenger: messenger
    )
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capability": result(self.capability())
      case "deleteModel": result(self.deleteModel())
      case "installModel": self.install(call, result)
      case "generate": result(FlutterError(code: "native_slm_unavailable", message: "iOS llama.cpp runtime 尚未接入。", details: self.capability()))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private var modelURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("slm/model.gguf")
  }

  private func capability() -> [String: Any] {
    let size = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return [
      "available": false,
      "message": size > 0 ? "模型已安装，iOS llama.cpp runtime 尚未接入。" : "未安装端侧模型。",
      "backend": "llama.cpp",
      "modelPath": modelURL.path,
      "modelSizeBytes": size,
    ]
  }

  private func deleteModel() -> Bool {
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return true }
    return (try? FileManager.default.removeItem(at: modelURL)) != nil
  }

  private func install(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let urlText = args["url"] as? String,
          let url = URL(string: urlText), url.scheme == "https",
          let expected = args["sha256"] as? String else {
      result(FlutterError(code: "invalid_model_distribution", message: "HTTPS URL and SHA-256 are required.", details: nil))
      return
    }
    URLSession.shared.downloadTask(with: url) { temporary, _, error in
      guard let temporary = temporary, error == nil else {
        result(FlutterError(code: "model_install_failed", message: error?.localizedDescription, details: nil))
        return
      }
      do {
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw InstallError.checksum }
        try FileManager.default.createDirectory(
          at: self.modelURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: self.modelURL.path) {
          try FileManager.default.removeItem(at: self.modelURL)
        }
        try FileManager.default.moveItem(at: temporary, to: self.modelURL)
        result(self.capability())
      } catch {
        result(FlutterError(code: "model_install_failed", message: error.localizedDescription, details: nil))
      }
    }.resume()
  }

  private enum InstallError: LocalizedError {
    case checksum
    var errorDescription: String? { "模型 SHA-256 校验失败。" }
  }
}
