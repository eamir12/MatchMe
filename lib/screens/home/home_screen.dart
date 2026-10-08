// lib/screens/home/home_screen.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/greeting_utils.dart';
import 'package:matchme/utils/home_refresh_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/widgets/pinned_location_sheet.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/screens/nearby/nearby_map_screen.dart';
import 'package:matchme/screens/paywall/paywall_screen.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/list_filter_bar.dart';
import 'package:matchme/utils/chat_inbox_utils.dart';
import 'package:matchme/utils/match_score_utils.dart';
import 'package:matchme/providers/chat_search_provider.dart';
import 'package:matchme/services/chat_archive_service.dart';
import 'package:matchme/services/local_db_service.dart';

/// How many rows the Recent Matches and Recent Chats sections show.
///
/// Home is a preview of the app, not a second copy of it. Five rows is enough
/// to show what is there and to make "See all" worth tapping, without
/// duplicating the Matches and Chats tabs on the screen users see most.
const int _kHomePreviewLimit = 5;


final supabase = Supabase.instance.client;

Widget _buildStatCard(
  BuildContext context,
  IconData icon,
  String value,
  String label, {
  String? subValue,
  VoidCallback? onTap,
}) {
  return Expanded(
    child: Semantics(
      container: true,
      button: onTap != null,
      label: '$label: $value${subValue == null ? '' : ', $subValue'}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 30,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.visible,
            ),
            if (subValue != null) ...[
              const SizedBox(height: 2),
              Text(
                subValue,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.visible,
              ),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

// Separate widget for subscription tier card to prevent entire home screen from rebuilding
// when subscription time updates (every minute)
class _SubscriptionTierCard extends ConsumerWidget {
  final UserProfile? profile;
  final String tierKey;
  final VoidCallback onTap;

  const _SubscriptionTierCard({
    required this.profile,
    required this.tierKey,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final remaining = ref.watch(subscriptionTimeRemainingProvider);

    final remainingText = (remaining != null && remaining > Duration.zero)
        ? '${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
        : null;

    return _buildStatCard(
      context,
      Icons.star_outline,
      l10n.getString(tierKey),
      l10n.getString('homeTier'),
      subValue: remainingText,
      onTap: onTap,
    );
  }
}

class _SortableMatch {
  _SortableMatch({
    required this.match,
    required this.sharedInterests,
    required this.rating,
    required this.remaining,
    required this.displayName,
  });

  final MatchModel match;
  final int sharedInterests;
  final double? rating;
  final Duration? remaining;
  final String displayName;
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // ── Matches filter state ──
  String? _selectedMatchesIntentKey;
  MatchTypeFilter _matchTypeFilterMatches = MatchTypeFilter.all;
  ListSortOption _sortOptionMatches = ListSortOption.recent;
  final TextEditingController _matchesSearchController =
      TextEditingController();
  String _matchesSearchQuery = '';

  // ── Chats filter state ──
  String? _selectedChatsIntentKey;
  MatchTypeFilter _matchTypeFilterChats = MatchTypeFilter.all;
  ListSortOption _sortOptionChats = ListSortOption.recent;
  bool _unreadOnlyChats = false;
  final TextEditingController _chatsSearchController = TextEditingController();
  String _chatsSearchQuery = '';

  static const List<ListSortOption> _matchSortOptions = [
    ListSortOption.recent,
    ListSortOption.nameAsc,
    ListSortOption.sharedInterests,
    ListSortOption.topRated,
    ListSortOption.expiringSoon,
  ];

  static const List<ListSortOption> _chatSortOptions = [
    ListSortOption.recent,
    ListSortOption.unreadFirst,
    ListSortOption.nameAsc,
  ];

  void _clearMatchesFilters() {
    _matchesSearchController.clear();
    setState(() {
      _matchesSearchQuery = '';
      _selectedMatchesIntentKey = null;
      _matchTypeFilterMatches = MatchTypeFilter.all;
      _sortOptionMatches = ListSortOption.recent;
    });
  }

  void _clearChatsFilters() {
    _chatsSearchController.clear();
    ref.read(chatFullTextSearchProvider('home').notifier).clear();
    setState(() {
      _chatsSearchQuery = '';
      _selectedChatsIntentKey = null;
      _unreadOnlyChats = false;
      _matchTypeFilterChats = MatchTypeFilter.all;
      _sortOptionChats = ListSortOption.recent;
    });
  }

  /// Archive/unarchive one chat from the Recent Chats row menu. Same shared
  /// path as the Chats tab (optimistic local write + best-effort server
  /// write); only the confirmation snackbar is added here. No selection mode
  /// exists on Home, so this is always a single chat.
  Future<void> _archiveChatFromHome(ChatModel chat) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    final archived = !chat.isArchived;
    await ChatArchiveService.archiveChats(
      userId: userId,
      localDb: ref.read(localDbProvider),
      matchIds: {chat.matchId},
      archived: archived,
    );
    if (!mounted) return;
    final l10n = ref.read(localizationProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.getString(
            archived ? 'chatsArchivedOne' : 'chatsUnarchivedOne',
          ),
        ),
      ),
    );
  }

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

  Future<void> _openMatchesFilterSheet(
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
      showMatchType: canFilterByMatchType,
      sortOptions: _matchSortOptions,
      initial: ListFilterState(
        selectedIntentKey: _selectedMatchesIntentKey,
        matchType: _matchTypeFilterMatches,
        sort: _sortOptionMatches,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedMatchesIntentKey = result.selectedIntentKey;
      _matchTypeFilterMatches = result.matchType;
      _sortOptionMatches = result.sort;
    });
  }

  Future<void> _openChatsFilterSheet(
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
      showMatchType: canFilterByMatchType,
      sortOptions: _chatSortOptions,
      initial: ListFilterState(
        selectedIntentKey: _selectedChatsIntentKey,
        matchType: _matchTypeFilterChats,
        extraToggleKey: 'unread',
        extraToggleLabel: l10n.getString('chatsUnreadOnly'),
        extraToggleActive: _unreadOnlyChats,
        sort: _sortOptionChats,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedChatsIntentKey = result.selectedIntentKey;
      _matchTypeFilterChats = result.matchType;
      _unreadOnlyChats = result.extraToggleActive;
      _sortOptionChats = result.sort;
    });
  }

  List<MatchModel> _sortMatches(
    List<MatchModel> matches,
    UserProfile? currentProfile,
  ) {
    if (_sortOptionMatches == ListSortOption.recent) {
      final sorted = List<MatchModel>.from(matches);
      sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return sorted;
    }

    final now = DateTime.now();
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

    switch (_sortOptionMatches) {
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

  List<ChatModel> _sortChats(List<ChatModel> chats) {
    if (_sortOptionChats == ListSortOption.recent) return chats;
    final sorted = List<ChatModel>.from(chats);
    switch (_sortOptionChats) {
      case ListSortOption.unreadFirst:
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

  // Tracks which account this State object is currently showing. The state
  // can be reused across an account switch on the same device (cached
  // MainNavigationScreen / IndexedStack), so per-user UI state must reset
  // when the signed-in user changes — like a cold start.
  String? _homeUserId;
  // Once the home content has been shown for the current account, never go
  // back to the full-screen loader — even if a provider briefly reports
  // loading again (e.g. a re-sync after the window regained focus). Falling
  // back to the loader on every reload is what made the home screen visibly
  // "twitch" (spinner flash + scroll/content jump) when switching between
  // Chrome and other apps or minimizing/maximizing the window.
  bool _homeWasReady = false;

  /// Set once the full-screen skeleton has been on screen for longer than
  /// [_fullScreenSkeletonBudget], which forces the content to render with
  /// whatever has arrived so far.
  bool _skeletonBudgetExpired = false;
  Timer? _skeletonBudgetTimer;

  /// Upper bound on how long the home screen may show nothing but skeleton
  /// placeholders before the real layout is rendered anyway.
  ///
  /// The `homeReady` gate below exists to avoid flashing an *empty* home while
  /// the first server sync is still in flight. But it also means one slow query
  /// leaves the user staring at full-width grey slabs for as long as the
  /// provider takes — up to the 30s ceiling on `initialHomeSyncProvider`. The
  /// sections each carry their own inline `loading:` skeleton, so rendering
  /// early degrades to a progressive fill-in rather than an empty screen.
  static const Duration _fullScreenSkeletonBudget = Duration(seconds: 2);

  void _cancelSkeletonBudgetTimer() {
    _skeletonBudgetTimer?.cancel();
    _skeletonBudgetTimer = null;
  }

  void _startSkeletonBudgetTimer() {
    if (_skeletonBudgetTimer != null || _skeletonBudgetExpired) return;
    _skeletonBudgetTimer = Timer(_fullScreenSkeletonBudget, () {
      _skeletonBudgetTimer = null;
      _skeletonBudgetExpired = true;
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    developer.log('🏠 HomeScreen init', name: 'MatchMeTrace');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Update user activity when home screen loads
        _updateUserActivity();
        // Normalize subscription on app start to pick up expired subs
        ref.read(subscriptionProvider.notifier).refreshQueueHistory();
        // Pre-warm the subscription tiers cache so the paywall can
        // render even if the user goes offline later without having
        // visited it first. `fetchTiers` is a no-op when offline and
        // returns whatever is in the local cache.
        _prewarmSubscriptionTiersCache();
      }
    });
  }

  Future<void> _prewarmSubscriptionTiersCache() async {
    try {
      // Only fetch when online to avoid a wasted Supabase call. When
      // offline, `fetchTiers` will read from the existing local cache.
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
      await ref.read(subscriptionServiceProvider).fetchTiers();
    } catch (_) {
      // Best-effort: never block home screen rendering on this.
    }
  }

  Future<void> _updateUserActivity() async {
    final user = supabase.auth.currentUser;
    if (user != null) {
      // Only update activity if online to avoid unnecessary network calls
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
      await UserActivityService.instance.pingIfDue(
        user.id,
        source: 'home-screen',
      );
    }
  }

  Widget _buildSectionTitle(
    BuildContext context,
    String title, {
    VoidCallback? onSeeAll,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 16.0, 8.0, 8.0),
      child: Row(
        children: [
          // Flexible, not a bare Text: Hebrew/Spanish titles are long enough to
          // overflow the row (and spill off the leading edge in RTL) where the
          // short English ones fit.
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.visible,
            ),
          ),
          if (onSeeAll != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onSeeAll,
              child: Text(
                ref.watch(localizationProvider).getString('homeSeeAll'),
              ),
            ),
          ],
        ],
      ),
    );
  }


  Widget _buildPinnedLocationCard(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    PinnedLocationState pinState,
  ) {
    // Home stays quiet for users who are not pinned — no passive promo for
    // people simply using the app. Starting a pin lives in contextual spots
    // (map pin FAB, Settings → Matching); this card is status-only.
    if (!pinState.initialized || !pinState.isActive) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = colorScheme.tertiary;
    final title = l10n.getString('pinnedLocationSectionTitle');
    final description = l10n.getString('pinnedLocationSectionDesc');

    final remaining = pinState.remainingFrom(DateTime.now().toUtc());
    final remainingText = remaining != null
        ? l10n.getString('pinnedLocationRemaining', params: {
            'duration': formatDurationWords(l10n, remaining),
          })
        : '';

    return Semantics(
      container: true,
      button: true,
      label: '$title. $description. $remainingText',
      excludeSemantics: true,
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // One canonical management surface for start/extend/unpin — the
          // shared sheet (also used by the map banner and the settings card).
          onTap: () => unawaited(showPinnedLocationSheet(context, ref)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.push_pin_outlined,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          child: Text(
                            remainingText,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // chevron_right auto-mirrors in RTL (matchTextDirection),
                // so it points left in Hebrew without manual branching.
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _logRenderedHomeStats(String label, Map<String, int?> stats) {
    final online = stats['online'];
    final nearby = stats['nearby'] ?? 0;
    debugPrint(
      '📊 [HOME_UI] rendering label=$label online=${online?.toString() ?? '...'} nearby=$nearby displayedToUser=${online?.toString() ?? '...'} reason=live provider value from current server fetch (null means the count is not trustworthy yet, so a placeholder is shown instead of a misleading 0)',
    );
  }

  Widget _buildLoadingIndicator() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSkeletonBox(height: 88, width: double.infinity, borderRadius: 16),
        SizedBox(height: 12),
        AppSkeletonBox(height: 88, width: double.infinity, borderRadius: 16),
      ],
    ),
  );

  Widget _buildEmptyList(String message) => Center(
    heightFactor: 2,
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Text(
        message,
        style: const TextStyle(color: Colors.grey),
        textAlign: TextAlign.center,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isVisible = ref.watch(isVisibleProvider);
    final backgroundMatchingEnabled = ref.watch(
      userPreferencesProvider.select((state) => state.backgroundMatchingMode),
    );
    final pinnedLocationState = ref.watch(pinnedLocationProvider);
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      return Scaffold(
        body: Center(child: Text(l10n.getString('generalError'))),
      );
    }
    // Account switch reusing this State: drop the previous account's intent
    // filters so the new account starts unfiltered, like a cold start.
    // (Assignment during build is safe here — build is already in progress
    // and the values are only read below in this same build.)
    if (_homeUserId != userId) {
      _homeUserId = userId;
      _selectedMatchesIntentKey = null;
      _matchTypeFilterMatches = MatchTypeFilter.all;
      _sortOptionMatches = ListSortOption.recent;
      _matchesSearchController.clear();
      _matchesSearchQuery = '';
      _selectedChatsIntentKey = null;
      _matchTypeFilterChats = MatchTypeFilter.all;
      _sortOptionChats = ListSortOption.recent;
      _unreadOnlyChats = false;
      _chatsSearchController.clear();
      _chatsSearchQuery = '';
      try {
        ref.read(chatFullTextSearchProvider('home').notifier).clear();
      } catch (_) {}
      _homeWasReady = false;
      _skeletonBudgetExpired = false;
      _cancelSkeletonBudgetTimer();
    }

    // Use helper (not ref.watch) — helper itself will watch the connectivityProvider safely.
    final isOnline = connectivityProviderChecker(ref) ?? true;

    ref.watch(matchNotificationProvider);
    // Keep rating-summary realtime alive so matched users' stars update the
    // moment they receive more ratings (broadcast + postgres_changes +
    // periodic safety-net inside the notifier).
    ref.watch(ratingSummaryRealtimeProvider);
    // Keep pinned-partner realtime alive so match rows show pin/unpin
    // immediately (broadcast on pin/extend/unpin/expire + 30s poll).
    ref.watch(pinnedPartnerRealtimeProvider);

    final subscriptionsEnabled = ref.watch(
      appConfigProvider.select(
        (c) => (c['subscription.enabled']?.toLowerCase() ?? 'true') == 'true',
      ),
    );

    final profileState = ref.watch(userProfileProvider(userId));
    final dashboardStats = ref.watch(dashboardStatsProvider);
    final recentMatchesAsync = ref.watch(recentMatchesProvider(userId));
    final recentChatsAsync = ref.watch(recentChatsProvider(userId));
    final allIntentsAsync = ref.watch(allIntentsProvider);
    // Watched at the top level (NOT inside a `profileState.when(data: ...)`
    // callback) on purpose. A `ref.watch` created and torn down as the
    // profile AsyncValue flips between `data`/`loading` triggers a Riverpod
    // reentrancy assertion (paused subscription count mismatch) when a
    // TickerProvider (e.g. the system notification overlay) resumes its
    // subscriptions in the middle of the cascade. See
    // `TotalUnreadChatCountNotifier` in home_providers.dart for the same
    // workaround applied via `ref.listen`.
    final effectiveSub = ref.watch(effectiveCurrentSubscriptionProvider);

    // Gate the entire screen behind a single loading state so sections don't
    // pop in one-by-one with "..." placeholders. The screen is only rendered
    // once every core element (profile, stats, matches, chats) has settled.
    // NOTE: the local-DB streams emit their (possibly empty) cached values
    // almost instantly, so `isLoading` alone cannot distinguish "synced and
    // genuinely empty" from "server sync hasn't landed yet". When online,
    // additionally wait for the first server sync (initialHomeSyncProvider)
    // so the home is never shown empty before populating seconds later.
    final chatIdsAsync = ref.watch(userChatIdsProvider(userId));
    final initialSyncAsync = ref.watch(initialHomeSyncProvider(userId));
    final bool homeReady =
        !profileState.isLoading &&
        (!isOnline || !dashboardStats.isLoading) &&
        !recentMatchesAsync.isLoading &&
        !recentChatsAsync.isLoading &&
        !chatIdsAsync.isLoading &&
        (!isOnline || !initialSyncAsync.isLoading);
    if (homeReady) {
      _homeWasReady = true;
      _cancelSkeletonBudgetTimer();
    }
    // Only gate on the loader before the first successful render for this
    // account, and never for longer than the budget - see
    // [_fullScreenSkeletonBudget].
    final showFullScreenSkeleton =
        !homeReady && !_homeWasReady && !_skeletonBudgetExpired;
    if (showFullScreenSkeleton) {
      _startSkeletonBudgetTimer();
    } else {
      _cancelSkeletonBudgetTimer();
    }
    if (showFullScreenSkeleton) {
      return Scaffold(
        body: Semantics(
          label: l10n.getString('generalLoading'),
          child: const AppSkeletonList(itemCount: 5, itemHeight: 96),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await appConfigService.refresh();
        ref.invalidate(appConfigProvider);
        ref.invalidate(externalAdsEnabledProvider);
        ref.invalidate(internalAdsEnabledProvider);
        ref.invalidate(externalAdServiceProvider);
        ref.invalidate(adMediationServiceProvider);
        ref.invalidate(dashboardStatsProvider);

        final syncManager = ref.read(globalSyncManagerProvider);
        final contentRefresh = HomeContentRefresh(
          syncMatches: () => syncManager.syncMatchesNow(userId),
          syncChats: () => syncManager.syncChatsNow(userId, force: true),
        );
        await Future.wait([
          ref.read(appConfigProvider.notifier).refresh(),
          ref.read(localizationProvider.notifier).syncLanguageAfterLogin(),
          ref.read(themeModeProvider.notifier).refreshFromRemote(),
          ref.read(userPreferencesProvider.notifier).refresh(),
          ref.read(subscriptionProvider.notifier).refreshStatus(),
          ref.read(subscriptionProvider.notifier).refreshQueueHistory(),
          ref.read(isVisibleProvider.notifier).refreshFromLocalAndRemote(),
          ref
              .read(profileSyncProvider)
              .syncProfile(userId, source: 'home-pull-to-refresh'),
          contentRefresh.run(),
        ]);

        ref.invalidate(userProfileProvider(userId));
        ref.invalidate(recentMatchesProvider(userId));
        ref.invalidate(recentChatsProvider(userId));
        // Ratings are aggregated via RPC + cached by FutureProvider.family —
        // must be invalidated explicitly or pull-to-refresh shows stale stars.
        ref.invalidate(userRatingSummaryProvider);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              bottom: 10.0,
            ),
            child: profileState.when(
              data: (profile) {
                final userName =
                    profile?.name.split(' ').first ??
                    l10n.getString('generalUser');
                final String welcomeText;
                if (isUsersBirthdayToday(
                  dateOfBirth: profile?.dateOfBirth,
                  userTimezone: profile?.userTimezone,
                )) {
                  welcomeText =
                      '${l10n.getString('happyBirthday')}, $userName!';
                } else {
                  final greeting = localizedGreeting(
                    l10n,
                    DateTime.now(),
                    gender: profile?.gender,
                  );
                  welcomeText =
                      '${greeting.replaceAll(RegExp(r'[!,]*$'), '').trim()}, $userName!';
                }
                return Text(
                  welcomeText,
                  style: Theme.of(context).textTheme.headlineSmall,
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (e, s) => const SizedBox.shrink(),
            ),
          ),
          // The home-base banner describes the position broadcast to
          // others. While invisible nothing is broadcast, so it is
          // irrelevant and stays hidden. Full pin management (extend/unpin)
          // remains available in Matching settings.
          if (isVisible)
            _buildPinnedLocationCard(context, ref, l10n, pinnedLocationState),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (isOnline && isVisible)
                  dashboardStats.when(
                    data: (stats) {
                      _logRenderedHomeStats('nearby', stats);
                      return _buildStatCard(
                        context,
                        Icons.radar_outlined,
                        "${stats['nearby'] ?? 0}",
                        l10n.getString('homeNearby'),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const NearbyMapScreen(),
                            ),
                          );
                        },
                      );
                    },
                    loading: () => _buildStatCard(
                      context,
                      Icons.radar_outlined,
                      "...",
                      l10n.getString('homeNearby'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const NearbyMapScreen(),
                          ),
                        );
                      },
                    ),
                    error: (e, s) => _buildStatCard(
                      context,
                      Icons.radar_outlined,
                      "0",
                      l10n.getString('homeNearby'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const NearbyMapScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                if (isOnline)
                  dashboardStats.when(
                    data: (stats) {
                      _logRenderedHomeStats('online', stats);
                      return _buildStatCard(
                        context,
                        Icons.people_outline,
                        stats['online']?.toString() ?? "...",
                        l10n.getString('homeOnline'),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const OnlineWorldMapScreen(),
                            ),
                          );
                        },
                      );
                    },
                    loading: () => _buildStatCard(
                      context,
                      Icons.people_outline,
                      "...",
                      l10n.getString('homeOnline'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const OnlineWorldMapScreen(),
                          ),
                        );
                      },
                    ),
                    error: (e, s) => _buildStatCard(
                      context,
                      Icons.people_outline,
                      "...",
                      l10n.getString('homeOnline'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const OnlineWorldMapScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                if (subscriptionsEnabled)
                  profileState.when(
                    data: (p) {
                      // Prefer the effective subscription (which falls back to
                      // the active queue entry) so the tier label and the
                      // "time left" subtext stay in sync when the queued
                      // subscription has been promoted to active before the
                      // user profile has been refreshed. The watch itself
                      // lives at the top of `build` — see the comment there.
                      final effectiveTier = (effectiveSub?.tier ?? 'free')
                          .trim()
                          .toLowerCase();
                      final tierKey =
                          'tier${effectiveTier.isNotEmpty ? effectiveTier.capitalize() : 'Free'}';
                      return _SubscriptionTierCard(
                        profile: p,
                        tierKey: tierKey,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PaywallScreen(),
                            ),
                          );
                        },
                      );
                    },
                    loading: () => _buildStatCard(
                      context,
                      Icons.star_border_outlined,
                      "...",
                      l10n.getString('homeTier'),
                    ),
                    error: (e, s) => _buildStatCard(
                      context,
                      Icons.error_outline,
                      l10n.getString('generalError'),
                      l10n.getString('homeTier'),
                    ),
                  ),
              ],
            ),
          ),
          recentMatchesAsync.when(
            data: (matches) {
              // Filter expired without chat. NOTE: do NOT watch matchExpiryNowProvider
              // here - that rebuilt the whole list every second (visible flicker).
              // Per-row MatchBox has its own 1s ticker and collapses to shrink
              // instantly on expiry, so list stays accurate without parent rebuild.
              // This filter only runs on data change (matches/chats), prune/sync
              // (15s) refreshes it invisibly via distinct provider.
              final now = DateTime.now();
              final chatIdsAsync = ref.watch(userChatIdsProvider(userId));
              final hasChatsLoaded = chatIdsAsync.hasValue;
              final chatIds = chatIdsAsync.asData?.value ?? const <String>{};
              final nonExpiredMatches = matches.where((m) {
                if (!hasChatsLoaded) return true;
                if (chatIds.contains(m.id)) return true;
                return m.remainingFrom(now) > Duration.zero;
              }).toList();
              final canFilterByMatchType = MatchTypeFilter.canFilter(
                nonExpiredMatches.map((m) => m.matchType).toList(),
              );
              final normalizedSelectedMatches = _selectedMatchesIntentKey
                  ?.trim()
                  .toLowerCase();
              final filteredByIntent =
                  normalizedSelectedMatches == null ||
                          normalizedSelectedMatches.isEmpty
                      ? nonExpiredMatches
                      : nonExpiredMatches.where((match) {
                          if (match.otherUserId.isEmpty) return false;
                          final keys = getIntentKeysFromMatchedIntent(
                            match.matchedIntent,
                          );
                          return keys.contains(normalizedSelectedMatches);
                        }).toList();

              final normalizedSearchMatches =
                  _matchesSearchQuery.trim().toLowerCase();
              final afterSearchMatches = normalizedSearchMatches.isEmpty
                  ? filteredByIntent
                  : filteredByIntent.where((match) {
                      final haystack = [
                        match.matchedIntent,
                        match.eventName ?? '',
                      ].join(' ').toLowerCase();
                      return haystack.contains(normalizedSearchMatches);
                    }).toList();

              final afterMatchTypeMatches =
                  _matchTypeFilterMatches == MatchTypeFilter.all
                      ? afterSearchMatches
                      : afterSearchMatches
                          .where(
                            (match) => _matchTypeFilterMatches.matches(
                              match.matchType,
                            ),
                          )
                          .toList();

              final currentProfile = profileState.asData?.value;
              final sortedMatches = _sortMatches(
                afterMatchTypeMatches,
                currentProfile,
              );

              final filterOptions = <String>{};
              for (final match in nonExpiredMatches) {
                if (match.otherUserId.isEmpty) continue;
                filterOptions.addAll(
                  getIntentKeysFromMatchedIntent(match.matchedIntent),
                );
              }
              if (normalizedSelectedMatches != null &&
                  normalizedSelectedMatches.isNotEmpty) {
                filterOptions.add(normalizedSelectedMatches);
              }
              final sortedFilterOptions = getOrderedSharedIntentKeys(
                filterOptions,
              );

              final activeFilterCount = ListFilterState(
                selectedIntentKey: _selectedMatchesIntentKey,
                matchType: _matchTypeFilterMatches,
                sort: _sortOptionMatches,
              ).activeCount;
              final hasActiveMatchesFilter =
                  activeFilterCount > 0 || normalizedSearchMatches.isNotEmpty;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionTitle(
                    context,
                    l10n.getString('homeRecentMatches'),
                    onSeeAll: () {
                      ref.read(navigationIndexProvider.notifier).setIndex(1);
                    },
                  ),
                  if (nonExpiredMatches.isNotEmpty) ...[
                    ListSearchBar(
                      controller: _matchesSearchController,
                      onQueryChanged: (value) =>
                          setState(() => _matchesSearchQuery = value),
                      onClearQuery: () => setState(() {
                        _matchesSearchController.clear();
                        _matchesSearchQuery = '';
                      }),
                      onOpenFilters: () => _openMatchesFilterSheet(
                        context,
                        l10n,
                        sortedFilterOptions,
                        allIntentsAsync.asData?.value ?? const <AppIntent>[],
                        canFilterByMatchType,
                        (draft) => _countMatches(nonExpiredMatches, draft),
                      ),
                      activeFilterCount: activeFilterCount,
                      l10n: l10n,
                      hintKey: 'matchesSearchHint',
                    ),
                    ResultCountLabel(
                      shown: sortedMatches.length,
                      total: nonExpiredMatches.length,
                      l10n: l10n,
                      countKey: 'matchesResultsCount',
                      countOfKey: 'matchesResultsCountOf',
                    ),
                  ],
                  if (sortedMatches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20.0),
                      child: hasActiveMatchesFilter
                          ? AppEmptyState(
                              icon: Icons.filter_alt_off_rounded,
                              title: l10n.getString('matchesNoIntentResults'),
                              message: l10n.getString(
                                'matchesNoIntentResultsMessage',
                              ),
                              actionLabel: l10n.getString(
                                'matchesClearFilters',
                              ),
                              onAction: _clearMatchesFilters,
                            )
                          : _buildEmptyList(l10n.getString('homeNoMatches')),
                    )
                  else
                    MatchBoxList(
                      matches: sortedMatches.take(_kHomePreviewLimit).toList(),
                      showTitle: false,
                    ),
                ],
              );
            },
            loading: _buildLoadingIndicator,
            // The recovery banner at the top of the screen explains why this
            // section is empty and offers a retry.
            error: (e, s) => const SizedBox.shrink(),
          ),
          recentChatsAsync.when(
            data: (chats) {
              // Archived chats live in the Chats tab's Archived view; the
              // Home feed shows active chats only. (Archive is per-user and
              // display-only — see ChatArchiveService.)
              final activeChats =
                  filterArchivedChats(chats, archived: false);
              // Build a lookup from matchId -> matchedIntent keys using the
              // matches that created the chats. This is the only correct
              // source: a chat exists because its underlying match was created
              // for exactly one (or a comma-separated list of) intents.
              final matchesForChats =
                  recentMatchesAsync.asData?.value ?? const [];
              final matchIntentById = <String, List<String>>{
                for (final m in matchesForChats)
                  m.id: getIntentKeysFromMatchedIntent(m.matchedIntent),
              };
              List<String> chatIntentKeysForChat(dynamic chat) =>
                  _intentKeysForChat(chat, matchIntentById);

              final matchTypeById = <String, String>{
                for (final m in matchesForChats)
                  (m as dynamic).id.toString():
                      ((m as dynamic).matchType as String?) ?? '',
              };
              String chatMatchType(dynamic chat) {
                final direct = (chat as dynamic).matchType as String? ?? '';
                if (direct.isNotEmpty) return direct;
                return matchTypeById[(chat as dynamic).matchId as String] ?? '';
              }

              final canFilterByMatchType = MatchTypeFilter.canFilter(
                activeChats.map(chatMatchType).toList(),
              );

              final normalizedSearchChats =
                  _chatsSearchQuery.trim().toLowerCase();

              // Preview search: name and last message. Instant and always
              // available, seeding results while the full-text pass runs.
              // Same pipeline as the Chats screen.
              final previewFilteredChats = normalizedSearchChats.isEmpty
                  ? activeChats
                  : activeChats.where((chat) {
                      final searchableText = [
                        chat.otherUserName,
                        chat.lastMessage,
                        chat.lastMessageTranslated ?? '',
                      ].join(' ').toLowerCase();
                      return searchableText.contains(normalizedSearchChats);
                    }).toList();

              // Full-text search: every cached message body, original +
              // translated (+ decrypted E2E content) — same as Chats screen.
              final searchAsyncChats = ref.watch(
                chatFullTextSearchProvider('home'),
              );
              final bodyHitsChats = searchAsyncChats.asData?.value;
              final bodyMatchesChats = normalizedSearchChats.isEmpty
                  ? const <String>{}
                  : bodyHitsChats?.map((h) => h.matchId).toSet();
              final bodySearchResolvedChats = bodyMatchesChats != null;

              // Union of the two: a chat matches if the word is in its
              // preview OR anywhere in its body.
              final searchedChats =
                  normalizedSearchChats.isEmpty || !bodySearchResolvedChats
                  ? previewFilteredChats
                  : activeChats
                        .where(
                          (chat) =>
                              bodyMatchesChats.contains(chat.matchId) ||
                              previewFilteredChats.contains(chat),
                        )
                        .toList();

              // Newest body hit per chat: replaces the last-message preview
              // with the matching text and auto-scrolls the opened chat.
              final newestHitsChats = newestHitByChat(bodyHitsChats);
              final hasChatsSearch = normalizedSearchChats.isNotEmpty;

              final afterUnreadChats = filterUnreadChats(
                searchedChats,
                unreadOnly: _unreadOnlyChats,
              );

              final normalizedSelectedChats = _selectedChatsIntentKey
                  ?.trim()
                  .toLowerCase();
              final afterIntentChats =
                  normalizedSelectedChats == null ||
                          normalizedSelectedChats.isEmpty
                      ? afterUnreadChats
                      : afterUnreadChats.where((chat) {
                          final keys = chatIntentKeysForChat(chat);
                          return keys.contains(normalizedSelectedChats);
                        }).toList();

              final afterMatchTypeChats =
                  _matchTypeFilterChats == MatchTypeFilter.all
                      ? afterIntentChats
                      : afterIntentChats
                          .where(
                            (chat) => _matchTypeFilterChats.matches(
                              chatMatchType(chat),
                            ),
                          )
                          .toList();

              final sortedChats = _sortChats(afterMatchTypeChats);

              final filterOptions = <String>{};
              for (final chat in activeChats) {
                filterOptions.addAll(chatIntentKeysForChat(chat));
              }
              if (normalizedSelectedChats != null &&
                  normalizedSelectedChats.isNotEmpty) {
                filterOptions.add(normalizedSelectedChats);
              }
              final sortedFilterOptions = getOrderedSharedIntentKeys(
                filterOptions,
              );

              final unreadConversationCount =
                  activeChats.where((c) => c.unreadCount > 0).length;

              final activeFilterCount = ListFilterState(
                selectedIntentKey: _selectedChatsIntentKey,
                matchType: _matchTypeFilterChats,
                extraToggleKey: 'unread',
                extraToggleLabel: unreadConversationCount == 0
                    ? l10n.getString('chatsUnreadOnly')
                    : l10n.getString(
                        'chatsUnreadOnlyWithCount',
                        params: {'count': '$unreadConversationCount'},
                      ),
                extraToggleActive: _unreadOnlyChats,
                sort: _sortOptionChats,
              ).activeCount;
              final hasActiveChatsFilter =
                  activeFilterCount > 0 || normalizedSearchChats.isNotEmpty;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionTitle(
                    context,
                    l10n.getString('homeRecentChats'),
                    onSeeAll: () {
                      ref.read(navigationIndexProvider.notifier).setIndex(2);
                    },
                  ),
                  if (activeChats.isNotEmpty) ...[
                    ListSearchBar(
                      controller: _chatsSearchController,
                      onQueryChanged: (value) {
                        setState(() => _chatsSearchQuery = value);
                        // Full-text pass over the cached message bodies.
                        // Debounced inside the provider, scoped to the chats
                        // on screen. Same as the Chats screen.
                        ref
                            .read(
                              chatFullTextSearchProvider('home').notifier,
                            )
                            .search(
                              ChatSearchRequest(
                                query: value,
                                matchIds: activeChats
                                    .map((c) => c.matchId)
                                    .toList(growable: false),
                              ),
                            );
                      },
                      onClearQuery: () {
                        ref
                            .read(
                              chatFullTextSearchProvider('home').notifier,
                            )
                            .clear();
                        setState(() {
                          _chatsSearchController.clear();
                          _chatsSearchQuery = '';
                        });
                      },
                      onOpenFilters: () => _openChatsFilterSheet(
                        context,
                        l10n,
                        sortedFilterOptions,
                        allIntentsAsync.asData?.value ?? const <AppIntent>[],
                        canFilterByMatchType,
                        (draft) => _countChats(
                          activeChats,
                          matchIntentById,
                          matchTypeById,
                          draft,
                        ),
                      ),
                      activeFilterCount: activeFilterCount,
                      l10n: l10n,
                      hintKey: 'chatsSearchHint',
                    ),
                      ResultCountLabel(
                        shown: sortedChats.length,
                        total: activeChats.length,
                        l10n: l10n,
                      ),
                      // While the full-text pass runs, say so — same as the
                      // Chats screen — instead of showing a stale list.
                      if (hasChatsSearch && !bodySearchResolvedChats)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 16, 8),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 11,
                                height: 11,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.getString('chatsSearchingMessages'),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  if (sortedChats.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20.0),
                      child: hasActiveChatsFilter
                          ? AppEmptyState(
                              icon: Icons.filter_alt_off_rounded,
                              title: l10n.getString('chatsNoIntentResults'),
                              message: l10n.getString(
                                'chatsNoIntentResultsMessage',
                              ),
                              actionLabel: l10n.getString(
                                'chatsClearFilters',
                              ),
                              onAction: _clearChatsFilters,
                            )
                          : _buildEmptyList(l10n.getString('homeNoChats')),
                    )
                  else
                    // While searching, show every match (not just the
                    // preview limit) and hand each row its newest matching
                    // snippet, exactly like the Chats screen.
                    ...(hasChatsSearch ? sortedChats : sortedChats.take(_kHomePreviewLimit))
                        .map((chat) {
                          final hit = hasChatsSearch
                              ? newestHitsChats[chat.matchId]
                              : null;
                          return ChatListItem(
                            chat: chat,
                            showUnreadBorder: true,
                            searchQuery: hasChatsSearch
                                ? _chatsSearchQuery
                                : null,
                            searchSnippet: hit?.snippet,
                            searchMessageId: hit?.messageId,
                            // Per-row ⋮ menu: archive from Home too. No
                            // "Select" entry here — multi-select lives on
                            // the Chats tab, Home is a preview.
                            onRowMenuArchive: () =>
                                _archiveChatFromHome(chat),
                          );
                        }),
                ],
              );
            },
            loading: _buildLoadingIndicator,
            // The recovery banner at the top of the screen explains why this
            // section is empty and offers a retry.
            error: (e, s) => const SizedBox.shrink(),
          ),
          if (recentMatchesAsync.asData?.value.isEmpty == true &&
              recentChatsAsync.asData?.value.isEmpty == true &&
              isVisible &&
              backgroundMatchingEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Semantics(
                liveRegion: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.getString('homeAllCaughtUp'),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              return const AdSlot(placement: AdPlacement.homeInline);
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cancelSkeletonBudgetTimer();
    _matchesSearchController.dispose();
    _chatsSearchController.dispose();
    super.dispose();
  }
}

/// Helper to safely read connectivity provider value (used in build)
bool? connectivityProviderChecker(WidgetRef ref) {
  try {
    return ref.watch(connectivityProvider).value;
  } catch (_) {
    return true;
  }
}
