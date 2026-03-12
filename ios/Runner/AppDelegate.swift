import Flutter
import FirebaseCore
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mainActivityChannel: FlutterMethodChannel?
  private var pendingInitialRoute: [String: Any]?
  private var appInfoChannel: FlutterMethodChannel?
  private var channelsConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    GeneratedPluginRegistrant.register(with: self)

    MatchMeBackgroundService.register(with: self.registrar(forPlugin: "MatchMeBackgroundService")!)
    configureChannelsIfNeeded()

    if let url = launchOptions?[.url] as? URL {
      handleIncomingUrl(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    configureChannelsIfNeeded()
    super.applicationDidBecomeActive(application)
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

  private func configureChannelsIfNeeded() {
    if channelsConfigured {
      return
    }

    guard let controller = resolveFlutterController() else {
      return
    }

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
    self.appInfoChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getAppInfo":
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        result([
          "appName": appName as Any,
          "version": version as Any,
          "buildNumber": build as Any
        ])
      case "hasApsEnvironmentEntitlement":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    channelsConfigured = true
  }

  private func resolveFlutterController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }

    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController as? FlutterViewController {
        return controller
      }
      if let controller = scene.windows.first?.rootViewController as? FlutterViewController {
        return controller
      }
    }

    return nil
  }
}
