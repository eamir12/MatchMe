#include "location_channel.h"

#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.Geolocation.h>
#include <winrt/Windows.System.Threading.h>

#include <chrono>
#include <cmath>
#include <string>

using namespace flutter;
using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Devices::Geolocation;
using namespace winrt::Windows::System::Threading;

namespace {

// ── diagnostic logging ──────────────────────────────────────────────────
// View with DebugView (Sysinternals) or Visual Studio Output window.
void Log(const char* msg) {
  OutputDebugStringA("[LocationChannel] ");
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

// ── registry-based permission check (never touches the location API) ───
//
// RequestAccessAsync() on a local Geolocator STILL latches the Windows
// location indicator for the entire process lifetime on desktop Win32
// apps.  So we read the user's location consent directly from the
// registry instead — this is a pure read, never triggers the indicator.
//
// Returns 2 = allowed, 0 = denied, 1 = unspecified.
int ReadPermissionFromRegistry() {
  // 1. Per-user consent (set when the user granted via the system dialog).
  {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\"
                      L"CapabilityAccessManager\\ConsentStore\\location",
                      0, KEY_READ, &key) == ERROR_SUCCESS) {
      wchar_t value[32] = {0};
      DWORD size = sizeof(value);
      DWORD type = 0;
      if (RegQueryValueExW(key, L"Value", nullptr, &type,
                           reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS) {
        RegCloseKey(key);
        std::wstring v(value);
        if (v == L"Allow") {
          Log("ReadPermissionFromRegistry: per-user = Allow");
          return 2;
        }
        if (v == L"Deny") {
          Log("ReadPermissionFromRegistry: per-user = Deny");
          return 0;
        }
      } else {
        RegCloseKey(key);
      }
    }
  }

  // 2. Machine-wide consent (set by group policy / first-run dialog).
  {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\"
                      L"CapabilityAccessManager\\ConsentStore\\location",
                      0, KEY_READ, &key) == ERROR_SUCCESS) {
      wchar_t value[32] = {0};
      DWORD size = sizeof(value);
      DWORD type = 0;
      if (RegQueryValueExW(key, L"Value", nullptr, &type,
                           reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS) {
        RegCloseKey(key);
        std::wstring v(value);
        if (v == L"Allow") {
          Log("ReadPermissionFromRegistry: machine = Allow");
          return 2;
        }
        if (v == L"Deny") {
          Log("ReadPermissionFromRegistry: machine = Deny");
          return 0;
        }
      } else {
        RegCloseKey(key);
      }
    }
  }

  // 3. Non-packaged desktop app consent (our app is not an MSIX package).
  {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentCapabilityAccessManager"
                      L"\\ConsentStore\\location\\NonPackaged",
                      0, KEY_READ, &key) == ERROR_SUCCESS) {
      wchar_t value[32] = {0};
      DWORD size = sizeof(value);
      DWORD type = 0;
      if (RegQueryValueExW(key, L"Value", nullptr, &type,
                           reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS) {
        RegCloseKey(key);
        std::wstring v(value);
        if (v == L"Allow") {
          Log("ReadPermissionFromRegistry: non-packaged = Allow");
          return 2;
        }
        if (v == L"Deny") {
          Log("ReadPermissionFromRegistry: non-packaged = Deny");
          return 0;
        }
      } else {
        RegCloseKey(key);
      }
    }
  }

  Log("ReadPermissionFromRegistry: unspecified");
  return 1;
}

EncodableMap LocationToEncodableMap(Geoposition const& location) {
  if (location == nullptr) {
    return EncodableMap();
  }

  auto position = EncodableMap();
  auto coordinate = location.Coordinate();

  position.insert({"latitude", coordinate.Latitude()});
  position.insert({"longitude", coordinate.Longitude()});
  position.insert({"timestamp",
                   clock::to_time_t(coordinate.Timestamp())});

  double altitude = 0.0;
  if (coordinate.Altitude() != nullptr &&
      !std::isnan(coordinate.Altitude().GetDouble())) {
    altitude = coordinate.Altitude().GetDouble();
  }
  position.insert({"altitude", altitude});

  double altitude_accuracy = 0.0;
  if (coordinate.AltitudeAccuracy() != nullptr &&
      !std::isnan(coordinate.AltitudeAccuracy().GetDouble())) {
    altitude_accuracy = coordinate.AltitudeAccuracy().GetDouble();
  }
  position.insert({"altitude_accuracy", altitude_accuracy});

  position.insert({"accuracy", coordinate.Accuracy()});

  double heading = 0.0;
  if (coordinate.Heading() != nullptr &&
      !std::isnan(coordinate.Heading().GetDouble())) {
    heading = coordinate.Heading().GetDouble();
  }
  position.insert({"heading", heading});

  double speed = 0.0;
  if (coordinate.Speed() != nullptr &&
      !std::isnan(coordinate.Speed().GetDouble())) {
    speed = coordinate.Speed().GetDouble();
  }
  position.insert({"speed", speed});

  position.insert({"is_mocked", false});

  return position;
}

int PermissionToInt(GeolocationAccessStatus access) {
  switch (access) {
    case GeolocationAccessStatus::Allowed:
      return 2;  // whileInUse
    case GeolocationAccessStatus::Denied:
      return 0;  // denied
    case GeolocationAccessStatus::Unspecified:
    default:
      return 1;  // deniedForever
  }
}

// ── position fetchers ──────────────────────────────────────────────────
//
// Both avoid RequestAccessAsync() entirely.  They check the registry
// first; if permission is not already granted they return an error
// without ever creating a Geolocator — so the indicator cannot turn on.
//
// If permission IS granted, they call GetGeopositionAsync() on a local
// Geolocator (destroyed when the function returns) and cancel the
// operation via ThreadPoolTimer after a hard timeout.

winrt::fire_and_forget GetPositionWithTimeout(
    int timeout_ms,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    int perm = ReadPermissionFromRegistry();
    if (perm != 2) {
      Log("GetPositionWithTimeout: permission not granted (reg), aborting");
      result->Error("PERMISSION_DENIED", "Location permission denied");
      co_return;
    }

    Log("GetPositionWithTimeout: creating local Geolocator");
    Geolocator geolocator;
    auto operation = geolocator.GetGeopositionAsync();

    auto timer = ThreadPoolTimer::CreateTimer(
        [operation](ThreadPoolTimer) {
          if (operation.Status() == AsyncStatus::Started) {
            operation.Cancel();
          }
        },
        std::chrono::milliseconds(timeout_ms));

    try {
      auto location = co_await operation;
      timer.Cancel();
      Log("GetPositionWithTimeout: success");
      result->Success(EncodableValue(LocationToEncodableMap(location)));
    } catch (hresult_canceled const&) {
      Log("GetPositionWithTimeout: timed out");
      result->Error("TIMEOUT", "Location request timed out");
    }
    // Geolocator is destroyed here — the WinRT operation has been
    // cancelled or completed, so the indicator turns off.
  } catch (hresult_error const& error) {
    auto msg = WideToUtf8(std::wstring(error.message()));
    Log(("GetPositionWithTimeout: error " + msg).c_str());
    result->Error("UNKNOWN_ERROR", msg);
  }
}

winrt::fire_and_forget GetLastKnownPositionWithTimeout(
    int timeout_ms,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    int perm = ReadPermissionFromRegistry();
    if (perm != 2) {
      Log("GetLastKnownPositionWithTimeout: permission not granted (reg), aborting");
      result->Error("PERMISSION_DENIED", "Location permission denied");
      co_return;
    }

    Log("GetLastKnownPositionWithTimeout: creating local Geolocator");
    Geolocator geolocator;
    auto operation = geolocator.GetGeopositionAsync(
        std::chrono::hours(1), std::chrono::milliseconds::zero());

    auto timer = ThreadPoolTimer::CreateTimer(
        [operation](ThreadPoolTimer) {
          if (operation.Status() == AsyncStatus::Started) {
            operation.Cancel();
          }
        },
        std::chrono::milliseconds(timeout_ms));

    try {
      auto location = co_await operation;
      timer.Cancel();
      Log("GetLastKnownPositionWithTimeout: success");
      result->Success(EncodableValue(LocationToEncodableMap(location)));
    } catch (hresult_canceled const&) {
      Log("GetLastKnownPositionWithTimeout: timed out");
      result->Error("TIMEOUT", "Last known position timed out");
    }
  } catch (hresult_error const& error) {
    auto msg = WideToUtf8(std::wstring(error.message()));
    Log(("GetLastKnownPositionWithTimeout: error " + msg).c_str());
    result->Error("UNKNOWN_ERROR", msg);
  }
}

}  // namespace

LocationChannel::LocationChannel(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<MethodChannel<EncodableValue>>(
      engine->messenger(), "matchme/windows_location",
      &StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  Log("LocationChannel registered");
}

LocationChannel::~LocationChannel() {}

void LocationChannel::HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  auto method = call.method_name();
  Log(("HandleMethodCall: " + method).c_str());

  if (method == "getCurrentPosition") {
    int timeout_ms = 5000;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(EncodableValue("timeoutMs"));
      if (it != args->end()) {
        timeout_ms = std::get<int>(it->second);
      }
    }
    GetPositionWithTimeout(timeout_ms, std::move(result));
  } else if (method == "getLastKnownPosition") {
    int timeout_ms = 3000;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(EncodableValue("timeoutMs"));
      if (it != args->end()) {
        timeout_ms = std::get<int>(it->second);
      }
    }
    GetLastKnownPositionWithTimeout(timeout_ms, std::move(result));
  } else if (method == "checkPermission" || method == "requestPermission") {
    // Registry read only — never touches RequestAccessAsync, so the
    // indicator cannot turn on from a permission check.
    int perm = ReadPermissionFromRegistry();
    Log(perm == 2 ? "HandleMethodCall: returning permission ALLOWED"
                  : "HandleMethodCall: returning permission NOT-ALLOWED");
    result->Success(EncodableValue(perm));
  } else if (method == "isLocationServiceEnabled") {
    // LocationStatus() is a pure status query — it does not request
    // access and does not trigger the indicator.
    try {
      Geolocator geolocator;
      auto status = geolocator.LocationStatus();
      bool enabled = status != PositionStatus::Disabled &&
                     status != PositionStatus::NotAvailable;
      Log(enabled ? "HandleMethodCall: isLocationServiceEnabled = true"
                  : "HandleMethodCall: isLocationServiceEnabled = false");
      result->Success(EncodableValue(enabled));
    } catch (hresult_error const& error) {
      auto msg = WideToUtf8(std::wstring(error.message()));
      Log(("HandleMethodCall: isLocationServiceEnabled error " + msg).c_str());
      result->Error("UNKNOWN_ERROR", msg);
    }
  } else {
    result->NotImplemented();
  }
}
