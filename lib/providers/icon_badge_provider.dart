// lib/providers/icon_badge_provider.dart
//
// Single source for the OS app-icon badge count: the unread entries in the
// persistent notification inbox.
//
// Why this exists: previously the iOS icon badge was only cleared when the
// user tapped the push notification itself. Opening the app from the home
// screen icon never touched it, and the server pushed `aps.badge >= 1` on
// every notification (with a forced minimum of 1), so the red badge could
// stick forever even with nothing new in the app. Mirroring the in-app
// unread state makes the badge self-correcting: it appears when something
// is unread and clears as soon as the user has seen everything, no matter
// how the app was opened.
//
// The inbox is the only surface counted. The match banner and chat list both
// represent events that also get an inbox row (new matches, match extensions,
// every chat message), so adding them on top counted one notification two or
// three times: a single unread chat message produced an unread chat plus an
// unread inbox row, and the iOS icon showed 2.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/notification_inbox_provider.dart';

/// Icon-badge total, or `null` while the initial inbox load is in flight.
///
/// Returning `null` while the inbox has no cached rows prevents a cold start
/// from stamping 0 over the server-set badge and then flickering back once
/// the real counts arrive.
final iconBadgeCountProvider = Provider<int?>((ref) {
  return iconBadgeValueFor(
    userId: Supabase.instance.client.auth.currentUser?.id ?? '',
    inbox: ref.watch(notificationInboxProvider),
  );
});

/// Pure badge calculation used by [iconBadgeCountProvider] and its tests.
int? iconBadgeValueFor({
  required String userId,
  required NotificationInboxState inbox,
}) {
  if (userId.isEmpty) return 0;
  if (inbox.isLoading && inbox.items.isEmpty) return null;
  return inbox.unreadCount;
}
