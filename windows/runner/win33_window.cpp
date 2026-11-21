#include "win32_window.h"

#include <dwmapi.h>

#include "resource.h"

namespace {

// The WindowProc function for a created window, delegating to the Win32Window
// instance.
LRESULT CALLBACK WndProc(HWND const window, UINT const message,
                         WPARAM const wparam, LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    that->OnCreate();
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

void EnableFullDPIScaling(HWND hwnd) {
  // Windows 10 RS2+ per-monitor DPI awareness V2.
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32) {
    using SetProcessDpiAwarenessContextFunc = BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT);
    auto set_dpi_awareness_context =
        reinterpret_cast<SetProcessDpiAwarenessContextFunc>(
            GetProcAddress(user32, "SetProcessDpiAwarenessContext"));
    if (set_dpi_awareness_context) {
      set_dpi_awareness_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
  }
}

}  // namespace

// static
Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

Win32Window::WindowClassRegistrar::~WindowClassRegistrar() {
  UnregisterWindowClass();
}

const wchar_t* Win32Window::WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = L"FLUTTER_RUNNER_WIN32_WINDOW";
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.lpfnWndProc = WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return L"FLUTTER_RUNNER_WIN32_WINDOW";
}

void Win32Window::WindowClassRegistrar::UnregisterWindowClass() {
  if (class_registered_) {
    UnregisterClass(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    class_registered_ = false;
  }
}

Win32Window::Win32Window() {
  window_class_registrar_ = std::make_unique<WindowClassRegistrar>();
}

Win32Window::~Win32Window() {
  Destroy();
}

bool Win32Window::Create(const std::wstring& title, const Point& origin,
                       const Size& size) {
  Destroy();
  const wchar_t* window_class = window_class_registrar_->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      static_cast<int>(origin.x * scale_factor),
      static_cast<int>(origin.y * scale_factor),
      static_cast<int>(size.width * scale_factor),
      static_cast<int>(size.height * scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  EnableFullDPIScaling(window);
  window_handle_ = window;
  return true;
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL) != 0;
}

bool Win32Window::Destroy() {
  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (window_class_registrar_) {
    window_class_registrar_->UnregisterWindowClass();
  }
  return true;
}

bool Win32Window::OnCreate() {
  // No-op; subclasses can override.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; subclasses can override.
}

LRESULT
Win32Window::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top,
                   newRectSize->right - newRectSize->left,
                   newRectSize->bottom - newRectSize->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }

    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        MoveWindow(child_content_, rect.left, rect.top,
                   rect.right - rect.left, rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();
  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, TRUE);
  SetFocus(child_content_);
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

void Win32Window::UpdateTheme(bool is_dark) {
  BOOL use_dark_mode = is_dark ? TRUE : FALSE;
  DwmSetWindowAttribute(window_handle_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                       &use_dark_mode, sizeof(use_dark_mode));
}
