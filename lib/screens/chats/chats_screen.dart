// lib/screens/chats/chats_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/services/chat_archive_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/widgets/multi_select.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:matchme/utils/chat_inbox_utils.dart';
import 'package:matchme/widgets/list_filter_bar.dart';
import 'package:matchme/providers/chat_search_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/safe_text.dart';

final supabase = Supabase.instance.client;

/// ChatsScreen
/// - By default this widget does NOT render its own AppBar (so it can be used inside
///   the app's top-level Scaffold in MainNavigationScreen without producing duplicate bars).
/// - Set [showAppBar] to true if you want a self-contained Scaffold + AppBar (e.g., when
///   navigating to ChatsScreen directly).
///
/// Multi-select: long-press a chat row to enter selection mode (shared
/// machinery in lib/widgets/multi_select.dart), tap more rows, then Archive or
/// Unarchive from the bottom bar. Archived chats move to the Archived view
/// (entry row below the search bar); archiving is per-user and display-only —
/// archived chats still receive notifications.
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

  // ── Archive view filter state (independent of the active list) ──
  //
  // The Archived view is its own list, so it keeps its own search, filters
  // and sort. Switching between the two views does not clear either side's
  // state — the user can return to a filtered active list after browsing
  // archived chats, and vice versa.
  String? _archivedSelectedIntentKey;
  bool _archivedUnreadOnly = false;
  final TextEditingController _archivedSearchController =
      TextEditingController();
  String _archivedSearchQuery = '';
  MatchTypeFilter _archivedMatchTypeFilter = MatchTypeFilter.all;
  ListSortOption _archivedSortOption = ListSortOption.recent;

  /// Multi-select state. The controller holds the selected match ids; while
  /// it is non-empty the screen is in selection mode.
  final SelectionController _selection = SelectionController();

  /// Whether the Archived view (instead of the main chat list) is shown.
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _archivedSearchController.dispose();
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// Archive/unarchive the given chats. The actual local+server work lives in
  /// ChatArchiveService.archiveChats, shared with Home's Recent Chats row
  /// menu; this adds the selection reset and the confirmation snackbar.
  /// Used both by the bulk selection bar and by the per-row ⋮ menu (a single
  /// chat).
  Future<void> _setChatsArchived(Set<String> ids, bool archived) async {
    if (ids.isEmpty) return;
    _selection.clear();
    final userId = supabase.auth.currentUser?.id;
    if (userId != null && userId.isNotEmpty) {
      await ChatArchiveService.archiveChats(
        userId: userId,
        localDb: ref.read(localDbProvider),
        matchIds: ids,
        archived: archived,
      );
    }
    if (!mounted) return;
    final l10n = ref.read(localizationProvider);
    // One chat reads better without the count ("Chat archived" vs
    // "1 chats archived"); the count keys cover every other size.
    final message = ids.length == 1
        ? l10n.getString(
            archived ? 'chatsArchivedOne' : 'chatsUnarchivedOne',
          )
        : l10n.getString(
            archived ? 'chatsArchivedCount' : 'chatsUnarchivedCount',
            params: {'count': ids.length.toString()},
          );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

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
  /// compose in one readable order rather than interleaved. Takes [sortOption]
  /// because the active list and the Archived view each keep their own sort.
  List<ChatModel> _sortChats(
    List<ChatModel> chats,
    ListSortOption sortOption,
  ) {
    if (sortOption == ListSortOption.recent) return chats;
    final sorted = List<ChatModel>.from(chats);
    switch (sortOption) {
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

  /// Clears the search field (and its full-text results) for whichever view
  /// is currently shown.
  void _clearViewSearch() {
    final key = _showArchived ? 'chats_archived' : 'chats';
    (_showArchived ? _archivedSearchController : _searchController).clear();
    ref.read(chatFullTextSearchProvider(key).notifier).clear();
    setState(() {
      if (_showArchived) {
        _archivedSearchQuery = '';
      } else {
        _searchQuery = '';
      }
    });
  }

  /// Clears every filter, sort and search for whichever view is currently
  /// shown. The other view's state is left untouched.
  void _clearViewFilters() {
    final key = _showArchived ? 'chats_archived' : 'chats';
    (_showArchived ? _archivedSearchController : _searchController).clear();
    ref.read(chatFullTextSearchProvider(key).notifier).clear();
    setState(() {
      if (_showArchived) {
        _archivedSearchQuery = '';
        _archivedSelectedIntentKey = null;
        _archivedUnreadOnly = false;
        _archivedMatchTypeFilter = MatchTypeFilter.all;
        _archivedSortOption = ListSortOption.recent;
      } else {
        _searchQuery = '';
        _selectedIntentKey = null;
        _unreadOnly = false;
        _matchTypeFilter = MatchTypeFilter.all;
        _sortOption = ListSortOption.recent;
      }
    });
  }

  /// Switch between the main chat list and the Archived view.
  ///
  /// Each view keeps its own search/filter/sort state, so switching does not
  /// clear anything — the user can return to a filtered list on either side.
  void _setShowArchived(bool value) {
    setState(() => _showArchived = value);
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

  /// Opens the filter sheet and applies the result to the active view.
  ///
  /// The sheet edits a local draft and the list only changes when the user
  /// presses "Show N results", so tapping through options does not make the
  /// list behind the sheet jump around. The current filter state and the
  /// apply callback are passed in so the same method works for both the
  /// active list and the Archived view, which each keep their own state.
  Future<void> _openFilterSheet({
    required BuildContext context,
    required LocalizationState l10n,
    required List<String> intentKeys,
    required List<AppIntent> allIntents,
    required bool canFilterByMatchType,
    required int Function(ListFilterState draft) countFor,
    required String? selectedIntentKey,
    required MatchTypeFilter matchTypeFilter,
    required bool unreadOnly,
    required ListSortOption sortOption,
    required int unreadConversationCount,
    required void Function(ListFilterState result) apply,
  }) async {
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
        selectedIntentKey: selectedIntentKey,
        matchType: matchTypeFilter,
        extraToggleKey: 'unread',
        extraToggleLabel: unreadConversationCount == 0
            ? l10n.getString('chatsUnreadOnly')
            : l10n.getString(
                'chatsUnreadOnlyWithCount',
                params: {'count': '$unreadConversationCount'},
              ),
        extraToggleActive: unreadOnly,
        sort: sortOption,
      ),
    );
    if (result == null || !mounted) return;
    apply(result);
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
        // Archive is per-user: split the cached list into what this screen
        // shows in its two views.
        final activeChats =
            filterArchivedChats(chats, archived: false);
        final archivedChats =
            filterArchivedChats(chats, archived: true);
        final viewChats = _showArchived ? archivedChats : activeChats;

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

        // ── View-specific filter/sort/search state ──
        //
        // The active list and the Archived view keep independent state. Pick
        // whichever view is currently on screen so the whole pipeline below
        // uses the right values without branching everywhere.
        final viewSearchQuery =
            _showArchived ? _archivedSearchQuery : _searchQuery;
        final viewUnreadOnly =
            _showArchived ? _archivedUnreadOnly : _unreadOnly;
        final viewSelectedIntentKey =
            _showArchived ? _archivedSelectedIntentKey : _selectedIntentKey;
        final viewMatchTypeFilter =
            _showArchived ? _archivedMatchTypeFilter : _matchTypeFilter;
        final viewSortOption =
            _showArchived ? _archivedSortOption : _sortOption;
        final viewSearchProviderKey =
            _showArchived ? 'chats_archived' : 'chats';

        final normalizedSearch = viewSearchQuery.trim().toLowerCase();

        // Preview search: name and last message. This is instant and always
        // available, so it seeds the results while the full-text pass runs.
        final previewFiltered = normalizedSearch.isEmpty
            ? viewChats
            : viewChats.where((chat) {
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
        final searchAsync = ref.watch(
          chatFullTextSearchProvider(viewSearchProviderKey),
        );
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
            : viewChats
                  .where(
                    (chat) =>
                        bodyMatches.contains(chat.matchId) ||
                        previewFiltered.contains(chat),
                  )
                  .toList();

        final afterUnread = filterUnreadChats(
          searchedChats,
          unreadOnly: viewUnreadOnly,
        );
        final normalizedSelected = viewSelectedIntentKey?.trim().toLowerCase();
        final filteredChats =
            normalizedSelected == null || normalizedSelected.isEmpty
            ? afterUnread
            : afterUnread.where((chat) {
                final keys = chatIntentKeysForChat(chat);
                return keys.contains(normalizedSelected);
              }).toList();

        // Match-basis filter, applied after search/unread/intent so the
        // result count reflects every active filter.
        final afterMatchType = viewMatchTypeFilter == MatchTypeFilter.all
            ? filteredChats
            : filteredChats
                  .where(
                    (chat) =>
                        viewMatchTypeFilter.matches(chatMatchType(chat)),
                  )
                  .toList();

        // Sort last: filters narrow, sort orders.
        final finalChats = _sortChats(afterMatchType, viewSortOption);

        // Newest body hit per chat: replaces the last-message preview with
        // the matching text and auto-scrolls the opened chat to it. Shared
        // with Home's Recent Chats so both lists behave identically.
        final newestHits = newestHitByChat(bodyHits);

        // Intent keys available to filter by come from the current view's
        // chats, so the Archived view offers only the intents present there.
        final filterOptions = <String>{};
        for (final chat in viewChats) {
          filterOptions.addAll(chatIntentKeysForChat(chat));
        }
        final sortedFilterOptions = getOrderedSharedIntentKeys(filterOptions);

        final hasSearch = normalizedSearch.isNotEmpty;
        final hasUnreadFilter = viewUnreadOnly;
        final unreadConversationCount = viewChats
            .where((chat) => chat.unreadCount > 0)
            .length;
        final hasIntentFilter =
            normalizedSelected != null && normalizedSelected.isNotEmpty;
        final hasMatchTypeFilter =
            viewMatchTypeFilter != MatchTypeFilter.all;
        final canFilterByMatchType = MatchTypeFilter.canFilter(
          viewChats.map(chatMatchType).toList(),
        );
        final hasActiveFilters =
            hasSearch ||
            hasUnreadFilter ||
            hasIntentFilter ||
            hasMatchTypeFilter;
        final selecting = _selection.isActive;

        return Column(
          children: [
            if (selecting)
              SelectionHeaderBar(
                controller: _selection,
                allIds:
                    viewChats.map((c) => c.matchId).toList(growable: false),
                selectedLabel: l10n.getString(
                  'inboxSelectedCount',
                  params: {'count': _selection.count.toString()},
                ),
                closeTooltip: l10n.getString('cancel'),
                selectAllTooltip: l10n.getString('inboxSelectAll'),
                deselectAllTooltip: l10n.getString('inboxDeselectAll'),
              )
            else if (_showArchived)
              // Archived view header: back to the main list, title, and the
              // one-line promise that archiving is display-only.
              Row(
                children: [
                  BackButton(
                    onPressed: () => _setShowArchived(false),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.getString('chatsArchived'),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        SafeText(
                          l10n.getString('chatsArchivedHint'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            // Search + filter bar and result count, shown for whichever view
            // is active (active list or Archived) as long as that view has
            // chats to filter.
            if (!selecting && viewChats.isNotEmpty)
              ListSearchBar(
                controller: _showArchived
                    ? _archivedSearchController
                    : _searchController,
                onQueryChanged: (value) {
                  setState(() {
                    if (_showArchived) {
                      _archivedSearchQuery = value;
                    } else {
                      _searchQuery = value;
                    }
                  });
                  // Full-text pass over the cached message bodies. Debounced
                  // inside the provider, and scoped to the chats on screen.
                  ref
                      .read(
                        chatFullTextSearchProvider(viewSearchProviderKey)
                            .notifier,
                      )
                      .search(
                        ChatSearchRequest(
                          query: value,
                          matchIds: viewChats
                              .map((c) => c.matchId)
                              .toList(growable: false),
                        ),
                      );
                },
                onClearQuery: () => _clearViewSearch(),
                onOpenFilters: () => _openFilterSheet(
                  context: context,
                  l10n: l10n,
                  intentKeys: sortedFilterOptions,
                  allIntents:
                      allIntentsAsync.asData?.value ?? const <AppIntent>[],
                  canFilterByMatchType: canFilterByMatchType,
                  countFor: (draft) => _countChats(
                    viewChats,
                    matchIntentById,
                    matchTypeById,
                    draft,
                  ),
                  selectedIntentKey: viewSelectedIntentKey,
                  matchTypeFilter: viewMatchTypeFilter,
                  unreadOnly: viewUnreadOnly,
                  sortOption: viewSortOption,
                  unreadConversationCount: unreadConversationCount,
                  apply: (result) => setState(() {
                    if (_showArchived) {
                      _archivedSelectedIntentKey = result.selectedIntentKey;
                      _archivedMatchTypeFilter = result.matchType;
                      _archivedUnreadOnly = result.extraToggleActive;
                      _archivedSortOption = result.sort;
                    } else {
                      _selectedIntentKey = result.selectedIntentKey;
                      _matchTypeFilter = result.matchType;
                      _unreadOnly = result.extraToggleActive;
                      _sortOption = result.sort;
                    }
                  }),
                ),
                activeFilterCount: ListFilterState(
                  selectedIntentKey: viewSelectedIntentKey,
                  matchType: viewMatchTypeFilter,
                  extraToggleKey: 'unread',
                  extraToggleLabel: unreadConversationCount == 0
                      ? l10n.getString('chatsUnreadOnly')
                      : l10n.getString(
                          'chatsUnreadOnlyWithCount',
                          params: {'count': '$unreadConversationCount'},
                        ),
                  extraToggleActive: viewUnreadOnly,
                  sort: viewSortOption,
                ).activeCount,
                l10n: l10n,
                hintKey: 'chatsSearchHint',
              ),
            if (!selecting && viewChats.isNotEmpty)
              ResultCountLabel(
                shown: finalChats.length,
                total: viewChats.length,
                l10n: l10n,
              ),
            // Entry into the Archived view — the WhatsApp pattern. Only
            // shown from the active (non-selecting) list. Archived chats
            // keep receiving notifications; they are just parked here.
            if (!selecting && !_showArchived && archivedChats.isNotEmpty)
              InkWell(
                onTap: () => _setShowArchived(true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.archive_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.getString('chatsArchived'),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        archivedChats.length.toString(),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
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
                  ? viewChats.isEmpty && initialSyncAsync.isLoading
                      ? Semantics(
                          container: true,
                          label: l10n.getString('generalLoading'),
                          child: const AppSkeletonList(itemCount: 5),
                        )
                      : Column(
                          children: [
                            Expanded(
                              child: _showArchived
                                  ? AppEmptyState(
                                      icon: Icons.archive_outlined,
                                      title: l10n.getString(
                                        'chatsArchivedEmptyTitle',
                                      ),
                                      message: l10n.getString(
                                        'chatsArchivedEmptyMessage',
                                      ),
                                    )
                                  : AppEmptyState(
                                      icon: hasSearch
                                          ? Icons.search_off
                                          : hasUnreadFilter
                                          ? Icons.mark_chat_unread_outlined
                                          : Icons.chat_bubble_outline,
                                      title: viewChats.isEmpty
                                          ? l10n.getString('homeNoChats')
                                          : hasSearch
                                          ? l10n.getString('chatsNoSearchResults')
                                          : hasUnreadFilter
                                          ? l10n.getString(
                                              'chatsNoUnreadResults',
                                            )
                                          : l10n.getString(
                                              'chatsNoIntentResults',
                                            ),
                                      message: viewChats.isEmpty
                                          ? l10n.getString(
                                              'chatsNoConversationsMessage',
                                            )
                                          : hasSearch
                                          ? l10n.getString(
                                              'chatsNoSearchResultsMessage',
                                            )
                                          : hasUnreadFilter
                                          ? l10n.getString(
                                              'chatsNoUnreadResultsMessage',
                                            )
                                          : l10n.getString(
                                              'chatsNoIntentResultsMessage',
                                            ),
                                      actionLabel: viewChats.isEmpty
                                          ? l10n.getString('chatsBrowseMatches')
                                          : hasActiveFilters
                                          ? l10n.getString('chatsClearFilters')
                                          : null,
                                      onAction: viewChats.isEmpty
                                          ? () => ref
                                                .read(
                                                  navigationIndexProvider
                                                      .notifier,
                                                )
                                                .setIndex(1)
                                          : hasActiveFilters
                                          ? _clearViewFilters
                                          : null,
                                    ),
                            ),
                            // Ad at the bottom of the content on the empty
                            // state too — uniform with the Events screen.
                            if (!_showArchived)
                              const AdSlot(placement: AdPlacement.chatsInline),
                            if (!_showArchived) const SizedBox(height: 32),
                          ],
                        )
                  : ListView.builder(
                      itemCount:
                          finalChats.length +
                          (!_showArchived && !selecting ? 1 : 0),
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        if (index == finalChats.length) {
                          // Ad scrolls with the content at the bottom of the
                          // list — uniform with the other tabs.
                          return const AdSlot(
                            placement: AdPlacement.chatsInline,
                          );
                        }
                        final chat = finalChats[index];
                        final hit = hasSearch
                            ? newestHits[chat.matchId]
                            : null;
                        return ChatListItem(
                          chat: chat,
                          showUnreadBorder: true,
                          searchQuery: hasSearch ? viewSearchQuery : null,
                          searchSnippet: hit?.snippet,
                          searchMessageId: hit?.messageId,
                          selectionMode: selecting,
                          selected: _selection.isSelected(chat.matchId),
                          onToggleSelect: () => _selection.toggle(chat.matchId),
                          onLongPress: () => _selection.toggle(chat.matchId),
                          // Per-row ⋮ menu (hidden while selecting, where the
                          // bottom bar covers these actions).
                          onRowMenuArchive: selecting
                              ? null
                              : () => _setChatsArchived(
                                  {chat.matchId}, !chat.isArchived),
                          onRowMenuSelect: selecting
                              ? null
                              : () => _selection.toggle(chat.matchId),
                        );
                      },
                    ),
            ),
            // The bulk-action bar replaces the bottom area while a selection
            // is in progress (the inline ad is skipped inside the list then).
            if (selecting)
              SelectionBottomBar(
                actions: [
                  SelectionAction(
                    icon: _showArchived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                    label: l10n.getString(
                      _showArchived ? 'chatsUnarchive' : 'chatsArchive',
                    ),
                    onPressed: () {
                      final ids = _selection.selected.toSet();
                      _setChatsArchived(ids, !_showArchived);
                    },
                  ),
                ],
              ),
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
        appBar: AppBar(title: ShrinkText(l10n.getString('chatsScreenTitle'))),
        body: content,
      );
    }
    return content;
  }
}
