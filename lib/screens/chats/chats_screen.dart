// lib/screens/chats/chats_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:matchme/utils/chat_inbox_utils.dart';
import 'package:matchme/widgets/list_filter_bar.dart';
import 'package:matchme/providers/chat_search_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

/// ChatsScreen
/// - By default this widget does NOT render its own AppBar (so it can be used inside
///   the app's top-level Scaffold in MainNavigationScreen without producing duplicate bars).
/// - Set [showAppBar] to true if you want a self-contained Scaffold + AppBar (e.g., when
///   navigating to ChatsScreen directly).
class ChatsScreen extends ConsumerStatefulWidget {
  final bool showAppBar;
  const ChatsScreen({super.key, this.showAppBar = false});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  String? _selectedIntentKey;
  bool _unreadOnly = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  MatchTypeFilter _matchTypeFilter = MatchTypeFilter.all;
  ListSortOption _sortOption = ListSortOption.recent;

  /// Sort orders the Chats screen offers, in sheet order.
  ///
  /// Declared here, as on the Matches screen, so the sheet and the list cannot
  /// disagree about what is available. Chats has no rating or shared-interest
  /// data to sort on, so it offers a different subset of the same enum — the
  /// control itself is identical.
  static const List<ListSortOption> _chatSortOptions = [
    ListSortOption.recent,
    ListSortOption.unreadFirst,
    ListSortOption.nameAsc,
  ];

  /// Applies the chosen sort to the filtered list.
  ///
  /// Kept separate from the filtering pipeline so search, filters and sort
  /// compose in one readable order rather than interleaved.
  List<ChatModel> _sortChats(List<ChatModel> chats) {
    if (_sortOption == ListSortOption.recent) return chats;
    final sorted = List<ChatModel>.from(chats);
    switch (_sortOption) {
      case ListSortOption.unreadFirst:
        // Conversations with unread messages first, then most recently active.
        // Everything else keeps the provider's recency order.
        sorted.sort((a, b) {
          final au = a.unreadCount > 0 ? 1 : 0;
          final bu = b.unreadCount > 0 ? 1 : 0;
          final c = bu.compareTo(au);
          return c != 0 ? c : b.lastMessageAt.compareTo(a.lastMessageAt);
        });
      case ListSortOption.nameAsc:
        sorted.sort((a, b) {
          final an = a.otherUserName.trim().toLowerCase();
          final bn = b.otherUserName.trim().toLowerCase();
          if (an.isEmpty && bn.isEmpty) {
            return b.lastMessageAt.compareTo(a.lastMessageAt);
          }
          // Unnamed rows sort last rather than clustering at the top.
          if (an.isEmpty) return 1;
          if (bn.isEmpty) return -1;
          return an.compareTo(bn);
        });
      case ListSortOption.recent:
      case ListSortOption.sharedInterests:
      case ListSortOption.topRated:
      case ListSortOption.expiringSoon:
        break;
    }
    return sorted;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(chatFullTextSearchProvider('chats').notifier).clear();
    setState(() => _searchQuery = '');
  }

  void _clearFilters() {
    _searchController.clear();
    ref.read(chatFullTextSearchProvider('chats').notifier).clear();
    setState(() {
      _searchQuery = '';
      _selectedIntentKey = null;
      _unreadOnly = false;
      _matchTypeFilter = MatchTypeFilter.all;
      _sortOption = ListSortOption.recent;
    });
  }

  /// Intent keys for a chat, preferring the underlying match's `matched_intent`
  /// because a chat can outlive a change to its own copy of that field.
  ///
  /// This was a local function inside build(), which meant the filter sheet's
  /// live count could not reuse it and had to approximate. It is a method now
  /// so the list and the count run identical logic and cannot disagree.
  static List<String> _intentKeysForChat(
    dynamic chat,
    Map<String, List<String>> matchIntentById,
  ) {
    final matchId = (chat as dynamic).matchId as String;
    final fromMatches = matchIntentById[matchId];
    if (fromMatches != null && fromMatches.isNotEmpty) return fromMatches;
    final chatMatched = (chat as dynamic).matchedIntent as String?;
    if (chatMatched != null && chatMatched.isNotEmpty) {
      return getIntentKeysFromMatchedIntent(chatMatched);
    }
    return const <String>[];
  }

  /// Exact number of chats that would survive [draft], used for the live count
  /// on the filter sheet's apply button. Mirrors the list's own predicates.
  int _countChats(
    List<ChatModel> chats,
    Map<String, List<String>> matchIntentById,
    Map<String, String> matchTypeById,
    ListFilterState draft,
  ) {
    String matchTypeOf(ChatModel chat) {
      if (chat.matchType.isNotEmpty) return chat.matchType;
      return matchTypeById[chat.matchId] ?? '';
    }

    final intent = draft.selectedIntentKey?.trim().toLowerCase();
    return chats.where((chat) {
      if (draft.matchType != MatchTypeFilter.all &&
          !draft.matchType.matches(matchTypeOf(chat))) {
        return false;
      }
      if (draft.extraToggleActive && chat.unreadCount <= 0) return false;
      if (intent != null && intent.isNotEmpty) {
        final keys = _intentKeysForChat(chat, matchIntentById)
            .map((k) => k.toLowerCase());
        if (!keys.contains(intent)) return false;
      }
      return true;
    }).length;
  }

  /// Opens the filter sheet and applies the result.
  ///
  /// The sheet edits a local draft and the list only changes when the user
  /// presses "Show N results", so tapping through options does not make the
  /// list behind the sheet jump around.
  Future<void> _openFilterSheet(
    BuildContext context,
    LocalizationState l10n,
    List<String> intentKeys,
    List<AppIntent> allIntents,
    bool canFilterByMatchType,
    int Function(ListFilterState draft) countFor,
  ) async {
    final result = await showListFilterSheet(
      context: context,
      l10n: l10n,
      intentKeys: intentKeys,
      allIntents: allIntents,
      resultCountFor: countFor,
      // Only offer the section when the backend is actually delivering match
      // types. Filtering by proximity or event against unknown values would
      // hide every row, which reads as data loss rather than as a filter.
      showMatchType: canFilterByMatchType,
      sortOptions: _chatSortOptions,
      initial: ListFilterState(
        selectedIntentKey: _selectedIntentKey,
        matchType: _matchTypeFilter,
        extraToggleKey: 'unread',
        extraToggleLabel: l10n.getString('chatsUnreadOnly'),
        extraToggleActive: _unreadOnly,
        sort: _sortOption,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedIntentKey = result.selectedIntentKey;
      _matchTypeFilter = result.matchType;
      _unreadOnly = result.extraToggleActive;
      _sortOption = result.sort;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final userId = supabase.auth.currentUser?.id;
    final allIntentsAsync = ref.watch(allIntentsProvider);
    final initialSyncAsync = userId != null
        ? ref.watch(initialHomeSyncProvider(userId))
        : const AsyncValue<void>.loading();

    // recent chats stream
    final recentChatsAsync = (userId != null)
        ? ref.watch(recentChatsProvider(userId))
        : const AsyncValue<List<ChatModel>>.loading();
    final allMatchesAsync = (userId != null)
        ? ref.watch(recentMatchesProvider(userId))
        : const AsyncValue<List<dynamic>>.loading();

    final content = recentChatsAsync.when(
      data: (chats) {
        final matches = allMatchesAsync.asData?.value ?? const [];
        // Map matchId -> intent keys that created that match.
        final matchIntentById = <String, List<String>>{
          for (final m in matches)
            (m as dynamic).id.toString(): getIntentKeysFromMatchedIntent(
              (m as dynamic).matchedIntent as String?,
            ),
        };
        List<String> chatIntentKeysForChat(dynamic chat) =>
            _intentKeysForChat(chat, matchIntentById);

        // Match type for a chat, preferring the server's own column and falling
        // back to the underlying match.
        //
        // The column arrives with migration 20262076000000. The fallback means
        // the proximity/event filter works before that migration is applied —
        // and this screen already loads the matches to resolve intents, so the
        // data is here either way. `event_id` was deliberately not used as a
        // proxy: it is not set for proximity matches, so it would misclassify
        // them as event matches.
        final matchTypeById = <String, String>{
          for (final m in matches)
            (m as dynamic).id.toString():
                ((m as dynamic).matchType as String?) ?? '',
        };
        String chatMatchType(dynamic chat) {
          final direct = (chat as dynamic).matchType as String? ?? '';
          if (direct.isNotEmpty) return direct;
          return matchTypeById[(chat as dynamic).matchId as String] ?? '';
        }

        final normalizedSearch = _searchQuery.trim().toLowerCase();

        // Preview search: name and last message. This is instant and always
        // available, so it seeds the results while the full-text pass runs.
        final previewFiltered = normalizedSearch.isEmpty
            ? chats
            : chats.where((chat) {
                final searchableText = [
                  chat.otherUserName,
                  chat.lastMessage,
                  chat.lastMessageTranslated ?? '',
                ].join(' ').toLowerCase();
                return searchableText.contains(normalizedSearch);
              }).toList();

        // Full-text search: every cached message in the chat, original and
        // machine-translated. Async and on-device — see chat_search_provider.
        // `bodyMatches` is null while it has not resolved, and an empty set once
        // it has resolved with no hits; those are different states and are
        // treated differently below.
        final searchAsync = ref.watch(chatFullTextSearchProvider('chats'));
        final bodyHits = searchAsync.asData?.value;
        final bodyMatches = normalizedSearch.isEmpty
            ? const <String>{}
            : bodyHits?.map((h) => h.matchId).toSet();
        final bodySearchResolved = bodyMatches != null;

        // Union of the two: a chat matches if the word is in its preview OR
        // anywhere in its body. While the full-text pass is still running the
        // preview result stands alone, so results never flicker empty.
        final searchedChats = normalizedSearch.isEmpty || !bodySearchResolved
            ? previewFiltered
            : chats
                  .where(
                    (chat) =>
                        bodyMatches.contains(chat.matchId) ||
                        previewFiltered.contains(chat),
                  )
                  .toList();

        final afterUnread = filterUnreadChats(
          searchedChats,
          unreadOnly: _unreadOnly,
        );
        final normalizedSelected = _selectedIntentKey?.trim().toLowerCase();
        final filteredChats =
            normalizedSelected == null || normalizedSelected.isEmpty
            ? afterUnread
            : afterUnread.where((chat) {
                final keys = chatIntentKeysForChat(chat);
                return keys.contains(normalizedSelected);
              }).toList();

        // Match-basis filter, applied after search/unread/intent so the
        // result count reflects every active filter.
        final afterMatchType = _matchTypeFilter == MatchTypeFilter.all
            ? filteredChats
            : filteredChats
                  .where(
                    (chat) => _matchTypeFilter.matches(chatMatchType(chat)),
                  )
                  .toList();

        // Sort last: filters narrow, sort orders.
        final finalChats = _sortChats(afterMatchType);

        // Newest body hit per chat: replaces the last-message preview with
        // the matching text and auto-scrolls the opened chat to it. Shared
        // with Home's Recent Chats so both lists behave identically.
        final newestHits = newestHitByChat(bodyHits);

        final filterOptions = <String>{};
        for (final chat in chats) {
          filterOptions.addAll(chatIntentKeysForChat(chat));
        }
        final sortedFilterOptions = getOrderedSharedIntentKeys(filterOptions);

        final hasSearch = normalizedSearch.isNotEmpty;
        final hasUnreadFilter = _unreadOnly;
        final unreadConversationCount = chats
            .where((chat) => chat.unreadCount > 0)
            .length;
        final hasIntentFilter =
            normalizedSelected != null && normalizedSelected.isNotEmpty;
        final hasMatchTypeFilter = _matchTypeFilter != MatchTypeFilter.all;
        final canFilterByMatchType = MatchTypeFilter.canFilter(
          chats.map(chatMatchType).toList(),
        );
        final hasActiveFilters =
            hasSearch ||
            hasUnreadFilter ||
            hasIntentFilter ||
            hasMatchTypeFilter;

        return Column(
          children: [
            if (chats.isNotEmpty)
              ListSearchBar(
                controller: _searchController,
                onQueryChanged: (value) {
                  setState(() => _searchQuery = value);
                  // Full-text pass over the cached message bodies. Debounced
                  // inside the provider, and scoped to the chats on screen.
                  ref
                      .read(chatFullTextSearchProvider('chats').notifier)
                      .search(
                        ChatSearchRequest(
                          query: value,
                          matchIds: chats
                              .map((c) => c.matchId)
                              .toList(growable: false),
                        ),
                      );
                },
                onClearQuery: () => _clearSearch(),
                onOpenFilters: () => _openFilterSheet(
                  context,
                  l10n,
                  sortedFilterOptions,
                  allIntentsAsync.asData?.value ?? const <AppIntent>[],
                  canFilterByMatchType,
                  (draft) =>
                      _countChats(chats, matchIntentById, matchTypeById, draft),
                ),
                activeFilterCount: ListFilterState(
                  selectedIntentKey: _selectedIntentKey,
                  matchType: _matchTypeFilter,
                  extraToggleKey: 'unread',
                  extraToggleLabel: unreadConversationCount == 0
                      ? l10n.getString('chatsUnreadOnly')
                      : l10n.getString(
                          'chatsUnreadOnlyWithCount',
                          params: {'count': '$unreadConversationCount'},
                        ),
                  extraToggleActive: _unreadOnly,
                  sort: _sortOption,
                ).activeCount,
                l10n: l10n,
                hintKey: 'chatsSearchHint',
              ),
            if (chats.isNotEmpty)
              ResultCountLabel(
                shown: finalChats.length,
                total: chats.length,
                l10n: l10n,
              ),
            // A quiet line explaining that the search is still running over
            // message bodies. Without it the list looks "wrong" for a beat:
            // the user types, sees nothing change, and assumes the feature
            // failed.
            if (normalizedSearch.isNotEmpty && !bodySearchResolved)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 16, 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.getString('chatsSearchingMessages'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: finalChats.isEmpty
                  ? chats.isEmpty && initialSyncAsync.isLoading
                        ? Semantics(
                            container: true,
                            label: l10n.getString('generalLoading'),
                            child: const AppSkeletonList(itemCount: 5),
                          )
                        : AppEmptyState(
                            icon: hasSearch
                                ? Icons.search_off
                                : hasUnreadFilter
                                ? Icons.mark_chat_unread_outlined
                                : Icons.chat_bubble_outline,
                            title: chats.isEmpty
                                ? l10n.getString('homeNoChats')
                                : hasSearch
                                ? l10n.getString('chatsNoSearchResults')
                                : hasUnreadFilter
                                ? l10n.getString('chatsNoUnreadResults')
                                : l10n.getString('chatsNoIntentResults'),
                            message: chats.isEmpty
                                ? l10n.getString('chatsNoConversationsMessage')
                                : hasSearch
                                ? l10n.getString('chatsNoSearchResultsMessage')
                                : hasUnreadFilter
                                ? l10n.getString('chatsNoUnreadResultsMessage')
                                : l10n.getString('chatsNoIntentResultsMessage'),
                            actionLabel: chats.isEmpty
                                ? l10n.getString('chatsBrowseMatches')
                                : hasActiveFilters
                                ? l10n.getString('chatsClearFilters')
                                : null,
                            onAction: chats.isEmpty
                                ? () => ref
                                      .read(navigationIndexProvider.notifier)
                                      .setIndex(1)
                                : hasActiveFilters
                                ? _clearFilters
                                : null,
                          )
                  : ListView.builder(
                      itemCount: finalChats.length,
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        final chat = finalChats[index];
                        final hit = hasSearch
                            ? newestHits[chat.matchId]
                            : null;
                        return ChatListItem(
                          chat: chat,
                          showUnreadBorder: true,
                          searchQuery: hasSearch ? _searchQuery : null,
                          searchSnippet: hit?.snippet,
                          searchMessageId: hit?.messageId,
                        );
                      },
                    ),
            ),
            if (finalChats.isNotEmpty)
              const AdSlot(placement: AdPlacement.chatsInline),
          ],
        );
      },
      loading: () => AppSkeletonList(
        itemCount: 5,
        semanticLabel: l10n.getString('generalLoading'),
      ),
      error: (e, s) => AppEmptyState(
        icon: Icons.cloud_off,
        title: l10n.getString('generalError'),
        message: l10n.getString('chatsLoadErrorMessage'),
        actionLabel: l10n.getString('generalRetry'),
        onAction: () {
          if (userId != null) {
            ref.invalidate(recentChatsProvider(userId));
          }
        },
      ),
    );

    // If caller asked this widget to be self-contained, render a Scaffold with
    // AppBar, otherwise render the content only (to avoid duplicate app bars
    // when shown inside MainNavigationScreen).
    if (widget.showAppBar) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.getString('chatsScreenTitle'))),
        body: content,
      );
    }
    return content;
  }
}
