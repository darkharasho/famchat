import Cocoa
import FlutterMacOS
import Sparkle

/// Starts Sparkle when the app carries a feed: release.yml writes SUFeedURL into the signed app,
/// so local builds never offer to "update" to a release.
public class FamchatUpdaterPlugin: NSObject, FlutterPlugin {
  private let controller: SPUStandardUpdaterController?

  init(controller: SPUStandardUpdaterController?) {
    self.controller = controller
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let info = Bundle.main.infoDictionary ?? [:]
    let feed = (info["SUFeedURL"] as? String) ?? ""
    let key = (info["SUPublicEDKey"] as? String) ?? ""
    let controller = feed.isEmpty || key.isEmpty
      ? nil
      : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    let channel = FlutterMethodChannel(name: "famchat/updater", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(FamchatUpdaterPlugin(controller: controller), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(controller != nil)
    case "checkForUpdates":
      controller?.checkForUpdates(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
