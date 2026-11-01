import Flutter
import FirebaseCore
import ImageIO
import UIKit
import Vision
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mainActivityChannel: FlutterMethodChannel?
  private var pendingInitialRoute: [String: Any]?
  private var appInfoChannel: FlutterMethodChannel?

  /// APNs registration outcome, surfaced through `getPushDiagnostics` so the
  /// field can tell "push is broken" apart from "push was never configured".
  private var apnsRegistrationAttempted = false
  private var apnsTokenRegistered = false
  private var apnsRegistrationError: String?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MatchMeBackgroundService") else {
      fatalError("Could not create the MatchMeBackgroundService plugin registrar")
    }
    MatchMeBackgroundService.register(with: registrar)
    configureChannels(binaryMessenger: engineBridge.applicationRegistrar.messenger())
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    MatchMeBackgroundService.registerBackgroundTaskHandlers()

    if let url = launchOptions?[.url] as? URL {
      handleIncomingUrl(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func handleIncomingUrl(_ url: URL) {
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
    _ = super.application(app, open: url, options: options)
    handleIncomingUrl(url)
    return true
  }

  // MARK: - APNs registration diagnostics
  //
  // Firebase's messaging plugin swizzles these callbacks, so the super call
  // keeps FCM working while we add visibility into what APNs actually did.
  // A missing `aps-environment` entitlement shows up here as a registration
  // failure — which is the difference between "push is broken" and "push was
  // never configured".

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
    apnsRegistrationAttempted = true
    apnsTokenRegistered = true
    apnsRegistrationError = nil
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    print("[MatchMe] ✅ APNs device token registered (prefix: \(token.prefix(12)))")
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
    apnsRegistrationAttempted = true
    apnsTokenRegistered = false
    apnsRegistrationError = error.localizedDescription
    print(
      "[MatchMe] ❌ APNs registration FAILED: \(error.localizedDescription) — "
        + "the app is most likely signed without the 'aps-environment' entitlement"
    )
  }

  /// Snapshot of everything needed to diagnose "no notifications arrive":
  ///
  /// * `hasApsEnvironment` — whether the app is signed with the push
  ///   entitlement. Without it APNs registration can never succeed.
  /// * `apsEnvironment` — the environment the entitlement points at
  ///   (`development` / `production`), when it can be read.
  /// * `apnsRegistrationAttempted` — whether APNs has answered yet.
  /// * `apnsTokenRegistered` — APNs handed us a device token.
  /// * `apnsRegistrationError` — why registration failed, when it did.
  ///
  /// `apnsTokenRegistered` is `false` while the registration is still
  /// pending; check `apnsRegistrationAttempted` to tell "not yet" from
  /// "rejected".
  private func pushDiagnostics() -> [String: Any] {
    // Optionals are boxed explicitly as `NSNull`: a bare `String?` in an
    // `[String: Any]` is an `Optional` value, which the standard method-codec
    // is not guaranteed to encode (it expects a real object).
    let environment: Any = signedApsEnvironmentValue() ?? NSNull()
    let registrationError: Any = apnsRegistrationError ?? NSNull()
    return [
      "hasApsEnvironment": hasApsEnvironmentEntitlement(),
      "apsEnvironment": environment,
      "apnsRegistrationAttempted": apnsRegistrationAttempted,
      "apnsTokenRegistered": apnsTokenRegistered,
      "apnsRegistrationError": registrationError,
    ]
  }

  private func configureChannels(binaryMessenger: FlutterBinaryMessenger) {
    let mainChannel = FlutterMethodChannel(name: "matchme/main_activity", binaryMessenger: binaryMessenger)
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

    let channel = FlutterMethodChannel(name: "matchme/app_info", binaryMessenger: binaryMessenger)
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
      case "getPushDiagnostics":
        result(self.pushDiagnostics())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let photoModerationChannel = FlutterMethodChannel(name: "matchme/photo_moderation", binaryMessenger: binaryMessenger)
    photoModerationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "analyzeProfilePhotoPresence":
        self.analyzeProfilePhotoPresence(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let photoPrescreenChannel = FlutterMethodChannel(name: "matchme/photo_prescreen", binaryMessenger: binaryMessenger)
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
    let badgeChannel = FlutterMethodChannel(name: "matchme/badge", binaryMessenger: binaryMessenger)
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
  }

  /// Whether the app is signed with a usable push entitlement.
  ///
  /// The original implementation scanned the embedded provisioning profile
  /// for `<key>aps-environment</key>`. That was wrong in the exact case that
  /// matters: the profile advertises push, but the app can still be signed
  /// with an entitlements file that omits `aps-environment` (which is what
  /// happened here — `CODE_SIGN_ENTITLEMENTS` pointed at an empty file).
  /// The result was that the app believed push was configured, asked for
  /// notification permission, registered an FCM installation ID — and never
  /// received a single notification, because APNs had no device token.
  ///
  /// Three signals are combined, strongest first:
  ///
  /// 1. The entitlement of the running (signed) task, when the platform
  ///    exposes it.
  /// 2. The outcome of the real APNs registration: a rejection proves the
  ///    signed app has no usable push entitlement, whatever the profile
  ///    says — and a success proves the opposite.
  /// 3. The provisioning profile scan (fallback for unsigned / sideloaded
  ///    builds, where there is no signed task to inspect).
  private func hasApsEnvironmentEntitlement() -> Bool {
    // 1. Ground truth from the signed task.
    if let signedValue = signedApsEnvironment() {
      return signedValue
    }
    // 2. The APNs registration result is the more reliable signal on iOS:
    //    it is what actually decides whether a push can be delivered.
    if apnsRegistrationAttempted {
      return apnsTokenRegistered
    }
    // 3. Fallback: unsigned / sideloaded build — scan the profile.
    guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
      return false
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let profile = String(data: data, encoding: .ascii) else {
      return false
    }
    return profile.contains("<key>aps-environment</key>")
  }

  // MARK: - Signed entitlement inspection
  //
  // `SecTaskCreateFromSelf` / `SecTaskCopyValueForEntitlement` are declared
  // for macOS / Mac Catalyst rather than for a plain iOS build, so the
  // symbols are resolved with `dlsym` at runtime instead of being imported
  // directly: a direct import would break the whole build if a future SDK
  // ever removed them. When the symbols are unavailable the inspection is
  // simply skipped and the caller falls back to the APNs registration
  // result, which is the more reliable signal anyway.

  // `Unmanaged` makes the +1 ownership explicit: both SecTask entry points
  // follow the CoreFoundation "Create"/"Copy" rule, so the caller owns the
  // returned reference. Relying on the implicit convention of a raw
  // `@convention(c)` function pointer would either leak or over-release.
  private typealias SecTaskCreateFromSelfFn = @convention(c) (
    AnyObject?
  ) -> Unmanaged<AnyObject>?
  private typealias SecTaskCopyValueForEntitlementFn = @convention(c) (
    AnyObject?,
    CFString,
    UnsafeMutablePointer<Unmanaged<CFError>?>?
  ) -> Unmanaged<AnyObject>?

  // The iOS SDK does not expose the `RTLD_DEFAULT` macro to Swift, so the
  // Darwin pseudo-handle for "search the global symbol scope" is spelled out.
  // Its value is ABI-stable (-2) across Darwin platforms.
  private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

  /// Resolved once at class initialisation.
  private static let secTaskSymbols: (
    create: SecTaskCreateFromSelfFn,
    copy: SecTaskCopyValueForEntitlementFn
  )? = {
    guard
      let createSymbol = dlsym(AppDelegate.rtldDefault, "SecTaskCreateFromSelf"),
      let copySymbol = dlsym(AppDelegate.rtldDefault, "SecTaskCopyValueForEntitlement")
    else {
      return nil
    }
    return (
      create: unsafeBitCast(createSymbol, to: SecTaskCreateFromSelfFn.self),
      copy: unsafeBitCast(copySymbol, to: SecTaskCopyValueForEntitlementFn.self)
    )
  }()

  /// `errSecCSMissingEntitlement` — the Security framework's way of saying
  /// "this app does not carry that entitlement". Declared as a literal
  /// because the constant is not exposed to Swift on every SDK.
  private static let errSecCSMissingEntitlement: CFIndex = -67030

  /// Whether the signed app carries `aps-environment`.
  ///
  /// * `true`  — the entitlement is present.
  /// * `false` — the entitlement is definitely absent.
  /// * `nil`   — the platform does not let us inspect the signed task, so
  ///             the caller has to use another signal.
  private func signedApsEnvironment() -> Bool? {
    guard let symbols = Self.secTaskSymbols else { return nil }
    guard let taskRef = symbols.create(nil) else { return nil }
    // `SecTaskCreateFromSelf` is a "Create" function: consuming the +1 here
    // keeps Swift from leaking the task on every call.
    let task = taskRef.takeRetainedValue()
    var error: Unmanaged<CFError>?
    guard let valueRef = symbols.copy(task, "aps-environment" as CFString, &error) else {
      // A NULL value with no error means the entitlement is simply not
      // there. The Security framework reports a missing entitlement as
      // `errSecCSMissingEntitlement` (-67030) in some OS versions, which is
      // also "absent" rather than "unknown". Any other error means we could
      // not tell.
      if let cfError = error?.takeRetainedValue() {
        let code = CFErrorGetCode(cfError)
        if code == Self.errSecCSMissingEntitlement { return false }
        return nil
      }
      return false
    }
    // "...CopyValue..." follows the Copy rule as well.
    let value = valueRef.takeRetainedValue()
    if let env = value as? String {
      return !env.isEmpty
    }
    if let envs = value as? [String] {
      return envs.contains { !$0.isEmpty }
    }
    // The key exists but carries an unexpected type: treat it as present.
    return true
  }

  /// The raw `aps-environment` value of the signed app, for diagnostics.
  private func signedApsEnvironmentValue() -> String? {
    guard let symbols = Self.secTaskSymbols else { return nil }
    guard let taskRef = symbols.create(nil) else { return nil }
    let task = taskRef.takeRetainedValue()
    guard let valueRef = symbols.copy(task, "aps-environment" as CFString, nil) else {
      return nil
    }
    let value = valueRef.takeRetainedValue()
    if let env = value as? String { return env }
    if let envs = value as? [String] { return envs.joined(separator: ",") }
    return nil
  }

  /// Expands a normalized Vision box by `fraction` of its own size on every
  /// side, clamped to the image.
  private func expandedBox(_ box: CGRect, fraction: CGFloat) -> CGRect {
    return box.insetBy(dx: -box.width * fraction, dy: -box.height * fraction)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  /// Intersection area of `a` and `b` divided by the area of `a`.
  private func intersectionRatio(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    if intersection.isEmpty || a.width <= 0 || a.height <= 0 { return 0 }
    return Double(intersection.width * intersection.height / (a.width * a.height))
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
        "bodyCount": 0,
        "faceSizeRatio": 0.0,
        "facePositionedCenter": false,
        "faceTouchesImageEdge": false,
        "completeFaceDetected": false,
        "faceObstructed": false,
        "bothEyesClosed": false,
        "textOverFace": false,
        "objectOverFace": false,
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
        "bodyCount": 0,
        "faceSizeRatio": 0.0,
        "facePositionedCenter": false,
        "faceTouchesImageEdge": false,
        "completeFaceDetected": false,
        "faceObstructed": false,
        "bothEyesClosed": false,
        "textOverFace": false,
        "objectOverFace": false,
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

        // Text recognition: catches cards, signs, watermarks and screenshots
        // before they ever reach server-side AI. Revision 3 (iOS 16+) adds
        // many more scripts — including Hebrew and Arabic, the common card
        // languages for RTL users — so prefer it when the OS supports it.
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        if #available(iOS 16.0, *) {
          textRequest.revision = 3
        }

        // Salient rectangle detection: a card/document held up in a selfie is
        // a rectangle even when its text is too small or low-contrast for OCR
        // to read — the exact case the text-only gate misses. Faces are not
        // rectangular, so this does not fire on ordinary portraits.
        // 0.15 (above Vision's 0.1 default): below that, background décor such
        // as pillow embroidery and tile motifs was detected as "documents".
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumAspectRatio = 0.3
        rectangleRequest.maximumAspectRatio = 3.0
        rectangleRequest.minimumSize = 0.15
        rectangleRequest.minimumConfidence = 0.5
        rectangleRequest.quadratureTolerance = 20.0
        rectangleRequest.maximumObservations = 5

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, bodyRequest, textRequest, rectangleRequest])

        let faceObservations = (faceRequest.results as? [VNFaceObservation]) ?? []
        let bodyObservations = (bodyRequest.results as? [VNHumanObservation]) ?? []
        let textObservations = (textRequest.results as? [VNRecognizedTextObservation]) ?? []
        let rectangleObservations = (rectangleRequest.results as? [VNRectangleObservation]) ?? []

        let faceCount = faceObservations.count
        let containsFace = faceCount > 0
        let faceConfidence = faceObservations.map(\.confidence).max() ?? 0
        let containsBody = !bodyObservations.isEmpty
        let bodyConfidence = bodyObservations.map(\.confidence).max() ?? 0
        // Spot me single-person gate input. Count confident bodies only so a
        // low-confidence background detection does not reject a solo selfie;
        // any observation still counts as one body.
        let confidentBodyCount = bodyObservations.filter { $0.confidence >= 0.5 }.count
        let bodyCount = bodyObservations.isEmpty ? 0 : max(1, confidentBodyCount)

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

        // Check for face obstruction (using roll/yaw if available).
        // 0.75 rad (~43°): a handheld selfie taken from a low angle or while
        // lying down routinely passed the old 0.5 rad (~29°) limit as a
        // "not clearly visible" failure on a perfectly sharp face.
        let faceObstructed = faceObservations.contains { face in
          if let roll = face.roll, let yaw = face.yaw {
            return abs(roll.doubleValue) > 0.75 || abs(yaw.doubleValue) > 0.75
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

        // Text analysis: per-observation metrics so the Dart side can flag
        // substantial text (cards/signs/watermarks) while ignoring incidental
        // text like small shirt prints. Vision boxes are normalized (origin
        // bottom-left); the ratios below are origin-independent.
        var textBlocks: [[String: CGFloat]] = []
        var textAreaSum: Double = 0
        var largestTextAreaRatio: Double = 0
        var largestTextHeightRatio: Double = 0
        var largestTextWidthRatio: Double = 0
        var largestTextCharCount = 0

        // Text overlapping the face region: a card or document held over the
        // face. Independent of the substantial-text thresholds — even 2
        // recognized characters inside the face box condemn the photo
        // (low-contrast cards often yield almost no OCR hits, which is exactly
        // the case that used to slip through).
        let largestFaceObservation = faceObservations.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        // Diagnostics for the failure dialog: worst-case head rotation of the
        // largest face in degrees (Vision exposes roll/yaw only, in radians).
        let headTiltDegrees: Double? = largestFaceObservation.map { face in
          let rollDeg = abs(face.roll?.doubleValue ?? 0) * 180 / .pi
          let yawDeg = abs(face.yaw?.doubleValue ?? 0) * 180 / .pi
          return max(rollDeg, yawDeg)
        }
        // Two zones so the user message stays accurate: text/objects over the
        // CORE face box mean "covering"; objects only near the face (or a
        // coarse merged person+card box) mean "document visible" — still a
        // violation, but the face is not occluded and the message must not
        // claim it is.
        let coreFaceZone = largestFaceObservation.map { self.expandedBox($0.boundingBox, fraction: 0.1) }
        let nearFaceZone = largestFaceObservation.map { self.expandedBox($0.boundingBox, fraction: 0.5) }
        var textOverFace = false
        var objectOverFace = false
        var documentNearFace = false

        // Region overlays for the failure dialog (normalized, top-left origin
        // to match Android).
        let faceBoxNormalized: [String: Double]? = largestFaceObservation.map { face in
          [
            "x": Double(face.boundingBox.minX),
            "y": Double(1 - face.boundingBox.maxY),
            "w": Double(face.boundingBox.width),
            "h": Double(face.boundingBox.height),
          ]
        }
        var issueBoxes: [[String: Any]] = []

        func normalizedIssueBox(_ box: CGRect, label: String) -> [String: Any] {
          return [
            "x": Double(box.minX),
            "y": Double(1 - box.maxY),
            "w": Double(box.width),
            "h": Double(box.height),
            "label": label,
          ]
        }

        for observation in textObservations {
          guard let candidate = observation.topCandidates(1).first else { continue }
          let charCount = candidate.string.count
          if let coreZone = coreFaceZone, charCount >= 2,
            self.intersectionRatio(observation.boundingBox, coreZone) >= 0.25 {
            textOverFace = true
            issueBoxes.append(normalizedIssueBox(observation.boundingBox, label: "text"))
          }
          guard charCount >= 3 else { continue }
          let box = observation.boundingBox
          let areaRatio = Double(box.width * box.height)
          textAreaSum += areaRatio
          textBlocks.append([
            "x": box.minX,
            "y": 1 - box.maxY, // convert to top-left origin to match Android
            "w": box.width,
            "h": box.height,
          ])
          if areaRatio > largestTextAreaRatio {
            largestTextAreaRatio = Double(areaRatio)
            largestTextHeightRatio = Double(box.height)
            largestTextWidthRatio = Double(box.width)
            largestTextCharCount = charCount
          }
        }
        let textContentAreaRatio = min(textAreaSum, 1.0)

        // Object near/over the face without OCR: a salient rectangle
        // (card/document) intersecting the face zones. Only the first
        // (highest-confidence) match flags and draws — one box tells the
        // story; a stack of boxes is noise.
        //
        // A rectangle counts as a held document only with corroborating
        // evidence — readable text lying on it, or card-sized area with
        // card-like proportions. VNDetectRectangles happily matches
        // background décor (pillow embroidery, tiles, screens), and a
        // close-up selfie's face zones reach the whole background, so
        // without corroboration those patterns were reported as "ID cards"
        // and "something covering your face".
        func isCorroboratedDocument(_ box: CGRect) -> Bool {
          let hasText = textObservations.contains { observation in
            guard let candidate = observation.topCandidates(1).first,
              !candidate.string.isEmpty
            else { return false }
            return self.intersectionRatio(observation.boundingBox, box) >= 0.2
          }
          if hasText { return true }
          let area = Double(box.width * box.height)
          let longer = max(box.width, box.height)
          let shorter = min(box.width, box.height)
          guard shorter > 0 else { return false }
          return area >= 0.03 && Double(longer / shorter) <= 2.5
        }

        if let nearZone = nearFaceZone, let faceObservation = largestFaceObservation {
          let faceArea = Double(
            faceObservation.boundingBox.width * faceObservation.boundingBox.height)
          for rectangle in rectangleObservations {
            let rectBox = rectangle.boundingBox
            guard isCorroboratedDocument(rectBox) else { continue }
            let overlapCore = coreFaceZone.map { self.intersectionRatio(rectBox, $0) } ?? 0
            let overlapNear = self.intersectionRatio(rectBox, nearZone)
            guard overlapCore >= 0.25 || overlapNear >= 0.25 else { continue }
            let rectArea = Double(rectBox.width * rectBox.height)
            let ratioToFace = faceArea > 0 ? rectArea / faceArea : 0
            let overlapWithFace = self.intersectionRatio(rectBox, faceObservation.boundingBox)
            // The detected face itself: high overlap at a comparable size.
            if overlapWithFace >= 0.7 && ratioToFace >= 0.4 && ratioToFace <= 3.0 {
              continue
            }
            if overlapCore >= 0.25 {
              // "Covering your face" only when most of the rectangle sits ON
              // the face box itself. Merely reaching the expanded face zone is
              // exactly what the background behind the user does.
              if overlapWithFace >= 0.5 && ratioToFace <= 3.0 {
                objectOverFace = true
              } else {
                // Near the face but not on it: visible document, no occlusion —
                // and the message must not claim the face is covered.
                documentNearFace = true
              }
              if overlapWithFace < 0.7 && rectArea < 0.6 && ratioToFace <= 3.0 {
                issueBoxes.append(normalizedIssueBox(rectBox, label: "document"))
              }
            } else {
              documentNearFace = true
              if ratioToFace <= 3.0 && rectArea < 0.6 {
                issueBoxes.append(normalizedIssueBox(rectBox, label: "document"))
              }
            }
            break
          }
        }

        let uncertain = !containsFace && !containsBody

        DispatchQueue.main.async {
          result([
            "supported": true,
            "prescreenVersion": 5,
            "containsFace": containsFace,
            "containsBody": containsBody,
            "uncertain": uncertain,
            "faceConfidence": Double(faceConfidence),
            "bodyConfidence": Double(bodyConfidence),
            "faceCount": faceCount,
            "bodyCount": bodyCount,
            "faceSizeRatio": faceSizeRatio,
            "facePositionedCenter": facePositionedCenter,
            "faceTouchesImageEdge": faceTouchesImageEdge,
            "completeFaceDetected": completeFaceDetected,
            "faceObstructed": faceObstructed,
            "headTiltDegrees": headTiltDegrees as Any,
            "bothEyesClosed": false,
            "textOverFace": textOverFace,
            "objectOverFace": objectOverFace,
            "documentNearFace": documentNearFace,
            "faceBox": faceBoxNormalized as Any,
            "issueBoxes": issueBoxes,
            "upperBodyOnly": upperBodyOnly,
            "fullBodyVisible": fullBodyVisible,
            "completeBodyDetected": completeBodyDetected,
            "textContentAreaRatio": textContentAreaRatio,
            "largestTextAreaRatio": largestTextAreaRatio,
            "largestTextHeightRatio": largestTextHeightRatio,
            "largestTextWidthRatio": largestTextWidthRatio,
            "largestTextCharCount": largestTextCharCount,
            "textBlocks": textBlocks
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
            "bodyCount": 0,
            "faceSizeRatio": 0.0,
            "facePositionedCenter": false,
            "faceTouchesImageEdge": false,
            "completeFaceDetected": false,
            "faceObstructed": false,
            "bothEyesClosed": false,
            "textOverFace": false,
            "objectOverFace": false,
            "documentNearFace": false,
            "upperBodyOnly": false,
            "fullBodyVisible": false,
            "completeBodyDetected": false
          ])
        }
      }
    }
  }
}
