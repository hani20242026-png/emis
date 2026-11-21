#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stderr), 2);
    }
    std::ios::sync_with_stdio();
    FlutterWindowsRenderTargetThreadPriority();
  }
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr || utf16_string[0] == L'\\0') {
    return std::string();
  }

  const int required_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, -1, nullptr, 0, nullptr,
      nullptr);
  if (required_length <= 1) {
    return std::string();
  }

  // Include the terminating NUL in the temporary buffer, then remove it.
  std::string utf8_string(static_cast<size_t>(required_length), '\\0');
  const int written = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, -1, utf8_string.data(),
      required_length, nullptr, nullptr);
  if (written <= 1) {
    return std::string();
  }

  utf8_string.resize(static_cast<size_t>(written - 1));
  return utf8_string;
}

std::vector<std::string> GetCommandLineArguments() {
  // GetCommandLineW() is permitted because this is a Win32 application.
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), nullptr);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument, which is the program name.
  for (int i = 1; argv[i] != nullptr; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}
