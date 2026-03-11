import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mainActivityChannel: FlutterMethodChannel?
  private var pendingInitialRoute: [String: Any]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register background service
    MatchMeBackgroundService.register(with: self.registrar(forPlugin: "MatchMeBackgroundService")!)

    if let controller = window?.rootViewController as? FlutterViewController {
      let mainChannel = FlutterMethodChannel(name: "matchme/main_activity", binaryMessenger: controller.binaryMessenger)
      self.mainActivityChannel = mainChannel
      mainChannel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        if call.method != "getInitialRoute" {
          result(FlutterMethodNotImplemented)
          return
        }
        let payload = self.pendingInitialRoute
        self.pendingInitialRoute = nil
        result(payload)
      }

      let channel = FlutterMethodChannel(name: "matchme/app_info", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method != "getAppInfo" {
          result(FlutterMethodNotImplemented)
          return
        }

        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        result([
          "appName": appName as Any,
          "version": version as Any,
          "buildNumber": build as Any
        ])
      }
    }

    if let url = launchOptions?[.url] as? URL {
      handleIncomingUrl(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleIncomingUrl(_ url: URL) {
    let payload: [String: Any]
    if url.isFileURL {
      payload = ["sharedFilePath": url.path]
    } else {
      payload = ["sharedText": url.absoluteString]
    }
    pendingInitialRoute = payload
    mainActivityChannel?.invokeMethod("onSharedIntent", arguments: payload)
  }

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    handleIncomingUrl(url)
    return true
  }
}
