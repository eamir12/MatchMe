#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One process per user session. The app's session layer assumes it is the only
// refresher of the single-use Supabase refresh token; a second instance runs a
// parallel refresher, and replaying a rotated token revokes the whole token
// family server-side (observed 2026-10-24). `Local\` scopes the name to the
// current login session so separate Windows users can each run the app.
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\MatchMe-Desktop-SingleInstance";

// Must match window.Create(L"matchme", ...) below. The class name comes from
// windows/runner/win32_window.cpp (kWindowClassName).
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"matchme";

void ActivateExistingInstance() {
  // The winner may still be creating its window when the second instance
  // launches; wait up to one second for it.
  for (int attempt = 0; attempt < 20; ++attempt) {
    HWND existing = ::FindWindowW(kWindowClassName, kWindowTitle);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
      return;
    }
    ::Sleep(50);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Fail open: if the mutex cannot be created, run anyway rather than refusing
  // to start.
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(single_instance_mutex);
    ActivateExistingInstance();
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Open maximized: this is a full-screen browsing surface, and a small default
  // window on a high-DPI laptop wastes most of the display. Set before Create so
  // the engine's first-frame Show() maximizes instead of showing restored.
  window.SetStartMaximized(true);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"matchme", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
