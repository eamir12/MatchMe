// lib/screens/matches/matches_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/utils/match_score_utils.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:matchme/widgets/list_filter_bar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sort orders the Matches screen offers, in sheet order. Declared here so
/// the sheet and the list cannot disagree about what is available.
const List<ListSortOption> _matchSortOptions = [
  ListSortOption.recent,
  ListSortOption.nameAsc,
  ListSortOption.sharedInterests,
  ListSortOption.topRated,
  ListSortOption.expiringSoon,
];

/// MatchesScreen
///
/// The Matches tab. Search, match-type, intent filters and sort all live
/// behind the single filter button next to the search field, so the list
/// itself stays a clean preview and the two list screens behave identically.
class MatchesScreen extends ConsumerStatefulWidget {
  const MatchesScreen({super.key});

  @override
  ConsumerState<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends ConsumerState<MatchesScreen> {
  String? _selectedIntentKey;
  ListSortOption _sortOption = ListSortOption.recent;

  // Owned by the State, not by build(). Creating a ScrollController inside
  // build() allocates a fresh controller on every rebuild and never disposes
  // the previous one, so the old controller's listeners keep pointing at a
  // dead element and the position resets on each rebuild.
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  MatchTypeFilter _matchTypeFilter = MatchTypeFilter.all;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _clearAllFilters() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _selectedIntentKey = null;
      _matchTypeFilter = MatchTypeFilter.all;
    });
  }

  /// Exact number of matches that would survive [draft], for the live count on
  /// the filter sheet's apply button. Mirrors the list's own predicates.
  int _countMatches(List<MatchModel> matches, ListFilterState draft) {
    final intent = draft.selectedIntentKey?.trim().toLowerCase();
    return matches.where((match) {
      if (draft.matchType != MatchTypeFilter.all &&
          !draft.matchType.matches(match.matchType)) {
        return false;
      }
      if (intent != null && intent.isNotEmpty) {
        final keys = getIntentKeysFromMatchedIntent(
          match.matchedIntent,
        ).map((k) => k.toLowerCase());
        if (!keys.contains(intent)) return false;
      }
      return true;
    }).length;
  }

  /// Opens the filter sheet and applies the result.
  ///
  /// The sheet edits a draft and the list only changes when the user presses
  /// "Show N results", so browsing options does not make the list behind the
  /// sheet jump around.
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
      // types. Filtering against unknown values would hide every row, which
      // reads as data loss rather than as a filter.
      showMatchType: canFilterByMatchType,
      sortOptions: _matchSortOptions,
      initial: ListFilterState(
        selectedIntentKey: _selectedIntentKey,
        matchType: _matchTypeFilter,
        sort: _sortOption,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedIntentKey = result.selectedIntentKey;
      _matchTypeFilter = result.matchType;
      _sortOption = result.sort;
    });
  }

  /// Sorts matches using the current sort option.
  ///
  /// [ListSortOption.distance] needs the other user's profile and the rating
  /// providers, so the list re-sorts automatically as data arrives. Ties always
  /// fall back to newest match first.
  List<MatchModel> _sortMatches(
    WidgetRef ref,
    List<MatchModel> matches,
    UserProfile? currentProfile,
  ) {
    if (_sortOption == ListSortOption.recent) {
      final sorted = List<MatchModel>.from(matches);
      sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return sorted;
    }

    final now =
        ref.watch(matchExpiryNowProvider).asData?.value ?? DateTime.now();
    final entries = <_SortableMatch>[];

    for (final match in matches) {
      if (match.otherUserId.isEmpty) continue;
      final otherProfile = ref
          .watch(userProfileProvider(match.otherUserId))
          .asData
          ?.value;

      int sharedInterests = -1;
      if (currentProfile != null && otherProfile != null) {
        sharedInterests = computeSharedInterestCount(
          currentProfile: currentProfile,
          otherProfile: otherProfile,
          matchedIntent: match.matchedIntent,
        );
      }

      final rating = ref
          .watch(userRatingSummaryProvider(match.otherUserId))
          .asData
          ?.value
          .overallAvg;

      // Display name for the alphabetical sort. The profile resolves
      // asynchronously, so a row whose profile has not loaded yet sorts last
      // rather than jumping around as data arrives.
      final displayName = otherProfile?.name.trim() ?? '';

      Duration? remaining;
      final rem = match.remainingFrom(now);
      remaining = rem <= Duration.zero ? null : rem;

      entries.add(
        _SortableMatch(
          match: match,
          sharedInterests: sharedInterests,
          rating: rating,
          remaining: remaining,
          displayName: displayName,
        ),
      );
    }

    switch (_sortOption) {
      case ListSortOption.sharedInterests:
        entries.sort((a, b) {
          final c = b.sharedInterests.compareTo(a.sharedInterests);
          return c != 0 ? c : b.match.createdAt.compareTo(a.match.createdAt);
        });
      case ListSortOption.topRated:
        entries.sort((a, b) {
          final ar = a.rating ?? -1.0;
          final br = b.rating ?? -1.0;
          final c = br.compareTo(ar);
          return c != 0 ? c : b.match.createdAt.compareTo(a.match.createdAt);
        });
      case ListSortOption.expiringSoon:
        entries.sort((a, b) {
          if (a.remaining == null && b.remaining == null) {
            return b.match.createdAt.compareTo(a.match.createdAt);
          }
          if (a.remaining == null) return 1;
          if (b.remaining == null) return -1;
          final c = a.remaining!.compareTo(b.remaining!);
          return c != 0 ? c : b.match.createdAt.compareTo(a.match.createdAt);
        });
      case ListSortOption.nameAsc:
        entries.sort((a, b) {
          // Unnamed rows go last rather than clustering at the top as an
          // empty string.
          if (a.displayName.isEmpty && b.displayName.isEmpty) {
            return b.match.createdAt.compareTo(a.match.createdAt);
          }
          if (a.displayName.isEmpty) return 1;
          if (b.displayName.isEmpty) return -1;
          final c = a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          );
          return c != 0 ? c : b.match.createdAt.compareTo(a.match.createdAt);
        });
      case ListSortOption.recent:
      case ListSortOption.unreadFirst:
        break;
    }

    return entries.map((e) => e.match).toList();
  }

  void _handleScroll(ScrollIntent intent, ScrollController controller) {
    const double scrollAmount = 200.0;
    if (intent.direction == AxisDirection.down) {
      controller.animateTo(
        controller.offset - scrollAmount,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    } else if (intent.direction == AxisDirection.up) {
      controller.animateTo(
        controller.offset + scrollAmount,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final currentUser = Supabase.instance.client.auth.currentUser;
    final currentProfileAsync = currentUser != null
        ? ref.watch(userProfileProvider(currentUser.id))
        : const AsyncValue<UserProfile?>.loading();
    final allIntentsAsync = ref.watch(allIntentsProvider);
    if (currentUser == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final userId = currentUser.id;
    final allMatchesAsync = ref.watch(recentMatchesProvider(userId));

    // Keep match notification provider alive for realtime subscriptions
    ref.watch(matchNotificationProvider);
    // Same rating realtime as home: keeps top-rated sort + stars live when a
    // matched user receives more ratings from other people.
    ref.watch(ratingSummaryRealtimeProvider);
    // Same pinned realtime as home: match rows show pin/unpin immediately.
    ref.watch(pinnedPartnerRealtimeProvider);

    // Update user activity when matches screen is viewed
    ref.watch(activityUpdateProvider);

    return Scaffold(
      body: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.arrowUp): const ScrollIntent(
            direction: AxisDirection.up,
          ),
          LogicalKeySet(LogicalKeyboardKey.arrowDown): const ScrollIntent(
            direction: AxisDirection.down,
          ),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            ScrollIntent: CallbackAction<ScrollIntent>(
              onInvoke: (ScrollIntent intent) =>
                  _handleScroll(intent, _scrollController),
            ),
          },
          child: RefreshIndicator(
            onRefresh: () async {
              // Refresh app config and external ad providers
              await appConfigService.refresh();
              ref.invalidate(appConfigProvider);
              ref.invalidate(externalAdsEnabledProvider);
              ref.invalidate(externalAdServiceProvider);
              ref.invalidate(adMediationServiceProvider);
              ref.invalidate(recentMatchesProvider(userId));
              ref.invalidate(recentChatsProvider(userId));
              ref.invalidate(userRatingSummaryProvider);
            },
            child: allMatchesAsync.when(
              data: (matches) {
                final currentProfile = currentProfileAsync.asData?.value;
                // Hide expired without chat. Don't watch per-second ticker here to
                // avoid full-list rebuild flicker; MatchBox self-collapses on expiry.
                final now = DateTime.now();
                final chatIdsAsync = ref.watch(userChatIdsProvider(userId));
                final hasChatsLoaded = chatIdsAsync.hasValue;
                final chatIds = chatIdsAsync.asData?.value ?? const <String>{};
                final nonExpired = matches.where((m) {
                  if (!hasChatsLoaded) return true;
                  if (chatIds.contains(m.id)) return true;
                  return m.remainingFrom(now) > Duration.zero;
                }).toList();
                final normalizedSelected = _selectedIntentKey
                    ?.trim()
                    .toLowerCase();
                final filteredMatches =
                    normalizedSelected == null || normalizedSelected.isEmpty
                    ? nonExpired
                    : nonExpired.where((match) {
                        if (match.otherUserId.isEmpty) return false;
                        final keys = getIntentKeysFromMatchedIntent(
                          match.matchedIntent,
                        );
                        return keys.contains(normalizedSelected);
                      }).toList();

                // Text search over the fields the match model actually
                // carries. The other person's name is deliberately not
                // searched: MatchModel stores only other_user_id, and the
                // display name is resolved per-row from userProfileProvider
                // inside MatchBox, so there is no name to filter against
                // without a bulk profile cache.
                final normalizedSearch = _searchQuery.trim().toLowerCase();
                final afterSearch = normalizedSearch.isEmpty
                    ? filteredMatches
                    : filteredMatches.where((match) {
                        final haystack = [
                          match.matchedIntent,
                          match.eventName ?? '',
                        ].join(' ').toLowerCase();
                        return haystack.contains(normalizedSearch);
                      }).toList();

                final searchedMatches = _matchTypeFilter == MatchTypeFilter.all
                    ? afterSearch
                    : afterSearch
                          .where(
                            (match) =>
                                _matchTypeFilter.matches(match.matchType),
                          )
                          .toList();

                final hasActiveFilter =
                    normalizedSelected != null && normalizedSelected.isNotEmpty;
                final filterOptions = <String>{};
                for (final match in nonExpired) {
                  if (match.otherUserId.isEmpty) continue;
                  filterOptions.addAll(
                    getIntentKeysFromMatchedIntent(match.matchedIntent),
                  );
                }
                if (hasActiveFilter) filterOptions.add(normalizedSelected);
                final sortedFilterOptions = getOrderedSharedIntentKeys(
                  filterOptions,
                );
                final allIntents =
                    allIntentsAsync.asData?.value ?? const <AppIntent>[];
                final canFilterByMatchType = MatchTypeFilter.canFilter(
                  nonExpired.map((m) => m.matchType).toList(),
                );
                final searchBar = nonExpired.isEmpty
                    ? const SizedBox.shrink()
                    : ListSearchBar(
                        controller: _searchController,
                        onQueryChanged: (value) =>
                            setState(() => _searchQuery = value),
                        onClearQuery: () => _searchController.clear(),
                        onOpenFilters: () => _openFilterSheet(
                          context,
                          l10n,
                          sortedFilterOptions,
                          allIntents,
                          canFilterByMatchType,
                          (draft) =>
                              _countMatches(nonExpired, draft),
                        ),
                        activeFilterCount: ListFilterState(
                          selectedIntentKey: _selectedIntentKey,
                          matchType: _matchTypeFilter,
                          sort: _sortOption,
                        ).activeCount,
                        l10n: l10n,
                        hintKey: 'matchesSearchHint',
                      );

                final hasAnyActiveFilter =
                    hasActiveFilter ||
                    _matchTypeFilter != MatchTypeFilter.all ||
                    _searchQuery.trim().isNotEmpty;

                if (searchedMatches.isEmpty) {
                  if (!hasAnyActiveFilter) {
                    return AppEmptyState(
                      icon: Icons.people_outline,
                      title: l10n.getString('homeNoMatches'),
                      message: l10n.getString('homeNearbyMapDesc'),
                    );
                  }
                  return Column(
                    children: [
                      searchBar,
                    const SizedBox(height: 2),
                    ResultCountLabel(
                      shown: searchedMatches.length,
                      total: nonExpired.length,
                      l10n: l10n,
                      countKey: 'matchesResultsCount',
                      countOfKey: 'matchesResultsCountOf',
                    ),
                      Expanded(
                        child: AppEmptyState(
                          icon: Icons.filter_alt_off_rounded,
                          title: l10n.getString('matchesNoIntentResults'),
                          message: l10n.getString(
                            'matchesNoIntentResultsMessage',
                          ),
                          actionLabel: l10n.getString('matchesClearFilters'),
                          onAction: _clearAllFilters,
                        ),
                      ),
                    ],
                  );
                }
                final sortedMatches = _sortMatches(
                  ref,
                  searchedMatches,
                  currentProfile,
                );

                return Column(
                  children: [
                      searchBar,
                    const SizedBox(height: 2),
                    ResultCountLabel(
                      shown: searchedMatches.length,
                      total: nonExpired.length,
                      l10n: l10n,
                      countKey: 'matchesResultsCount',
                      countOfKey: 'matchesResultsCountOf',
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(bottom: 80),
                        child: Column(
                          children: [
                            MatchBoxList(
                              matches: sortedMatches,
                              showTitle: false,
                            ),
                            // Ad scrolls with the content at the bottom of
                            // the list — uniform with the other tabs.
                            const AdSlot(placement: AdPlacement.matchesInline),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
              loading: () => AppSkeletonList(
                itemCount: 5,
                semanticLabel: l10n.getString('generalLoading'),
              ),
              error: (e, s) =>
                  Center(child: Text(l10n.getString('generalError'))),
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-match sort keys. [sharedInterests] is -1 while profiles are still
/// loading so those entries sink until the real count arrives; [rating] is
/// null when the other user has no ratings yet; [remaining] is null once the
/// chat window has expired or a chat has started (no urgency).
class _SortableMatch {
  final MatchModel match;
  final int sharedInterests;
  final double? rating;
  final Duration? remaining;
  final String displayName;

  _SortableMatch({
    required this.match,
    required this.sharedInterests,
    required this.rating,
    required this.remaining,
    required this.displayName,
  });
}
