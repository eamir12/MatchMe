#ifndef RUNNER_PUSH_CHANNEL_H_
#define RUNNER_PUSH_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>

// Windows push channel for WNS (Windows Push Notification Service).
//
// The MSIX-packaged client requests a channel URI from
// PushNotificationChannelManagerForUser and hands it back to Dart; the
// Supabase edge functions then deliver toasts while the app is closed.
// This custom channel exists because the platform channel API needs a native
// timeout and a launch-argument reader (toast activation while suspended).
class PushChannel {
 public:
  explicit PushChannel(flutter::FlutterEngine* engine);
  ~PushChannel();

  PushChannel(const PushChannel&) = delete;
  PushChannel& operator=(const PushChannel&) = delete;

 private:
  // Called from the method channel handler (runs on the platform/STA thread,
  // so awaited WinRT continuations resume on this same thread).
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void CreatePushChannel(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      int timeout_ms);

  // Returns the matchme:// URI the app was launched with (toast activation),
  // or an empty string when launched normally.
  static std::string GetInitialLaunchPayload();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PUSH_CHANNEL_H_
