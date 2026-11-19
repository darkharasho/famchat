#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cstdint>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// The smallest window the phone layout still fits in, in logical pixels.
constexpr int kMinWidth = 380;
constexpr int kMinHeight = 500;

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Where the window's size and position are kept across launches: its normal
// (not maximized) rect in screen coordinates and physical pixels, the DPI of
// the monitor it was on, and whether it was maximized.
constexpr const wchar_t kWindowPlacementRegKey[] = L"Software\\FamChat\\Window";

bool ReadRegDword(const wchar_t* name, DWORD* value) {
  DWORD size = sizeof(*value);
  return RegGetValueW(HKEY_CURRENT_USER, kWindowPlacementRegKey, name,
                      RRF_RT_REG_DWORD, nullptr, value,
                      &size) == ERROR_SUCCESS;
}

void WriteRegDword(HKEY key, const wchar_t* name, DWORD value) {
  RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value),
                 sizeof(value));
}

// The saved window rect, fitted to today's monitors: the same place if that is
// still on a monitor (rescaled if the monitor's DPI changed), else centred on
// the primary monitor; never larger than the monitor's work area. False when
// nothing usable is saved.
bool LoadSavedPlacement(RECT* rect, bool* maximized) {
  DWORD left, top, right, bottom, saved_dpi, saved_maximized;
  if (!ReadRegDword(L"Left", &left) || !ReadRegDword(L"Top", &top) ||
      !ReadRegDword(L"Right", &right) || !ReadRegDword(L"Bottom", &bottom) ||
      !ReadRegDword(L"Dpi", &saved_dpi)) {
    return false;
  }
  if (!ReadRegDword(L"Maximized", &saved_maximized)) {
    saved_maximized = 0;
  }
  // Signed: monitors left of or above the primary one have negative
  // coordinates.
  RECT saved = {static_cast<LONG>(static_cast<int32_t>(left)),
                static_cast<LONG>(static_cast<int32_t>(top)),
                static_cast<LONG>(static_cast<int32_t>(right)),
                static_cast<LONG>(static_cast<int32_t>(bottom))};
  LONG width = saved.right - saved.left;
  LONG height = saved.bottom - saved.top;
  if (saved_dpi < 48 || saved_dpi > 960 || width <= 0 || height <= 0 ||
      width > 32768 || height > 32768) {
    return false;
  }

  bool on_screen = true;
  HMONITOR monitor = MonitorFromRect(&saved, MONITOR_DEFAULTTONULL);
  if (monitor == nullptr) {
    on_screen = false;
    const POINT origin = {0, 0};
    monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  }
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || !GetMonitorInfo(monitor, &info)) {
    return false;
  }
  const RECT& work = info.rcWork;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi != 0 && dpi != saved_dpi) {
    const int new_dpi = static_cast<int>(dpi);
    const int old_dpi = static_cast<int>(saved_dpi);
    width = MulDiv(width, new_dpi, old_dpi);
    height = MulDiv(height, new_dpi, old_dpi);
  }
  const double scale_factor = (dpi != 0 ? dpi : 96) / 96.0;
  const LONG work_width = work.right - work.left;
  const LONG work_height = work.bottom - work.top;
  width = (std::max)(static_cast<LONG>(Scale(kMinWidth, scale_factor)),
                     (std::min)(width, work_width));
  height = (std::max)(static_cast<LONG>(Scale(kMinHeight, scale_factor)),
                      (std::min)(height, work_height));

  LONG x = saved.left;
  LONG y = saved.top;
  if (!on_screen) {
    x = work.left + (work_width - width) / 2;
    y = work.top + (work_height - height) / 2;
  } else {
    // Wholly on the monitor it is (mostly) on.
    x = (std::max)(work.left, (std::min)(x, work.right - width));
    y = (std::max)(work.top, (std::min)(y, work.bottom - height));
  }
  *rect = {x, y, x + width, y + height};
  *maximized = saved_maximized != 0;
  return true;
}

// The height of the resize border above a window's title bar, which a
// maximized window pushes off the top of the screen.
int MaximizedTopInset(HWND hwnd) {
  UINT dpi = GetDpiForWindow(hwnd);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  // Where and how large it was last time, else |origin| and |size| scaled for
  // the monitor there. Created there directly, already the right size for that
  // monitor's DPI, so it never moves or resizes once shown.
  int x, y, width, height;
  RECT saved_rect;
  bool saved_maximized = false;
  if (LoadSavedPlacement(&saved_rect, &saved_maximized)) {
    x = saved_rect.left;
    y = saved_rect.top;
    width = saved_rect.right - saved_rect.left;
    height = saved_rect.bottom - saved_rect.top;
    start_maximized_ = saved_maximized;
  } else {
    const POINT target_point = {static_cast<LONG>(origin.x),
                                static_cast<LONG>(origin.y)};
    HMONITOR monitor =
        MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
    UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
    double scale_factor = dpi / 96.0;
    x = Scale(origin.x, scale_factor);
    y = Scale(origin.y, scale_factor);
    width = Scale(size.width, scale_factor);
    height = Scale(size.height, scale_factor);
  }

  HWND window = CreateWindow(window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
                             x, y, width, height, nullptr, nullptr,
                             GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }
  RememberNormalRect(window);

  UpdateTheme(window);
  // Recalculate the frame now that WM_NCCALCSIZE drops the title bar.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  return OnCreate();
}

bool Win32Window::Show() {
  const int command = start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  start_maximized_ = false;
  return ShowWindow(window_handle_, command);
}

void Win32Window::RememberNormalRect(HWND hwnd) {
  if (IsZoomed(hwnd) || IsIconic(hwnd)) {
    return;
  }
  RECT rect;
  if (GetWindowRect(hwnd, &rect) && rect.right > rect.left &&
      rect.bottom > rect.top) {
    normal_rect_ = rect;
    normal_dpi_ = GetDpiForWindow(hwnd);
  }
}

void Win32Window::SavePlacement(HWND hwnd) {
  RememberNormalRect(hwnd);
  if (normal_dpi_ == 0) {
    return;
  }
  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(placement);
  // Minimized (or hidden to the tray) from maximized still counts as maximized.
  bool maximized = IsZoomed(hwnd) != FALSE;
  if (!maximized && IsIconic(hwnd) && GetWindowPlacement(hwnd, &placement)) {
    maximized = (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
  }
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowPlacementRegKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  WriteRegDword(key, L"Left", static_cast<DWORD>(normal_rect_.left));
  WriteRegDword(key, L"Top", static_cast<DWORD>(normal_rect_.top));
  WriteRegDword(key, L"Right", static_cast<DWORD>(normal_rect_.right));
  WriteRegDword(key, L"Bottom", static_cast<DWORD>(normal_rect_.bottom));
  WriteRegDword(key, L"Dpi", normal_dpi_);
  WriteRegDword(key, L"Maximized", maximized ? 1 : 0);
  RegCloseKey(key);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    // FamChat draws its own title bar (lib/window/title_bar.dart). The client
    // area takes the system title bar's place; the left, right and bottom
    // resize borders stay the system's, and the app resizes from the top edge
    // itself (startResize in flutter_window.cpp).
    case WM_NCCALCSIZE: {
      if (wparam == FALSE) {
        break;
      }
      auto params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      const LONG top = params->rgrc[0].top;
      LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
      if (result != 0) {
        return result;
      }
      params->rgrc[0].top = top;
      if (IsZoomed(hwnd)) {
        params->rgrc[0].top += MaximizedTopInset(hwnd);
      }
      return 0;
    }

    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      double scale_factor = GetDpiForWindow(hwnd) / 96.0;
      info->ptMinTrackSize.x = Scale(kMinWidth, scale_factor);
      info->ptMinTrackSize.y = Scale(kMinHeight, scale_factor);
      return 0;
    }

    case WM_DESTROY:
      SavePlacement(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_MOVE:
      RememberNormalRect(hwnd);
      break;

    // Signing out or shutting down may end the process without WM_DESTROY.
    case WM_ENDSESSION:
      if (wparam) {
        SavePlacement(hwnd);
      }
      break;

    case WM_SIZE: {
      RememberNormalRect(hwnd);
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
