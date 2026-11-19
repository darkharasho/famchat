import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  // famchat/window: the in-app title bar's requests (lib/window/window_controls.dart).
  private var windowChannel: FlutterMethodChannel?
  // "Keep running in the menu bar": closing hides the window (setCloseToTray from Dart).
  private var closeToTray = false
  private var hiddenToTray = false
  // The menu bar item while the setting is on: the glyph, and the unread count as its title.
  private var statusItem: NSStatusItem?

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

    // Open where and at the size it was last time: AppKit saves the frame to the user defaults as
    // the window moves and resizes, and the autosave name restores it. After the setFrame above,
    // so the saved frame wins over the nib's; setFrameUsingName makes the restore explicit and
    // keeps the default frame when nothing is saved yet. AppKit keeps the frame on screen.
    let autosaveName = "FamChatMainWindow"
    self.setFrameUsingName(autosaveName)
    self.setFrameAutosaveName(autosaveName)

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
      case "hide":
        self.hideToMenuBar()
      case "show":
        self.showAndFocus()
      case "quit":
        NSApp.terminate(nil)
      case "setCloseToTray":
        self.closeToTray = (call.arguments as? Bool) ?? false
        (NSApp.delegate as? AppDelegate)?.keepRunning = self.closeToTray
      case "setTray":
        self.setTray(call.arguments as? [String: Any] ?? [:])
      case "setBadge":
        // The Dock badge comes from app_badge_plus.
        break
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

    // Closing asks windowShouldClose first, so "Keep running in the menu bar" can hide instead.
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func windowState() -> [String: Bool] {
    return [
      "maximized": isZoomed, "fullScreen": styleMask.contains(.fullScreen),
      // The menu bar is always there.
      "trayAvailable": true, "hidden": hiddenToTray,
    ]
  }

  private func sendState() {
    windowChannel?.invokeMethod("stateChanged", arguments: windowState())
  }

  // The red button and Cmd+W: hide while the setting is on; otherwise close, which quits.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeToTray && statusItem != nil {
      hideToMenuBar()
      return false
    }
    return true
  }

  private func hideToMenuBar() {
    // Never hide without the menu bar item (or the Dock icon) to come back through.
    guard statusItem != nil else {
      NSApp.terminate(nil)
      return
    }
    if styleMask.contains(.fullScreen) {
      toggleFullScreen(nil)
    }
    orderOut(nil)
    hiddenToTray = true
    sendState()
  }

  func showAndFocus() {
    if isMiniaturized {
      deminiaturize(nil)
    }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if hiddenToTray {
      hiddenToTray = false
      sendState()
    }
  }

  // {visible, tooltip, title, icon (template PNG, 18 pt at 2x)} from lib/window/desktop_badges.dart.
  private func setTray(_ args: [String: Any]) {
    guard args["visible"] as? Bool == true else {
      if let item = statusItem {
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
      }
      if hiddenToTray {
        showAndFocus()
      }
      return
    }
    let item = statusItem ?? makeStatusItem()
    statusItem = item
    guard let button = item.button else { return }
    if let png = args["icon"] as? FlutterStandardTypedData, let image = NSImage(data: png.data) {
      image.size = NSSize(width: 18, height: 18)
      image.isTemplate = true
      button.image = image
    }
    let title = args["title"] as? String ?? ""
    button.title = title
    button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
    button.toolTip = args["tooltip"] as? String
  }

  private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let open = NSMenuItem(title: "Open FamChat", action: #selector(openFromMenu), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(NSMenuItem.separator())
    let quit = NSMenuItem(title: "Quit FamChat", action: #selector(quitFromMenu), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    item.button?.setAccessibilityLabel("FamChat")
    return item
  }

  @objc private func openFromMenu() {
    showAndFocus()
  }

  @objc private func quitFromMenu() {
    NSApp.terminate(nil)
  }
}
