#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "famchat/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleWindowCall(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

flutter::EncodableValue FlutterWindow::WindowState() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)},
      {flutter::EncodableValue("fullScreen"), flutter::EncodableValue(false)},
  });
}

void FlutterWindow::ShowSystemMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = GetSystemMenu(hwnd, FALSE);
  if (menu == nullptr) {
    return;
  }
  const bool maximized = IsZoomed(hwnd) != FALSE;
  auto enable = [menu](UINT item, bool on) {
    EnableMenuItem(menu, item, MF_BYCOMMAND | (on ? MF_ENABLED : MF_GRAYED));
  };
  enable(SC_RESTORE, maximized);
  enable(SC_MOVE, !maximized);
  enable(SC_SIZE, !maximized);
  enable(SC_MINIMIZE, true);
  enable(SC_MAXIMIZE, !maximized);
  enable(SC_CLOSE, true);
  POINT cursor;
  GetCursorPos(&cursor);
  const BOOL command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y,
                     0, hwnd, nullptr);
  if (command != 0) {
    PostMessage(hwnd, WM_SYSCOMMAND, static_cast<WPARAM>(command), 0);
  }
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  const std::string& method = call.method_name();
  if (method == "state") {
    result->Success(WindowState());
    return;
  }
  if (method == "startDrag" || method == "startResize") {
    WPARAM command = SC_MOVE | HTCAPTION;
    if (method == "startResize") {
      const auto* edge = std::get_if<std::string>(call.arguments());
      const std::string side = edge != nullptr ? *edge : "top";
      command = SC_SIZE | (side == "topLeft"    ? WMSZ_TOPLEFT
                           : side == "topRight" ? WMSZ_TOPRIGHT
                                                : WMSZ_TOP);
    }
    // Answer first: the move or resize runs a modal loop until the button
    // comes up.
    result->Success();
    ReleaseCapture();
    SendMessage(hwnd, WM_SYSCOMMAND, command, 0);
    return;
  }
  if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
  } else if (method == "showMenu") {
    ShowSystemMenu();
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE: {
      const bool maximized = IsZoomed(hwnd) != FALSE;
      if (window_channel_ && maximized != maximized_) {
        maximized_ = maximized;
        window_channel_->InvokeMethod(
            "stateChanged",
            std::make_unique<flutter::EncodableValue>(WindowState()));
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
