#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <objbase.h>

#include <utility>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                    _In_ wchar_t *command_line, _In_ int show_command) {
  UNREFERENCED_PARAMETER(prev);
  UNREFERENCED_PARAMETER(command_line);

  // Initialize COM for WebView2 / desktop plugins. S_FALSE is also a
  // successful initialization and must be balanced by CoUninitialize().
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTMENTTHREADED);
  const bool com_initialized = SUCCEEDED(com_result);

  // Attach to console when launched from a terminal for debugging.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize Flutter, so that it can load convert UTF-8 to UTF-16.
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"مساعد EMIS", origin, size)) {
    if (com_initialized) {
      ::CoUninitialize();
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (com_initialized) {
    ::CoUninitialize();
  }
  return EXIT_SUCCESS;
}
