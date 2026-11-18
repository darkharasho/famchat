import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// "Keep running in the menu bar" (lib/settings/close_to_tray.dart), set by MainFlutterWindow
  /// from the famchat/window channel: closing the window hides it and FamChat keeps running.
  var keepRunning = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !keepRunning
  }

  /// A click on the Dock icon brings back a window hidden by closing it.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag, let window = mainFlutterWindow as? MainFlutterWindow {
      window.showAndFocus()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
