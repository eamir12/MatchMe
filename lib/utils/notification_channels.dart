import 'package:flutter/foundation.dart';

/// Android notification-channel ids for admin broadcasts.
///
/// Android 8+ (API 26+) takes a notification's sound and vibration from its
/// **channel**, never from the per-notification `playSound`/`enableVibration`
/// flags, and a channel's sound/vibration cannot be changed after it is created.
/// The recipient's in-app "Admin announcements" sound/vibrate preference can
/// therefore only be honoured by sending the push to a matching channel:
///
///   sound + vibrate -> admin_broadcasts          (default alerting channel)
///   sound only      -> admin_broadcasts_sound
///   vibrate only    -> admin_broadcasts_vibrate
///   neither         -> admin_broadcasts_silent
///
/// The server mirrors this mapping in
/// `public.admin_broadcast_channel_id(boolean, boolean)`
/// (supabase/migrations/20260925000000_admin_broadcast_alert_preferences.sql);
/// keep both sides in sync. `MobileLocalNotificationService.ensureInitialized()`
/// pre-creates every id below so an FCM push that targets a channel which has
/// never been used still lands with the intended alerting behaviour.
class AdminBroadcastChannels {
  const AdminBroadcastChannels._();

  static const String alerting = 'admin_broadcasts';
  static const String soundOnly = 'admin_broadcasts_sound';
  static const String vibrateOnly = 'admin_broadcasts_vibrate';
  static const String silent = 'admin_broadcasts_silent';

  /// Every channel the server can target (pre-created on the device).
  static const List<String> all = <String>[
    alerting,
    soundOnly,
    vibrateOnly,
    silent,
  ];

  /// Channel matching the user's admin-announcement alert preference.
  static String idFor({
    required bool soundEnabled,
    required bool vibrateEnabled,
  }) {
    if (soundEnabled) {
      return vibrateEnabled ? alerting : soundOnly;
    }
    return vibrateEnabled ? vibrateOnly : silent;
  }

  static bool playsSound(String channelId) =>
      channelId == alerting || channelId == soundOnly;

  static bool vibrates(String channelId) =>
      channelId == alerting || channelId == vibrateOnly;

  /// Silent channels are created with default importance/priority so the user
  /// still gets a banner, just without sound or vibration.
  static bool isSilent(String channelId) => channelId == silent;

  static String name(String channelId) => switch (channelId) {
    alerting => 'Admin Broadcasts',
    soundOnly => 'Admin Broadcasts (sound)',
    vibrateOnly => 'Admin Broadcasts (vibrate)',
    _ => 'Admin Broadcasts (silent)',
  };

  static String description(String channelId) => switch (channelId) {
    soundOnly => 'Admin broadcast announcements with sound only',
    vibrateOnly => 'Admin broadcast announcements with vibration only',
    silent => 'Admin broadcast announcements without sound or vibration',
    _ => 'Admin broadcast announcements',
  };
}

/// Android notification **group** keys.
///
/// A group is what makes the tray bundle several per-conversation cards into
/// one stack, and it is what lets the unread-badge carrier render as the
/// stack's summary instead of as its own always-visible card.
///
/// Mirrored by `MatchMeBadgeController.GROUP_KEY_CHATS` (Kotlin); keep both in
/// sync. Only conversation cards (chat messages, new match, match extended)
/// belong here — expiry, admin broadcasts and live-location cards are not
/// conversations and stay ungrouped so they never hide behind a chat summary.
class NotificationGroups {
  const NotificationGroups._();

  static const String chats = 'matchme_chats';
}

/// Java's `String.hashCode`, in Dart.
///
/// A tray entry is addressed by `(package, id, tag)`. This app's own Kotlin
/// producers — `MatchMeBackgroundService.showNotification` and
/// `LocationWorker.showFallbackNotification` — post conversation cards with
/// `id = key.hashCode()` computed *in Kotlin*, and the FCM SDK posts the
/// server's card as `id = 0` tagged with the push's collapse key. Dart's
/// `String.hashCode` is a different function over the same string, so a card
/// posted from Dart with `key.hashCode` lands beside the native card instead of
/// replacing it: a second tray entry, and a second buzz, for one message. Any
/// Dart card that has to share a slot with a native one — or retire it — has to
/// hash in the native space.
///
/// UTF-16 code units, `31 * h + c`, truncated to a signed 32-bit int at every
/// step, exactly like `java.lang.String.hashCode`.
int javaStringHashCode(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (31 * hash + unit).toSigned(32);
  }
  return hash;
}

/// The Android tray id for [key]: the native hash on Android, Dart's own hash
/// elsewhere (iOS uses this as the notification request identifier, where no
/// Kotlin code is involved).
int cardIdForPlatform(String key) =>
    defaultTargetPlatform == TargetPlatform.android
    ? javaStringHashCode(key)
    : key.hashCode;
