import Flutter
import FirebaseCore
import ImageIO
import UIKit
import Vision

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
        result(self.hasApsEnvironmentEntitlement())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let photoModerationChannel = FlutterMethodChannel(name: "matchme/photo_moderation", binaryMessenger: controller.binaryMessenger)
    photoModerationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "analyzeProfilePhotoPresence":
        self.analyzeProfilePhotoPresence(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let photoPrescreenChannel = FlutterMethodChannel(name: "matchme/photo_prescreen", binaryMessenger: controller.binaryMessenger)
    photoPrescreenChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "analyzePhoto":
        self.analyzePhotoPrescreen(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // App-icon badge: APNs `badge` sets it while killed/background; this
    // keeps foreground-accurate counts and clears it on read without plugins.
    let badgeChannel = FlutterMethodChannel(name: "matchme/badge", binaryMessenger: controller.binaryMessenger)
    badgeChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setBadgeCount":
        let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
        DispatchQueue.main.async {
          UIApplication.shared.applicationIconBadgeNumber = max(0, count)
        }
        result(nil)
      case "clearBadge":
        DispatchQueue.main.async {
          UIApplication.shared.applicationIconBadgeNumber = 0
        }
        result(nil)
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

  private func hasApsEnvironmentEntitlement() -> Bool {
    guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
      return false
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let profile = String(data: data, encoding: .ascii) else {
      return false
    }
    return profile.contains("<key>aps-environment</key>")
  }

  private func analyzeProfilePhotoPresence(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let typedBytes = args["bytes"] as? FlutterStandardTypedData
    else {
      result([
        "supported": true,
        "containsFace": false,
        "containsBody": false,
        "uncertain": true,
        "faceConfidence": 0.0,
        "bodyConfidence": 0.0
      ])
      return
    }

    let data = typedBytes.data
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
      result([
        "supported": true,
        "containsFace": false,
        "containsBody": false,
        "uncertain": true,
        "faceConfidence": 0.0,
        "bodyConfidence": 0.0
      ])
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()
        bodyRequest.upperBodyOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, bodyRequest])

        let faceObservations = (faceRequest.results as? [VNFaceObservation]) ?? []
        let bodyObservations = (bodyRequest.results as? [VNHumanObservation]) ?? []
        let faceConfidence = faceObservations.map(\.confidence).max() ?? 0
        let bodyConfidence = bodyObservations.map(\.confidence).max() ?? 0

        DispatchQueue.main.async {
          result([
            "supported": true,
            "containsFace": !faceObservations.isEmpty,
            "containsBody": !bodyObservations.isEmpty,
            "uncertain": false,
            "faceConfidence": Double(faceConfidence),
            "bodyConfidence": Double(bodyConfidence)
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result([
            "supported": false,
            "containsFace": false,
            "containsBody": false,
            "uncertain": true,
            "faceConfidence": 0.0,
            "bodyConfidence": 0.0
          ])
        }
      }
    }
  }

  private func analyzePhotoPrescreen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let typedBytes = args["bytes"] as? FlutterStandardTypedData
    else {
      result([
        "supported": true,
        "containsFace": false,
        "containsBody": false,
        "uncertain": true,
        "faceConfidence": 0.0,
        "bodyConfidence": 0.0,
        "faceCount": 0,
        "faceSizeRatio": 0.0,
        "facePositionedCenter": false,
        "faceTouchesImageEdge": false,
        "completeFaceDetected": false,
        "faceObstructed": false,
        "upperBodyOnly": false,
        "fullBodyVisible": false,
        "completeBodyDetected": false
      ])
      return
    }

    let data = typedBytes.data
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
      result([
        "supported": true,
        "containsFace": false,
        "containsBody": false,
        "uncertain": true,
        "faceConfidence": 0.0,
        "bodyConfidence": 0.0,
        "faceCount": 0,
        "faceSizeRatio": 0.0,
        "facePositionedCenter": false,
        "faceTouchesImageEdge": false,
        "completeFaceDetected": false,
        "faceObstructed": false,
        "upperBodyOnly": false,
        "fullBodyVisible": false,
        "completeBodyDetected": false
      ])
      return
    }

    let minFaceConfidence = (args["minFaceConfidence"] as? Double) ?? 0.65
    let minBodyConfidence = (args["minBodyConfidence"] as? Double) ?? 0.55

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()
        bodyRequest.upperBodyOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, bodyRequest])

        let faceObservations = (faceRequest.results as? [VNFaceObservation]) ?? []
        let bodyObservations = (bodyRequest.results as? [VNHumanObservation]) ?? []

        let faceCount = faceObservations.count
        let containsFace = faceCount > 0
        let faceConfidence = faceObservations.map(\.confidence).max() ?? 0
        let containsBody = !bodyObservations.isEmpty
        let bodyConfidence = bodyObservations.map(\.confidence).max() ?? 0

        // Calculate face size ratio (largest face)
        let faceSizeRatio: Double
        if containsFace, let largestFace = faceObservations.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
          let faceArea = largestFace.boundingBox.width * largestFace.boundingBox.height
          faceSizeRatio = Double(faceArea)
        } else {
          faceSizeRatio = 0.0
        }

        // Check if face is positioned in center
        let facePositionedCenter: Bool
        if containsFace, let largestFace = faceObservations.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
          let faceCenterX = largestFace.boundingBox.midX
          let faceCenterY = largestFace.boundingBox.midY
          let thresholdX: CGFloat = 0.3
          let thresholdY: CGFloat = 0.3
          facePositionedCenter = abs(faceCenterX - 0.5) < thresholdX && abs(faceCenterY - 0.5) < thresholdY
        } else {
          facePositionedCenter = false
        }

        // Vision supplies normalized bounds. A face touching a border is
        // incomplete/cropped and cannot be used as the face subject.
        let edgeTolerance: CGFloat = 0.02
        let faceTouchesImageEdge = faceObservations.contains { face in
          let box = face.boundingBox
          return box.minX <= edgeTolerance || box.minY <= edgeTolerance ||
            box.maxX >= 1 - edgeTolerance || box.maxY >= 1 - edgeTolerance
        }
        let completeFaceDetected = faceObservations.contains { face in
          let box = face.boundingBox
          return box.minX > edgeTolerance && box.minY > edgeTolerance &&
            box.maxX < 1 - edgeTolerance && box.maxY < 1 - edgeTolerance
        }

        // Check for face obstruction (using roll/yaw if available)
        let faceObstructed = faceObservations.contains { face in
          if let roll = face.roll, let yaw = face.yaw {
            return abs(roll) > 0.5 || abs(yaw) > 0.5
          }
          return false
        }

        // Determine upper body vs full body
        let upperBodyOnly = bodyObservations.allSatisfy { $0.upperBodyOnly }
        let fullBodyVisible = bodyObservations.contains { !$0.upperBodyOnly }
        let completeBodyDetected = bodyObservations.contains { body in
          let box = body.boundingBox
          return !body.upperBodyOnly && box.minX > edgeTolerance &&
            box.minY > edgeTolerance && box.maxX < 1 - edgeTolerance &&
            box.maxY < 1 - edgeTolerance
        }

        let uncertain = !containsFace && !containsBody

        DispatchQueue.main.async {
          result([
            "supported": true,
            "containsFace": containsFace,
            "containsBody": containsBody,
            "uncertain": uncertain,
            "faceConfidence": Double(faceConfidence),
            "bodyConfidence": Double(bodyConfidence),
            "faceCount": faceCount,
            "faceSizeRatio": faceSizeRatio,
            "facePositionedCenter": facePositionedCenter,
            "faceTouchesImageEdge": faceTouchesImageEdge,
            "completeFaceDetected": completeFaceDetected,
            "faceObstructed": faceObstructed,
            "upperBodyOnly": upperBodyOnly,
            "fullBodyVisible": fullBodyVisible,
            "completeBodyDetected": completeBodyDetected
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result([
            "supported": false,
            "containsFace": false,
            "containsBody": false,
            "uncertain": true,
            "faceConfidence": 0.0,
            "bodyConfidence": 0.0,
            "faceCount": 0,
            "faceSizeRatio": 0.0,
            "facePositionedCenter": false,
            "faceTouchesImageEdge": false,
            "completeFaceDetected": false,
            "faceObstructed": false,
            "upperBodyOnly": false,
            "fullBodyVisible": false,
            "completeBodyDetected": false
          ])
        }
      }
    }
  }
}
