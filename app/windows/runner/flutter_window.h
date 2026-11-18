#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // The message a second FamChat sends the running one's window, which then
  // shows itself (main.cpp).
  static UINT ShowInstanceMessage();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // One square icon image from Dart: |size| by |size| BGRA pixels, straight
  // alpha (lib/window/desktop_badges.dart).
  struct IconImage {
    int size;
    std::vector<uint8_t> bgra;
  };

  // The project to run.
  flutter::DartProject project_;

  // Answers famchat/window, the in-app title bar's requests
  // (lib/window/window_controls.dart).
  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Whether the window is maximized, for the title bar.
  flutter::EncodableValue WindowState();
  void SendWindowState();

  // Opens the window's system menu at the pointer.
  void ShowSystemMenu();

  // Hides the window to the tray, if the tray icon is there to bring it back;
  // quits otherwise.
  void HideToTray();
  // Shows the window and brings it to the front.
  void ShowAndFocus();
  // Closes the window for real, which quits.
  void Quit();

  // The tray icon (Shell_NotifyIcon) and its menu.
  void UpdateTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu(int x, int y);

  // The taskbar button's overlay (ITaskbarList3).
  void UpdateOverlay();

  // The small-icon size for the window's DPI, and an icon from the image
  // closest to it.
  int SmallIconSize();
  HICON IconFor(const std::vector<IconImage>& images);
  static std::vector<IconImage> ReadIcons(const flutter::EncodableValue* list);

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // The last maximized state sent to the title bar.
  bool maximized_ = false;

  // Set from Dart (setCloseToTray): closing hides the window to the tray.
  bool close_to_tray_ = false;
  // The window is hidden to the tray.
  bool hidden_ = false;
  // Quitting for real: WM_CLOSE must not hide.
  bool quitting_ = false;

  // The tray icon, while Dart wants it shown.
  bool tray_wanted_ = false;
  bool tray_added_ = false;
  std::vector<IconImage> tray_images_;
  std::wstring tray_tooltip_ = L"FamChat";
  HICON tray_icon_ = nullptr;

  // The overlay; no images means none.
  std::vector<IconImage> overlay_images_;
  std::wstring overlay_description_;
  HICON overlay_icon_ = nullptr;
  ITaskbarList3* taskbar_ = nullptr;

  // Explorer's broadcasts: the taskbar was (re)created, so the tray icon needs
  // adding again; and our taskbar button exists, so the overlay can be set.
  UINT taskbar_created_message_ = 0;
  UINT taskbar_button_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
