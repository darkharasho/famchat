#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <cstring>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The tray icon's callback message and id, and its menu's commands.
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuQuit = 2;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), length);
  return out;
}

const flutter::EncodableValue* Lookup(const flutter::EncodableMap& map,
                                      const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

// A 32-bit icon from straight-alpha BGRA pixels.
HICON IconFromBgra(int size, const std::vector<uint8_t>& bgra) {
  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = size;
  header.bV5Height = -size;  // top-down rows
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;
  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color =
      CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&header),
                       DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, dc);
  if (color == nullptr || bits == nullptr) {
    return nullptr;
  }
  std::memcpy(bits, bgra.data(), bgra.size());
  // The alpha channel does the masking; the mask itself is all "opaque".
  std::vector<uint8_t> mask_bits(
      static_cast<size_t>(((size + 15) / 16) * 2 * size), 0);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, mask_bits.data());
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmColor = color;
  info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

// static
UINT FlutterWindow::ShowInstanceMessage() {
  static const UINT message =
      RegisterWindowMessage(L"dev.famchat.app.ShowWindow");
  return message;
}

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

  taskbar_created_message_ = RegisterWindowMessage(L"TaskbarCreated");
  taskbar_button_created_message_ =
      RegisterWindowMessage(L"TaskbarButtonCreated");
  // Let these through even if FamChat runs elevated and Explorer or a second
  // FamChat doesn't.
  ChangeWindowMessageFilterEx(GetHandle(), ShowInstanceMessage(),
                              MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(GetHandle(), taskbar_created_message_,
                              MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(GetHandle(), taskbar_button_created_message_,
                              MSGFLT_ALLOW, nullptr);

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
  RemoveTrayIcon();
  if (tray_icon_ != nullptr) {
    DestroyIcon(tray_icon_);
    tray_icon_ = nullptr;
  }
  if (overlay_icon_ != nullptr) {
    DestroyIcon(overlay_icon_);
    overlay_icon_ = nullptr;
  }
  if (taskbar_ != nullptr) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
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
      // The notification area is always there.
      {flutter::EncodableValue("trayAvailable"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("hidden"), flutter::EncodableValue(hidden_)},
  });
}

void FlutterWindow::SendWindowState() {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "stateChanged",
        std::make_unique<flutter::EncodableValue>(WindowState()));
  }
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

void FlutterWindow::HideToTray() {
  // Never hide without the tray icon to come back through.
  if (!tray_added_) {
    Quit();
    return;
  }
  ShowWindow(GetHandle(), SW_HIDE);
  hidden_ = true;
  SendWindowState();
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  } else {
    ShowWindow(hwnd, SW_SHOW);
  }
  SetForegroundWindow(hwnd);
  if (hidden_) {
    hidden_ = false;
    SendWindowState();
  }
}

void FlutterWindow::Quit() {
  quitting_ = true;
  // Through the message loop, outside whatever callback asked.
  PostMessage(GetHandle(), WM_CLOSE, 0, 0);
}

int FlutterWindow::SmallIconSize() {
  return GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(GetHandle()));
}

HICON FlutterWindow::IconFor(const std::vector<IconImage>& images) {
  if (images.empty()) {
    return nullptr;
  }
  // The smallest image at least as big as the system wants, else the biggest.
  const int want = SmallIconSize();
  const IconImage* best = nullptr;
  for (const auto& image : images) {
    if (image.size >= want && (best == nullptr || image.size < best->size)) {
      best = &image;
    }
  }
  if (best == nullptr) {
    for (const auto& image : images) {
      if (best == nullptr || image.size > best->size) {
        best = &image;
      }
    }
  }
  return IconFromBgra(best->size, best->bgra);
}

// static
std::vector<FlutterWindow::IconImage> FlutterWindow::ReadIcons(
    const flutter::EncodableValue* value) {
  std::vector<IconImage> images;
  const auto* list =
      value != nullptr ? std::get_if<flutter::EncodableList>(value) : nullptr;
  if (list == nullptr) {
    return images;
  }
  for (const auto& entry : *list) {
    const auto* map = std::get_if<flutter::EncodableMap>(&entry);
    if (map == nullptr) {
      continue;
    }
    const auto* size_value = Lookup(*map, "size");
    const auto* pixels_value = Lookup(*map, "pixels");
    const auto* size =
        size_value != nullptr ? std::get_if<int32_t>(size_value) : nullptr;
    const auto* pixels =
        pixels_value != nullptr
            ? std::get_if<std::vector<uint8_t>>(pixels_value)
            : nullptr;
    if (size == nullptr || pixels == nullptr || *size <= 0 ||
        pixels->size() != static_cast<size_t>(*size) *
                               static_cast<size_t>(*size) * 4) {
      continue;
    }
    images.push_back(IconImage{*size, *pixels});
  }
  return images;
}

void FlutterWindow::UpdateTrayIcon() {
  if (!tray_wanted_) {
    RemoveTrayIcon();
    return;
  }
  HICON icon = IconFor(tray_images_);
  if (icon == nullptr) {
    return;
  }
  if (tray_icon_ != nullptr) {
    DestroyIcon(tray_icon_);
  }
  tray_icon_ = icon;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = tray_icon_;
  wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
  if (tray_added_) {
    tray_added_ = Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
  }
  if (!tray_added_) {
    tray_added_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
    if (tray_added_) {
      data.uVersion = NOTIFYICON_VERSION_4;
      Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
  }
  // A hidden window and no icon to bring it back: show it.
  if (!tray_added_ && hidden_) {
    ShowAndFocus();
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) {
    return;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_added_ = false;
  if (hidden_) {
    ShowAndFocus();
  }
}

void FlutterWindow::ShowTrayMenu(int x, int y) {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kMenuOpen, L"Open FamChat");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"Quit");
  SetMenuDefaultItem(menu, kMenuOpen, FALSE);
  // Without this the menu doesn't close when the user clicks elsewhere.
  SetForegroundWindow(hwnd);
  const UINT command = static_cast<UINT>(
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, x,
                     y, 0, hwnd, nullptr));
  PostMessage(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kMenuOpen) {
    ShowAndFocus();
  } else if (command == kMenuQuit) {
    Quit();
  }
}

void FlutterWindow::UpdateOverlay() {
  if (taskbar_ == nullptr) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      taskbar_ = nullptr;
      return;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_->Release();
      taskbar_ = nullptr;
      return;
    }
  }
  HICON icon = IconFor(overlay_images_);
  // Fails until the taskbar button exists; TaskbarButtonCreated tries again.
  taskbar_->SetOverlayIcon(GetHandle(), icon,
                           icon != nullptr ? overlay_description_.c_str()
                                           : nullptr);
  if (overlay_icon_ != nullptr) {
    DestroyIcon(overlay_icon_);
  }
  overlay_icon_ = icon;
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
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "hide") {
    HideToTray();
  } else if (method == "show") {
    ShowAndFocus();
  } else if (method == "quit") {
    Quit();
  } else if (method == "setCloseToTray") {
    const auto* on = std::get_if<bool>(call.arguments());
    close_to_tray_ = on != nullptr && *on;
  } else if (method == "setTray") {
    if (args != nullptr) {
      const auto* visible = Lookup(*args, "visible");
      tray_wanted_ = visible != nullptr && std::get_if<bool>(visible) != nullptr &&
                     std::get<bool>(*visible);
      const auto* tooltip = Lookup(*args, "tooltip");
      if (tooltip != nullptr && std::get_if<std::string>(tooltip) != nullptr) {
        tray_tooltip_ = Utf16FromUtf8(std::get<std::string>(*tooltip));
      }
      auto images = ReadIcons(Lookup(*args, "icons"));
      if (!images.empty()) {
        tray_images_ = std::move(images);
      }
      UpdateTrayIcon();
    }
  } else if (method == "setBadge") {
    if (args != nullptr) {
      overlay_images_ = ReadIcons(Lookup(*args, "icons"));
      const auto* description = Lookup(*args, "description");
      overlay_description_ =
          description != nullptr &&
                  std::get_if<std::string>(description) != nullptr
              ? Utf16FromUtf8(std::get<std::string>(*description))
              : std::wstring();
      UpdateOverlay();
    }
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
  // The system's close (Alt+F4, the taskbar's Close window): hide to the tray
  // when Dart says so; the title bar's close goes through Dart instead.
  if (message == WM_CLOSE && close_to_tray_ && !quitting_ && tray_added_) {
    HideToTray();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == ShowInstanceMessage()) {
    ShowAndFocus();
    return 0;
  }
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer restarted: the tray icon is gone and needs adding again.
    tray_added_ = false;
    UpdateTrayIcon();
    return 0;
  }
  if (taskbar_button_created_message_ != 0 &&
      message == taskbar_button_created_message_) {
    UpdateOverlay();
    return 0;
  }

  switch (message) {
    case kTrayMessage:
      // NOTIFYICON_VERSION_4: the event in the low word of lparam, the anchor
      // point in wparam.
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
          ShowAndFocus();
          break;
        case WM_CONTEXTMENU:
          ShowTrayMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
          break;
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DPICHANGED:
      // Icons for the new DPI.
      if (tray_added_) {
        UpdateTrayIcon();
      }
      if (!overlay_images_.empty()) {
        UpdateOverlay();
      }
      break;
    case WM_SIZE: {
      const bool maximized = IsZoomed(hwnd) != FALSE;
      if (window_channel_ && maximized != maximized_) {
        maximized_ = maximized;
        SendWindowState();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
