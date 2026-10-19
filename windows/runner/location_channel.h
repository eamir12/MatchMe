#ifndef RUNNER_LOCATION_CHANNEL_H_
#define RUNNER_LOCATION_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <memory>

class LocationChannel {
 public:
  explicit LocationChannel(flutter::FlutterEngine* engine);
  ~LocationChannel();

  LocationChannel(const LocationChannel&) = delete;
  LocationChannel& operator=(const LocationChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_LOCATION_CHANNEL_H_
