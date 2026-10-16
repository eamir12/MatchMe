// lib/providers/icon_badge_provider.dart
//
// Single source for the OS app-icon badge count: the sum of every unread
// surface the in-app UI actually shows (match banners, chats with unread
// messages, notification inbox).
//
// Why this exists: previously the iOS icon badge was only cleared when the
// user tapped the push notification itself. Opening the app from the home
// screen icon never touched it, and the server pushed `aps.badge >= 1` on
// every notification (with a forced minimum of 1), so the red badge could
// stick forever even with nothing new in the app. Mirroring the in-app
// unread state makes the badge self-correcting: it appears when something
// is unread and clears as soon as the user has seen everything, no matter
// how the app was opened.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';

/// Icon-badge total, or `null` while chat unread state is still loading.
///
/// Returning `null` while `recentChatsProvider` is loading prevents a cold
/// start from stamping 0 over the server-set badge and then flickering back
/// once the real counts arrive.
final iconBadgeCountProvider = Provider<int?>((ref) {
  final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
  if (userId.isEmpty) return 0;

  final matches = ref.watch(unreadMatchCountProvider);
  final inbox = ref.watch(unreadInboxCountProvider);

  final chatsAsync = ref.watch(recentChatsProvider(userId));
  final chats = chatsAsync.asData?.value;
  if (chats == null) {
    // Error (offline with no cache) falls through to 0 so a stale badge
    // still clears; only the loading state is deferred.
    if (chatsAsync.isLoading) return null;
    return matches + inbox;
  }

  return matches + inbox + chats.where((c) => c.unreadCount > 0).length;
});
