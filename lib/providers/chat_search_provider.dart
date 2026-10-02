// lib/providers/chat_search_provider.dart
//
// Full-text search across a user's messages.
//
// Runs on-device. Chat messages are end-to-end encrypted, so the server holds
// only ciphertext and cannot search it — an index on the server would mean
// handing over every message the user has ever sent, which is exactly what the
// product promises not to do. The client holds the keys, so the client searches.
//
// Consequence worth being honest about with users: a message that has never
// been synced to this device cannot be found, because there is no plaintext
// here to match. Opening a chat syncs it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:matchme/services/local_db_service.dart';

export 'package:matchme/services/local_db_service.dart' show MessageSearchHit;
/// A search request: the text, and which chats are in scope.
///
/// The scope is the chat list as currently filtered, so the user searching
/// "climbing" inside a filtered-by-intent list gets results from that list, not
/// from chats they are not looking at.
class ChatSearchRequest {
  const ChatSearchRequest({
    required this.query,
    required this.matchIds,
  });

  final String query;
  final List<String> matchIds;

  bool get isEmpty => query.trim().isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ChatSearchRequest &&
      other.query == query &&
      other.matchIds.length == matchIds.length &&
      other.matchIds.every(matchIds.contains);

  @override
  int get hashCode => Object.hash(query, matchIds.length);
}

class ChatFullTextSearch extends Notifier<AsyncValue<List<MessageSearchHit>>> {
  Timer? _debounce;

  @override
  AsyncValue<List<MessageSearchHit>> build() {
    ref.onDispose(() => _debounce?.cancel());
    return const AsyncValue.data(<MessageSearchHit>[]);
  }

  /// Debounced entry point, wired to the search field's onChanged.
  ///
  /// The debounce matters: this walks every cached message in scope, and
  /// running it per keystroke would re-do that work for each character typed.
  void search(ChatSearchRequest request) {
    _debounce?.cancel();

    if (request.isEmpty) {
      state = const AsyncValue.data(<MessageSearchHit>[]);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 280), () async {
      state = const AsyncValue.loading();
      try {
        final hits = await ref
            .read(localDbProvider)
            .searchCachedMessages(
              request.query,
              matchIds: request.matchIds,
            );
        state = AsyncValue.data(hits);
      } catch (e, st) {
        state = AsyncValue.error(e, st);
      }
    });
  }

  /// Clears results and cancels any in-flight debounce.
  void clear() {
    _debounce?.cancel();
    state = const AsyncValue.data(<MessageSearchHit>[]);
  }
}

/// One search state per chat list that uses it (e.g. `'chats'` for the Chats
/// screen, `'home'` for Home's Recent Chats). The Chats screen and Home can
/// both be alive at once with different queries/scopes, so a single shared
/// state would leak one list's results (and loading state) into the other.
final chatFullTextSearchProvider = NotifierProvider.family<
  ChatFullTextSearch,
  AsyncValue<List<MessageSearchHit>>,
  String
>((_) => ChatFullTextSearch());

/// Newest body hit per chat.
///
/// The full-text pass yields newest-first within each chat, so the first hit
/// per matchId is the most recent matching text — the snippet a row previews
/// and the message an opened chat scrolls to.
Map<String, MessageSearchHit> newestHitByChat(
  List<MessageSearchHit>? hits,
) {
  final map = <String, MessageSearchHit>{};
  for (final h in hits ?? const <MessageSearchHit>[]) {
    map.putIfAbsent(h.matchId, () => h);
  }
  return map;
}
