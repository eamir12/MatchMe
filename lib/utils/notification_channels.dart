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
