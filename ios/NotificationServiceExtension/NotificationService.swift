import UserNotifications

/// MatchMe Notification Service Extension (decrypt-in-tray).
///
/// Status: source is complete and crash-safe, but the Xcode target is NOT
/// wired into `ios/Runner.xcodeproj` yet — see `NSE_SETUP.md` next to this
/// file (5-minute Xcode steps). Until the target exists this file is inert.
///
/// What it does once live:
/// 1. Groups chat pushes per conversation (`threadIdentifier = matchId`) so
///    killed-state trays stack like WhatsApp instead of replacing each other.
/// 2. Keeps the server-localized title/body (the server already localizes
///    `New Match!` / `New message` per `users.preferred_language`).
/// 3. Best-effort E2EE decrypt hook: if the app has handed chat keys to the
///    shared App Group defaults (contract in `NSE_SETUP.md`), the extension
///    swaps the generic placeholder for real text. If no key is present it
///    keeps the server placeholder — never blank, never crashing.
///
/// Memory/time budget: iOS gives ~30s and ~24MB. No network, no keychain
/// access, no force-unwraps. Every failure path calls the content handler
/// with the best-effort content.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let base = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    self.bestAttemptContent = base
    do {
      try self.enrich(base, userInfo: request.content.userInfo)
      contentHandler(base)
    } catch {
      contentHandler(base)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = self.contentHandler, let content = self.bestAttemptContent {
      handler(content)
    }
  }

  private func enrich(
    _ content: UNMutableNotificationContent,
    userInfo: [AnyHashable: Any]
  ) throws {
    let matchId = stringField(userInfo, keys: ["matchId", "match_id"])
    let kind = stringField(userInfo, keys: ["kind", "type"]).lowercased()

    // 1) Conversation grouping for every chat-shaped push.
    if !matchId.isEmpty
      && (kind == "message" || kind == "chat_message" || kind == "chat"
        || kind.isEmpty)
    {
      content.threadIdentifier = "match_\(matchId)"
    }
    if kind == "match" || kind == "new_match", !matchId.isEmpty {
      content.threadIdentifier = "new_match_\(matchId)"
    }

    // 2) + 3) E2EE preview hook. Contract: the Flutter app writes the chat's
    // Base64 message key into the shared App Group defaults under
    // `nse_keys_<matchId>` (see NSE_SETUP.md). Absent keys (today: always)
    // mean we keep the server placeholder.
    guard !matchId.isEmpty else { return }
    guard let preview = self.trySharedDecrypt(userInfo: userInfo, matchId: matchId),
      !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    content.body = preview
  }

  // MARK: - Shared-key decrypt hook (handoof not implemented yet)

  private func trySharedDecrypt(
    userInfo: [AnyHashable: Any],
    matchId: String
  ) -> String? {
    // App Group suite must match the value in NSE_SETUP.md AND the future
    // Runner target capability. Until the Dart side writes keys here,
    // `defaults` is nil and we return nil (keep server placeholder).
    guard let defaults = UserDefaults(suiteName: NotificationService.appGroup) else {
      return nil
    }
    guard let _ = defaults.string(forKey: "nse_keys_\(matchId)") else {
      return nil
    }
    // Key present but no crypto in the extension yet — returning nil keeps
    // the localized placeholder. Full AES-GCM lands with the key-handoff
    // change (documented in NSE_SETUP.md step 4).
    return nil
  }

  private static var appGroup: String {
    // MUST match the App Group created in Xcode (NSE_SETUP.md step 2).
    return "group.com.example.matchme"
  }

  private func stringField(
    _ dict: [AnyHashable: Any],
    keys: [String]
  ) -> String {
    for key in keys {
      if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      // FCM nests custom keys under `data` for NSE delivery in some setups.
      if let nested = dict["data"] as? [String: Any],
        let value = nested[key] as? String,
        !value.trimmingCharacters(in: .whitespaces).isEmpty
      {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return ""
  }
}
