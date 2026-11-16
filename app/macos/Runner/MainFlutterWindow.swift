import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // famchat/window: the in-app title bar's requests (lib/window/window_controls.dart).
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // The traffic lights stay; the title and the title bar's own background go, and the app runs
    // up underneath them. The app keeps a blank band there (lib/window/title_bar.dart).
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    // The smallest window the phone layout still fits in.
    self.contentMinSize = NSSize(width: 380, height: 500)

    let channel = FlutterMethodChannel(
      name: "famchat/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "state":
        result(self.windowState())
        return
      case "startDrag":
        if let event = NSApp.currentEvent,
          event.type == .leftMouseDown || event.type == .leftMouseDragged
        {
          self.performDrag(with: event)
        }
      case "toggleMaximize":
        // What "double-click a window's title bar to" says in System Settings.
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": self.miniaturize(nil)
        case "None": break
        default: self.zoom(nil)
        }
      case "minimize":
        self.miniaturize(nil)
      case "close":
        self.performClose(nil)
      case "startResize", "showMenu":
        break
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    windowChannel = channel
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) {
        [weak self] _ in
        guard let self = self else { return }
        self.windowChannel?.invokeMethod("stateChanged", arguments: self.windowState())
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func windowState() -> [String: Bool] {
    return ["maximized": isZoomed, "fullScreen": styleMask.contains(.fullScreen)]
  }
}
