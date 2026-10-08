// lib/services/chat_archive_service.dart
//
// Server-side archive flag for chats. public.chats holds one row per
// (user, match), so writing archived_at on the caller's own rows archives a
// chat for them only — the other participant's view is untouched. RLS
// ("users_update_own_chats") permits exactly this update.
//
// Archiving is a display concern only: the row keeps receiving updates from
// the chat-message triggers and the chat still receives notifications. The
// client applies the change optimistically through LocalDbService
// .setChatsArchived first, so the UI moves immediately even offline; this
// call then makes it durable and the next sync reconciles.

import 'package:flutter/foundation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatArchiveService {
  ChatArchiveService._();
  static final ChatArchiveService instance = ChatArchiveService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// One-stop entry for every surface that archives chats (the Chats tab and
  /// Home's Recent Chats): optimistic local cache write first so the UI moves
  /// immediately (and the change stands while offline), then a best-effort
  /// server write. The next sync reconciles with the server's archived_at
  /// either way.
  static Future<void> archiveChats({
    required String userId,
    required LocalDbService localDb,
    required Set<String> matchIds,
    required bool archived,
  }) async {
    if (matchIds.isEmpty) return;
    await localDb.setChatsArchived(userId, matchIds, archived);
    if (shouldSkipSupabaseCalls()) return;
    try {
      await instance.setArchived(matchIds, archived: archived);
    } catch (e) {
      debugPrint('ChatArchiveService: archiveChats($archived) failed: $e');
    }
  }

  /// Archive or unarchive a batch of chats for the signed-in user.
  Future<void> setArchived(
    Set<String> matchIds, {
    required bool archived,
  }) async {
    if (matchIds.isEmpty) return;
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    try {
      await _client
          .from('chats')
          .update({
            'archived_at':
                archived ? DateTime.now().toUtc().toIso8601String() : null,
          })
          .eq('user_id', userId)
          .inFilter('match_id', matchIds.toList());
    } catch (e) {
      debugPrint('ChatArchiveService: setArchived($archived) failed: $e');
      rethrow;
    }
  }
}
