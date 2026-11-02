import CryptoKit
import UserNotifications

/// MatchMe Notification Service Extension (cached avatar attachment).
///
/// The extension attaches the matched user's already-cached photo from the
/// shared App Group. It never fetches a URL or sends photo data to a server.
/// The server-localized title/body remain unchanged.
///
/// Memory/time budget: iOS gives ~30s and ~24MB. No network, no keychain
/// access, no force-unwraps. Every failure path calls the content handler
/// with the best-effort content.
final class NotificationService: UNNotificationServiceExtension {
  private let deliveryLock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    deliveryLock.lock()
    self.contentHandler = contentHandler
    deliveryLock.unlock()
    guard let base = request.content.mutableCopy() as? UNMutableNotificationContent else {
      finish(with: request.content)
      return
    }
    deliveryLock.lock()
    bestAttemptContent = base
    deliveryLock.unlock()
    do {
      try self.enrich(base, userInfo: request.content.userInfo)
      finish(with: base)
    } catch {
      finish(with: base)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    deliveryLock.lock()
    let content = bestAttemptContent
    deliveryLock.unlock()
    guard let content = content else { return }
    finish(with: content)
  }

  private func finish(with content: UNNotificationContent) {
    deliveryLock.lock()
    let handler = contentHandler
    contentHandler = nil
    deliveryLock.unlock()
    handler?(content)
  }

  private func enrich(
    _ content: UNMutableNotificationContent,
    userInfo: [AnyHashable: Any]
  ) throws {
    let matchId = stringField(userInfo, keys: ["matchId", "match_id"])
    let kind = stringField(userInfo, keys: ["kind", "type"]).lowercased()

    // Keep distinct match lifecycle events in their own notification threads.
    if !matchId.isEmpty
      && (kind == "message" || kind == "chat_message" || kind == "chat"
        || kind.isEmpty)
    {
      content.threadIdentifier = "match_\(matchId)"
    }
    if kind == "match" || kind == "new_match", !matchId.isEmpty {
      content.threadIdentifier = "new_match_\(matchId)"
    }

    guard !matchId.isEmpty else { return }
    try attachCachedAvatar(matchId: matchId, to: content)
  }

  private func attachCachedAvatar(
    matchId: String,
    to content: UNMutableNotificationContent
  ) throws {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: NotificationService.appGroup
    ) else { return }
    let avatarDirectory = container
      .appendingPathComponent("Library/Caches", isDirectory: true)
      .appendingPathComponent("notification_avatars", isDirectory: true)
    let prefix = Self.sha256Hex(matchId) + "-"
    guard let cachedPhoto = try FileManager.default.contentsOfDirectory(
      at: avatarDirectory,
      includingPropertiesForKeys: nil
    ).first(where: {
      $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jpg"
    }) else { return }

    let attachmentDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("matchme_notification_avatars", isDirectory: true)
    try FileManager.default.createDirectory(
      at: attachmentDirectory,
      withIntermediateDirectories: true
    )
    let attachmentURL = attachmentDirectory
      .appendingPathComponent("avatar-\(UUID().uuidString).jpg")
    try FileManager.default.copyItem(at: cachedPhoto, to: attachmentURL)
    let attachment = try UNNotificationAttachment(
      identifier: "matched-user-avatar",
      url: attachmentURL,
      options: nil
    )
    content.attachments = [attachment]
  }

  private static var appGroup: String {
    return "group.com.app.matchme"
  }

  private static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
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
