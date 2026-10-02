// lib/services/notification_inbox_service.dart
//
// Client access to the persistent notification inbox (public.user_notifications).
//
// The server writes most rows itself: a DB trigger copies everything that
// enters notification_queue (match expiry warnings, admin broadcasts, match
// extensions, birthday automations, visibility warnings, ...), and the
// push-message edge function inserts chat/new-match pushes directly. The
// client only writes rows for notification kinds that never touch the server
// (live-location-share alerts raised from realtime signals) and reads/marks/
// deletes everywhere else.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One entry in the user's notification inbox — think of it as an email:
/// a subject ([title]), body text, the notification [type] and the time it
/// arrived ([createdAt]).
class NotificationInboxItem {
  final String id;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? deletedAt;

  bool get isUnread => readAt == null;

  NotificationInboxItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    this.readAt,
    this.deletedAt,
  });

  factory NotificationInboxItem.fromMap(Map<String, dynamic> map) {
    return NotificationInboxItem(
      id: map['id']?.toString() ?? '',
      type: (map['type'] ?? 'general').toString(),
      title: (map['title'] ?? '').toString(),
      body: (map['body'] ?? '').toString(),
      data: map['data'] is Map
          ? Map<String, dynamic>.from(map['data'] as Map)
          : <String, dynamic>{},
      createdAt: DateTime.tryParse((map['created_at'] ?? '').toString())
              ?.toLocal() ??
          DateTime.now(),
      readAt: DateTime.tryParse((map['read_at'] ?? '').toString())?.toLocal(),
      deletedAt:
          DateTime.tryParse((map['deleted_at'] ?? '').toString())?.toLocal(),
    );
  }
}

class NotificationInboxService {
  NotificationInboxService._();
  static final NotificationInboxService instance = NotificationInboxService._();

  static const int pageSize = 50;

  SupabaseClient get _client => Supabase.instance.client;

  /// Fetch inbox rows, newest first. Soft-deleted rows are excluded.
  Future<List<NotificationInboxItem>> fetchNotifications({
    int limit = pageSize,
    int offset = 0,
  }) async {
    final response = await _client
        .from('user_notifications')
        .select('id, type, title, body, data, created_at, read_at, deleted_at')
        .filter('deleted_at', 'is', null)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    final rows = (response as List?) ?? const [];
    return rows
        .map((row) =>
            NotificationInboxItem.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  /// Count of unread, non-deleted notifications.
  Future<int> countUnread() async {
    final response = await _client
        .from('user_notifications')
        .select('id')
        .filter('deleted_at', 'is', null)
        .filter('read_at', 'is', null)
        .count(CountOption.exact);
    return response.count;
  }

  Future<void> markRead(String id) async {
    await _client
        .from('user_notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id)
        .filter('read_at', 'is', null);
  }

  Future<void> markAllRead() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    await _client
        .from('user_notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', userId)
        .filter('read_at', 'is', null)
        .filter('deleted_at', 'is', null);
  }

  /// Soft delete so the client list can be reconciled from the server.
  Future<void> delete(String id) async {
    await _client
        .from('user_notifications')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  Future<void> deleteAll() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    await _client
        .from('user_notifications')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', userId)
        .filter('deleted_at', 'is', null);
  }

  /// Subscribe to realtime inserts for the current user's inbox.
  /// Returns the channel; caller owns its lifecycle (see
  /// SupabaseRealtimeManager) and should remove it when the user signs out.
  RealtimeChannel subscribeInbox(
    String userId,
    void Function(NotificationInboxItem item) onInsert,
  ) {
    final channelName = 'notification_inbox_$userId';
    final channel = _client.channel(channelName);
    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'user_notifications',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      callback: (payload) {
        try {
          final record = payload.newRecord;
          if (record.isEmpty) return;
          onInsert(NotificationInboxItem.fromMap(record));
        } catch (e) {
          debugPrint('NotificationInbox: realtime insert error: $e');
        }
      },
    );
    channel.subscribe();
    return channel;
  }
}
