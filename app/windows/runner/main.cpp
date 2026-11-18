#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // FamChat runs once: a second launch (the Start menu, a pinned taskbar
  // button) shows the running one's window, which may be hidden in the tray,
  // and exits. The mutex goes when the process does.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\dev.famchat.app.instance");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"FamChat");
    if (running != nullptr) {
      DWORD process = 0;
      ::GetWindowThreadProcessId(running, &process);
      // The foreground (this launch) lets the running one come to the front.
      ::AllowSetForegroundWindow(process);
      ::PostMessageW(running, FlutterWindow::ShowInstanceMessage(), 0, 0);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"FamChat", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
