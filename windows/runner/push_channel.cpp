#include "push_channel.h"

#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>
#include <winrt/Windows.System.Threading.h>

#include <algorithm>
#include <chrono>
#include <string>

#include "utils.h"

using namespace flutter;
using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking::PushNotifications;
using namespace winrt::Windows::System::Threading;

namespace {

// ── diagnostic logging ──────────────────────────────────────────────────
// View with DebugView (Sysinternals) or Visual Studio Output window.
void Log(const char* msg) {
  OutputDebugStringA("[PushChannel] ");
  OutputDebugStringA(msg);
  OutputDebugStringA("\n");
}

std::string WideToUtf8(std::wstring const& wide) {
  if (wide.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                 static_cast<int>(wide.size()),
                                 nullptr, 0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                      static_cast<int>(wide.size()),
                      &result[0], size, nullptr, nullptr);
  return result;
}

// ── channel creation ────────────────────────────────────────────────────
//
// Requires package identity (MSIX). The channel URI expires roughly every
// 30 days, so Dart re-requests it on each app start; the server stores it
// with a freshness timestamp and prunes stale values.
//
// co_await on an IAsyncOperation launched from the STA method-call handler
// resumes on that same thread, so calling result->Success off the awaited
// continuation is safe (same pattern as LocationChannel).
winrt::fire_and_forget CreateChannelWithTimeout(
    int timeout_ms,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    Log("CreateChannelWithTimeout: requesting channel URI");
    auto operation =
        PushNotificationChannelManager::
            CreatePushNotificationChannelForApplicationAsync();

    auto timer = ThreadPoolTimer::CreateTimer(
        [operation](ThreadPoolTimer) {
          if (operation.Status() == AsyncStatus::Started) {
            operation.Cancel();
          }
        },
        std::chrono::milliseconds(timeout_ms));

    try {
      auto channel = co_await operation;
      timer.Cancel();
      std::string uri = WideToUtf8(channel.Uri().c_str());
      Log(("CreateChannelWithTimeout: success (prefix " +
           uri.substr(0, std::min<size_t>(32, uri.size())) + "...)")
              .c_str());
      result->Success(EncodableValue(uri));
    } catch (hresult_canceled const&) {
      Log("CreateChannelWithTimeout: timed out");
      result->Error("TIMEOUT", "WNS channel request timed out");
    }
  } catch (hresult_error const& error) {
    // Typical causes: unpackaged build (no package identity), no internet.
    auto msg = WideToUtf8(std::wstring(error.message()));
    Log(("CreateChannelWithTimeout: error " + msg).c_str());
    result->Error("NOT_AVAILABLE", msg);
  }
}

}  // namespace

PushChannel::PushChannel(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<MethodChannel<EncodableValue>>(
      engine->messenger(), "matchme/windows_push",
      &StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  Log("PushChannel registered");
}

PushChannel::~PushChannel() {}

void PushChannel::HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  auto method = call.method_name();
  Log(("HandleMethodCall: " + method).c_str());

  if (method == "createPushChannel") {
    int timeout_ms = 8000;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(EncodableValue("timeoutMs"));
      if (it != args->end()) {
        timeout_ms = std::get<int>(it->second);
      }
    }
    CreatePushChannel(std::move(result), timeout_ms);
  } else if (method == "getInitialLaunchPayload") {
    // Read synchronously: the toast's matchme:// URI arrives in the command
    // line when Windows cold-starts the app (protocol activation).
    std::string payload = GetInitialLaunchPayload();
    if (payload.empty()) {
      result->Success(EncodableValue());
    } else {
      result->Success(EncodableValue(payload));
    }
  } else {
    result->NotImplemented();
  }
}

void PushChannel::CreatePushChannel(
    std::unique_ptr<MethodResult<EncodableValue>> result,
    int timeout_ms) {
  CreateChannelWithTimeout(timeout_ms, std::move(result));
}

std::string PushChannel::GetInitialLaunchPayload() {
  // Single-instance launch via protocol activation embeds the URI in the
  // process command line (matchme://chat/<id>).
  for (const auto& arg : GetCommandLineArguments()) {
    if (arg.rfind("matchme://", 0) == 0) {
      Log(("GetInitialLaunchPayload: found launch URI (" +
           arg.substr(0, std::min<size_t>(48, arg.size())) + ")")
              .c_str());
      return arg;
    }
  }
  return std::string();
}
