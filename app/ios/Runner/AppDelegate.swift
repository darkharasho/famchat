import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Background tasks begun for a message still sending (lib/chat/background_send.dart).
  private var backgroundTasks = Set<Int>()
  private var backgroundTaskChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamchatBackgroundTask") {
      let channel = FlutterMethodChannel(name: "famchat/background_task", binaryMessenger: registrar.messenger())
      backgroundTaskChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return result(nil) }
        switch call.method {
        case "begin":
          var id = UIBackgroundTaskIdentifier.invalid
          id = UIApplication.shared.beginBackgroundTask(withName: "Sending a message") {
            // Out of time: Dart closes the hub socket, then the task ends (at most a second later,
            // so iOS doesn't kill the app for overrunning).
            let raw = id.rawValue
            self.backgroundTaskChannel?.invokeMethod("expired", arguments: raw) { _ in self.endBackgroundTask(raw) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.endBackgroundTask(raw) }
          }
          if id == .invalid { return result(nil) }
          self.backgroundTasks.insert(id.rawValue)
          result(id.rawValue)
        case "end":
          if let raw = call.arguments as? Int { self.endBackgroundTask(raw) }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func endBackgroundTask(_ raw: Int) {
    guard backgroundTasks.remove(raw) != nil else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
  }
}
