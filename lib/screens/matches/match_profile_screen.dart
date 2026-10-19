import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/zodiac.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/verified_badge.dart';
import 'package:matchme/widgets/new_user_badge.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';
import 'package:matchme/screens/matches/match_rating_screen.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/widgets/pinned_partner_chip.dart';
import 'package:matchme/widgets/photo_gallery_viewer.dart';
import 'package:matchme/widgets/profile_photo_thumbnail.dart';
import 'package:matchme/widgets/profile_completeness_summary.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/screens/location_share/location_share_map_screen.dart';
import 'package:matchme/screens/location_share/location_share_duration_dialog.dart';
import 'package:matchme/widgets/location_share_banner.dart';
import 'package:matchme/utils/match_score_utils.dart';
import 'package:matchme/utils/profile_completeness.dart';
import 'package:matchme/utils/shared_intent_utils.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/match_extension_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/widgets/match_location_mini_map.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/translation_service.dart';

final supabase = Supabase.instance.client;

String _normalizeKey(String s) {
  final trimmed = s.trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

bool _isBusinessIntentKey(String s) =>
    _normalizeKey(s) == 'business_networking';

bool _hasBusinessIntent(UserProfile p) =>
    p.activeModes.any((m) => _isBusinessIntentKey(m));

bool _hasSocialIntent(UserProfile p) => p.activeModes.any(
  (m) => m != '0' && m.isNotEmpty && !_isBusinessIntentKey(m),
);

/// MatchProfileScreen
/// Shows the matched user's profile for a single matched intent.
class MatchProfileScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final String matchedIntent;
  final String matchType;
  final String? eventId;
  final String? eventName;
  final String? eventLink;
  final DateTime? createdAt;
  // Rematch + location fields (optional for backward compat)
  final int matchOccurrence;
  final double? user1Latitude;
  final double? user1Longitude;
  final double? user2Latitude;
  final double? user2Longitude;
  final double? mapCenterLat;
  final double? mapCenterLng;
  final double? mapZoom;
  final List<MatchLocation> previousLocations;
  final List<MatchLocation> allMatchLocationsOverride;
  final bool isRetroactive;

  const MatchProfileScreen({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    required this.matchedIntent,
    this.matchType = 'proximity',
    this.eventId,
    this.eventName,
    this.eventLink,
    this.createdAt,
    this.matchOccurrence = 1,
    this.user1Latitude,
    this.user1Longitude,
    this.user2Latitude,
    this.user2Longitude,
    this.mapCenterLat,
    this.mapCenterLng,
    this.mapZoom,
    this.previousLocations = const [],
    this.allMatchLocationsOverride = const [],
    this.isRetroactive = false,
  });

  @override
  ConsumerState<MatchProfileScreen> createState() => _MatchProfileScreenState();
}

class _MatchProfileScreenState extends ConsumerState<MatchProfileScreen> {
  late final ScrollController _scrollController;
  RealtimeChannel? _chatSignalChannel;
  final _ratingService = MatchRatingService();
  Future<UserRatingSummary>? _otherRatingSummaryFuture;
  Future<List<RatingQuestion>>? _ratingQuestionsFuture;
  Future<bool>? _hasRatedThisMatchFuture;
  Future<bool>? _hasPendingRatingPromptFuture;
  MatchLocation? _directFetchedLocation;
  bool _directFetchDone = false;
  // Offline-first minimap snapshot loaded from local storage (Hive settings
  // box). Populated in initState so _collectAllLocations can fall back to it
  // when the constructor args and the matches cache are both empty offline.
  List<MatchLocation> _snapshotLocations = const [];

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    if (widget.matchId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(matchNotificationProvider.notifier)
            .markAsViewed(widget.matchId);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.matchId.isNotEmpty) {
        _subscribeToChatLocationSignals();
        unawaited(_checkExistingLocationShareSignal());
      }
    });

    Future.microtask(() {
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        ref
            .read(profileSyncProvider)
            .syncProfile(
              currentUserId,
              source: 'match-profile-init-current-user',
            );
      }
      if (widget.otherUserId.isNotEmpty) {
        ref
            .read(profileSyncProvider)
            .syncProfile(
              widget.otherUserId,
              source: 'match-profile-init-other-user',
            );
        // Fresh pinned flag on open (covers broadcasts missed while the list
        // was not visible); realtime keeps it live afterwards.
        try {
          ref.invalidate(pinnedPartnerProvider(widget.otherUserId));
        } catch (_) {}
      }
    });

    if (widget.otherUserId.isNotEmpty) {
      // Cache-first: displays instantly from memory/Hive, refreshes in bg.
      _otherRatingSummaryFuture = _ratingService.getUserRatingSummary(
        widget.otherUserId,
      );
      // When the background Supabase refresh lands with different data,
      // update this screen immediately (the service also updates memory+Hive
      // for the next startup; the provider path covers MatchBox stars).
      unawaited(
        _ratingService.refreshSummaryInBackground(widget.otherUserId).then((
          fresh,
        ) {
          if (!mounted || fresh == null) return;
          setState(() {
            _otherRatingSummaryFuture = Future.value(fresh);
          });
          try {
            // ignore: unused_result
            ref.invalidate(userRatingSummaryProvider(widget.otherUserId));
          } catch (_) {}
        }),
      );
      _ratingQuestionsFuture = _ratingService.getQuestions();
    }
    if (widget.matchId.isNotEmpty) {
      _hasRatedThisMatchFuture = _ratingService.hasUserRatedMatch(
        widget.matchId,
      );
      _hasPendingRatingPromptFuture = _ratingService.hasPendingRatingPrompt(
        widget.matchId,
      );
      // Direct fetch for coarse map as fallback when local cache hasn't synced yet
      // (fixes: DB row has map_center but recentMatchesProvider still empty)
      if (widget.mapCenterLat == null &&
          widget.allMatchLocationsOverride.isEmpty) {
        Future.microtask(() => _fetchDirectMapCenter());
      }
      // Load the persisted minimap snapshot so the map renders offline even
      // when the constructor args carry no location (e.g. chat entry point).
      Future.microtask(() => _loadMinimapSnapshot());
    }
  }

  /// Load the locally persisted minimap locations for this match (offline fallback).
  Future<void> _loadMinimapSnapshot() async {
    if (widget.matchId.isEmpty) return;
    try {
      final localDb = ref.read(localDbProvider);
      final raw = await localDb.getMatchMinimapSnapshot(widget.matchId);
      if (raw.isEmpty || !mounted) return;
      final parsed = raw
          .map((e) {
            try {
              return MatchLocation.fromJson(e);
            } catch (_) {
              return null;
            }
          })
          .whereType<MatchLocation>()
          .where((l) => l.hasDisplayableLocation)
          .toList();
      if (parsed.isNotEmpty && mounted) {
        setState(() => _snapshotLocations = parsed);
      }
    } catch (_) {}
  }

  /// Persist displayable minimap locations to local storage (fire-and-forget).
  /// Called whenever fresh locations are available so offline opens still show maps.
  Future<void> _persistMinimapSnapshot(List<MatchLocation> locations) async {
    if (widget.matchId.isEmpty || locations.isEmpty) return;
    try {
      final displayable = locations
          .where((l) => l.hasDisplayableLocation)
          .toList();
      if (displayable.isEmpty) return;
      final localDb = ref.read(localDbProvider);
      await localDb.saveMatchMinimapSnapshot(
        widget.matchId,
        displayable.map((l) => l.toJson()).toList(),
      );
    } catch (_) {}
  }

  Future<void> _fetchDirectMapCenter() async {
    if (_directFetchDone || widget.matchId.isEmpty) return;
    _directFetchDone = true;
    try {
      final row = await supabase
          .from('matches')
          .select(
            'map_center_lat, map_center_lng, map_zoom, match_occurrence, match_type, is_retroactive',
          )
          .eq('id', widget.matchId)
          .maybeSingle();
      if (row == null || !mounted) return;
      final lat = (row['map_center_lat'] as num?)?.toDouble();
      final lng = (row['map_center_lng'] as num?)?.toDouble();
      final zoom = (row['map_zoom'] as num?)?.toDouble();
      final occ =
          (row['match_occurrence'] as num?)?.toInt() ?? widget.matchOccurrence;
      if (lat != null && lng != null && mounted) {
        setState(() {
          _directFetchedLocation = MatchLocation(
            occurrence: occ,
            mapCenterLat: lat,
            mapCenterLng: lng,
            mapZoom: zoom ?? 12,
            matchId: widget.matchId,
            matchedIntent: widget.matchedIntent,
            createdAt: widget.createdAt,
          );
        });
      }
    } catch (_) {}
  }

  String _formatScore(double value, {int decimals = 1}) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _headerKeyForQuestion(RatingQuestion q) {
    switch (q.id) {
      case 'communication':
        return 'ratingHeaderCommunication';
      case 'reliability':
        return 'ratingHeaderReliability';
      case 'respect':
        return 'ratingHeaderRespect';
      case 'safety':
        return 'ratingHeaderSafety';
      case 'profile_accuracy':
        return 'ratingHeaderAccuracy';
      default:
        return q.translationKey;
    }
  }

  String _humanizeKey(String value) {
    return value
        .replaceAll('::', ' ')
        .replaceAll('_', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  /// Resolves the matched user's display name with an offline-first fallback chain:
  /// 1) Locally cached profile (Hive via userProfileProvider) — available offline.
  /// 2) The name passed via the constructor (resolved at navigation time).
  /// 3) A loading label while a sync may still deliver the profile (never
  ///    flash "Unknown" transiently during normal loads).
  /// 4) Localized "Unknown" — reachable only when the name is genuinely
  ///    unresolvable: no cached profile, no usable passed name, and no sync
  ///    in flight (e.g. profile never synced and device offline, wiped app
  ///    data, or a deleted user). All entry points now pass a resolved name,
  ///    so in practice this branch is a defensive last resort, consistent
  ///    with the match list and chat list placeholders.
  /// All branches go through [formatAsFirstNameLastInitial] which capitalizes
  /// first letters regardless of how the user typed the name.
  String _effectiveOtherUserName(
    UserProfile? cachedProfile,
    LocalizationState l10n, {
    required bool isLoading,
    required bool isOnline,
  }) {
    final cachedName =
        cachedProfile?.name
            .replaceAll(RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]'), '')
            .trim() ??
        '';
    if (cachedName.isNotEmpty) {
      return cachedName.formatAsFirstNameLastInitial();
    }
    String unknown;
    try {
      unknown = l10n.getString('generalUnknown');
      if (unknown.trim().isEmpty) unknown = 'Unknown';
    } catch (_) {
      unknown = 'Unknown';
    }
    String loading;
    try {
      loading = l10n.getString('generalLoading');
      if (loading.trim().isEmpty) loading = 'Loading...';
    } catch (_) {
      loading = 'Loading...';
    }
    final passed = widget.otherUserName.trim();
    final stripped = passed
        .replaceAll(RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]'), '')
        .trim();
    // A passed "Unknown"/"Loading" placeholder carries no information — treat
    // it as unusable so we fall through to loading/unknown handling instead
    // of reformatting and displaying the placeholder as if it were a name.
    final passedUsable =
        stripped.isNotEmpty &&
        stripped != unknown.trim() &&
        stripped.toLowerCase() != 'unknown user' &&
        stripped != loading.trim();
    if (passedUsable) {
      // Re-format to guarantee capitalization even if the caller passed a
      // stale or unformatted value.
      try {
        return stripped.formatAsFirstNameLastInitial();
      } catch (_) {
        return passed;
      }
    }
    // No name from any source yet: if a sync may still deliver the profile,
    // show loading rather than flashing "Unknown".
    if (isLoading || isOnline) return loading;
    return unknown;
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    if (!l10n.containsKey(key)) return null;
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key || val.endsWith('...')) return null;
      return val;
    } catch (_) {
      return null;
    }
  }

  String _localizedLifestyleValue(
    LocalizationState l10n,
    String category,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: category, context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final prefix =
        'lifestyle${category[0].toUpperCase()}${category.substring(1)}';
    final key = '$prefix$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedReligionValue(LocalizationState l10n, String value) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'religion', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final key = 'religion$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedEducationValue(LocalizationState l10n, String value) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'education', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value.trim()).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final direct = _tryGetString(l10n, value.trim());
    if (direct != null) return direct;
    return _humanizeKey(value);
  }

  String _localizedFamilyWantsChildrenValue(
    LocalizationState l10n,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((
                fieldKey: 'wants_children',
                context: 'profile',
              )),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final direct = _tryGetString(l10n, value);
    if (direct != null) return direct;
    return _humanizeKey(value);
  }

  String _formatHeight(LocalizationState l10n, int heightCm, String unit) {
    if (unit.trim().toLowerCase() != 'ft') {
      return '$heightCm ${l10n.getString('settingsHeightCm')}';
    }
    final totalInches = (heightCm / 2.54).round();
    final feet = totalInches ~/ 12;
    final inches = totalInches % 12;
    return l10n
        .getString('profileHeightFeetInches')
        .replaceAll('{feet}', feet.toString())
        .replaceAll('{inches}', inches.toString());
  }

  List<String> _orderedLanguageSkills(Iterable<String> skills) {
    const order = {'understand': 0, 'read': 1, 'speak': 2};
    final ordered = skills.toList();
    ordered.sort((a, b) {
      final aKey = a.trim().toLowerCase();
      final bKey = b.trim().toLowerCase();
      final aOrder = order[aKey] ?? order.length;
      final bOrder = order[bKey] ?? order.length;
      return aOrder == bOrder ? aKey.compareTo(bKey) : aOrder.compareTo(bOrder);
    });
    return ordered;
  }

  String _normalizeGenderDisplayKey(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return v;
    final lower = v.toLowerCase();
    if (lower.startsWith('gender_')) return lower;
    // Common storage shapes: "male" / "female" / "non_binary".
    if (lower == 'male' || lower == 'female' || lower == 'non_binary') {
      return 'gender_$lower';
    }
    return v;
  }

  String _resolveInterestDisplayText(
    LocalizationState l10n,
    String interestKey,
    Map<String, String> interestDisplayMap,
  ) {
    // Try mapped key first (normal case when providers are loaded)
    final mappedKey = interestDisplayMap[interestKey]?.trim() ?? '';
    if (mappedKey.isNotEmpty) {
      final localized = _tryGetString(l10n, mappedKey);
      if (localized != null) return localized;
      return _humanizeKey(mappedKey);
    }

    // Handle race condition: interestDisplayMap may be empty during initialization.
    // Try common prefixes before falling back to humanization.
    if (!interestKey.contains('.') && !interestKey.contains('::')) {
      const prefixes = ['interest.', 'intent.activity.', 'intent.'];
      for (final prefix in prefixes) {
        final attempt = _tryGetString(l10n, '$prefix$interestKey');
        if (attempt != null) return attempt;
      }
    }

    // Try bare key directly
    final direct = _tryGetString(l10n, interestKey);
    if (direct != null) return direct;

    // Final fallback to humanized display
    return _humanizeKey(interestKey);
  }

  @override
  void dispose() {
    _chatSignalChannel?.unsubscribe();
    _chatSignalChannel = null;
    _scrollController.dispose();
    super.dispose();
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

  Future<void> _handleLocationShare(BuildContext context, WidgetRef ref) async {
    final l10n = ref.read(localizationProvider);
    final currentSession = ref.read(locationShareProvider);

    if (currentSession != null && currentSession.matchId == widget.matchId) {
      final iAmSharer = currentSession.myStatus == ShareStatus.sharing;
      final otherIsSharing = currentSession.otherStatus == ShareStatus.sharing;

      if (iAmSharer && !otherIsSharing) {
        await _showShareOptionsSheet(context, ref, currentSession);
        return;
      }
      if (otherIsSharing) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const LocationShareMapScreen(),
          ),
        );
        return;
      }
      // Stale session — fall through to re-check
    }

    final shouldSkip = shouldSkipSupabaseCalls();
    if (shouldSkip) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('locationShareOffline'))),
      );
      return;
    }

    // Check if other user is already sharing with us
    final hasExistingSignal = await ref
        .read(locationShareProvider.notifier)
        .hasActiveShareSignal(widget.matchId);

    if (hasExistingSignal) {
      // Receiver joining: view map only (do not start sharing back immediately)
      // Read the same realtime source the display watches (local-DB stream).
      final otherProfileAsync = ref.read(
        otherUserProfileProvider(widget.otherUserId),
      );
      final otherPhoto =
          otherProfileAsync.asData?.value?.photos.isNotEmpty == true
          ? otherProfileAsync.asData!.value!.photos[0]
          : null;
      ref
          .read(locationShareProvider.notifier)
          .viewExistingShare(
            matchId: widget.matchId,
            otherUserId: widget.otherUserId,
            otherUserName: widget.otherUserName,
            otherUserPhoto: otherPhoto,
          );

      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const LocationShareMapScreen(),
          ),
        );
      }
      return;
    }

    // Check location permissions before starting location share
    final locationService = ref.read(locationServiceProvider);
    final hasPermission = await locationService.handleLocationPermission();
    if (!hasPermission) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('locationPermissionDenied')),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // No session: pick duration and start sharing, then stay on profile
    final duration = await showDialog<Duration>(
      context: context,
      builder: (context) =>
          LocationShareDurationDialog(otherUserName: widget.otherUserName),
    );

    if (duration == null || !context.mounted) return;
    final Duration? effectiveDuration = duration == Duration.zero
        ? null
        : duration;

    // Same realtime source the display watches (local-DB stream).
    final otherProfileAsync = ref.read(otherUserProfileProvider(widget.otherUserId));
    final otherPhoto =
        otherProfileAsync.asData?.value?.photos.isNotEmpty == true
        ? otherProfileAsync.asData!.value!.photos[0]
        : null;
    ref
        .read(locationShareProvider.notifier)
        .startSharing(
          matchId: widget.matchId,
          otherUserId: widget.otherUserId,
          otherUserName: widget.otherUserName,
          otherUserPhoto: otherPhoto,
          duration: effectiveDuration,
        );

    // Stay on profile — the chat banner will reflect the sharing status.
    // We do NOT navigate to the map: seeing only your own dot is meaningless.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('locationShareStarted')),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildQuickActions(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
  ) {
    final enabled = widget.matchId.isNotEmpty && widget.otherUserId.isNotEmpty;
    final effectiveName = widget.otherUserName.trim().isNotEmpty
        ? widget.otherUserName
        : l10n.getString('generalUnknown');
    final messageButton = FilledButton.icon(
      onPressed: enabled
          ? () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    matchId: widget.matchId,
                    otherUserName: effectiveName,
                    otherUserId: widget.otherUserId,
                  ),
                ),
              );
            }
          : null,
      icon: const Icon(Icons.chat_bubble_outline),
      label: Text(l10n.getString('chatButton')),
    );
    // Reflect the live location-share state on the button itself: mutual and
    // incoming shares become filled "enter the map" buttons; an outgoing-only
    // share keeps the outlined style but shows that sharing is in progress.
    final session = ref.watch(locationShareProvider);
    final activeSession =
        session != null && session.matchId == widget.matchId ? session : null;
    final iAmSharing = activeSession?.myStatus == ShareStatus.sharing;
    final otherIsSharing = activeSession?.otherStatus == ShareStatus.sharing;
    final isMutual = iAmSharing && otherIsSharing;

    final Widget shareButton;
    if (isMutual) {
      shareButton = FilledButton.icon(
        onPressed: enabled ? () => _handleLocationShare(context, ref) : null,
        icon: const Icon(Icons.people),
        label: Text(l10n.getString('locationShareButtonMutualActive')),
      );
    } else if (otherIsSharing) {
      shareButton = FilledButton.icon(
        onPressed: enabled ? () => _handleLocationShare(context, ref) : null,
        icon: const Icon(Icons.location_on),
        label: Text(l10n.getString('locationShareView')),
      );
    } else if (iAmSharing) {
      shareButton = OutlinedButton.icon(
        onPressed: enabled ? () => _handleLocationShare(context, ref) : null,
        icon: const Icon(Icons.share_location),
        label: Text(l10n.getString('locationShareButtonSharing')),
      );
    } else {
      shareButton = OutlinedButton.icon(
        onPressed: enabled ? () => _handleLocationShare(context, ref) : null,
        icon: const Icon(Icons.share_location),
        label: Text(l10n.getString('locationShareStart')),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 380;
        return SafeArea(
          top: false,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        messageButton,
                        const SizedBox(height: 8),
                        shareButton,
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: messageButton),
                        const SizedBox(width: 12),
                        Expanded(child: shareButton),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  /// Options bottom sheet shown to the sharer (User A) when they tap location
  /// while a session is already active.
  Future<void> _showShareOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    dynamic session,
  ) async {
    final l10n = ref.read(localizationProvider);
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.share_location,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.blue.shade300
                            : Colors.blue.shade700,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('locationShareBannerYouAreSharing'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            l10n
                                .getString('locationShareBannerSharingWith')
                                .replaceAll('{name}', widget.otherUserName),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: AppThemeTokens.accentSurface(
                    Colors.blue.shade700,
                    Theme.of(context).brightness,
                  ),
                  leading: Icon(
                    Icons.timer_outlined,
                    color: AppThemeTokens.accentInk(
                      Colors.blue.shade700,
                      Theme.of(context).brightness,
                    ),
                  ),
                  title: Text(
                    l10n.getString('locationShareChangeDuration'),
                    style: TextStyle(
                      color: AppThemeTokens.accentInk(
                        Colors.blue.shade800,
                        Theme.of(context).brightness,
                      ),
                    ),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    if (!context.mounted) return;
                    final newDuration = await showDialog<Duration?>(
                      context: context,
                      builder: (ctx) => LocationShareDurationDialog(
                        otherUserName: widget.otherUserName,
                        isChangingDuration: true,
                      ),
                    );
                    if (newDuration == null || !context.mounted) return;
                    final Duration? effectiveDuration =
                        newDuration == Duration.zero ? null : newDuration;
                    await ref
                        .read(locationShareProvider.notifier)
                        .updateDuration(effectiveDuration);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            l10n.getString('locationShareDurationUpdated'),
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 10),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.12),
                  leading: Icon(
                    Icons.stop_circle_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    l10n.getString('locationShareStop'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await ref
                        .read(locationShareProvider.notifier)
                        .stopSharing();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleChangeDuration(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = ref.read(localizationProvider);
    final newDuration = await showDialog<Duration>(
      context: context,
      builder: (context) => LocationShareDurationDialog(
        otherUserName: widget.otherUserName,
        isChangingDuration: true,
      ),
    );
    if (newDuration == null || !context.mounted) return;
    final Duration? effectiveDuration = newDuration == Duration.zero
        ? null
        : newDuration;

    await ref
        .read(locationShareProvider.notifier)
        .updateDuration(effectiveDuration);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('locationShareDurationUpdated')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _subscribeToChatLocationSignals() {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null || widget.matchId.isEmpty) return;

    _chatSignalChannel?.unsubscribe();

    _chatSignalChannel = supabase
        .channel('profile_ls:${widget.matchId}:$currentUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'location_share_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: widget.matchId,
          ),
          callback: (payload) => _onLocationShareSignalReceived(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'location_share_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: widget.matchId,
          ),
          callback: (payload) => _onLocationShareSignalDeleted(payload),
        )
        .subscribe();
  }

  void _onLocationShareSignalReceived(PostgresChangePayload payload) {
    if (!mounted) return;
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final newRecord = payload.newRecord;
    final sharerId = newRecord['sharer_id'] as String?;
    final expiresAtStr = newRecord['expires_at'] as String?;

    if (sharerId == null || sharerId == currentUserId) return;
    if (sharerId != widget.otherUserId) return;

    if (expiresAtStr != null) {
      final expiresAt = DateTime.parse(expiresAtStr).toUtc();
      if (DateTime.now().toUtc().isAfter(expiresAt)) return;
    }

    final currentSession = ref.read(locationShareProvider);
    if (currentSession != null) {
      // Session exists — the sharer updated their duration
      final DateTime? expiresAt = expiresAtStr != null
          ? DateTime.parse(expiresAtStr)
          : null;
      ref.read(locationShareProvider.notifier).updateOtherExpiresAt(expiresAt);
      return;
    }

    final DateTime? expiresAt = expiresAtStr != null
        ? DateTime.parse(expiresAtStr)
        : null;
    ref
        .read(locationShareProvider.notifier)
        .viewExistingShare(
          matchId: widget.matchId,
          otherUserId: widget.otherUserId,
          otherUserName: widget.otherUserName,
          expiresAt: expiresAt,
        );
  }

  void _onLocationShareSignalDeleted(PostgresChangePayload payload) {
    // Note: oldRecord only contains the primary key (id).
    // The subscription is already filtered by match_id, so we just
    // check if the session exists to update the receiver's state.
    if (!mounted) return;
    final currentSession = ref.read(locationShareProvider);
    if (currentSession == null) return;
    if (currentSession.matchId != widget.matchId) return;

    ref.read(locationShareProvider.notifier).markOtherStopped();
  }

  Future<void> _checkExistingLocationShareSignal() async {
    if (!mounted) return;
    final currentSession = ref.read(locationShareProvider);
    if (currentSession != null) return;

    try {
      final hasSignal = await ref
          .read(locationShareProvider.notifier)
          .hasActiveShareSignal(widget.matchId);
      if (!hasSignal || !mounted) return;

      // Same realtime source the display watches (local-DB stream).
      final otherProfileAsync = ref.read(
        otherUserProfileProvider(widget.otherUserId),
      );
      final otherPhoto =
          otherProfileAsync.asData?.value?.photos.isNotEmpty == true
          ? otherProfileAsync.asData!.value!.photos[0]
          : null;
      ref
          .read(locationShareProvider.notifier)
          .viewExistingShare(
            matchId: widget.matchId,
            otherUserId: widget.otherUserId,
            otherUserName: widget.otherUserName,
            otherUserPhoto: otherPhoto,
          );
    } catch (_) {}
  }

  Future<void> _showUnmatchDialog(
    BuildContext context,
    LocalizationState l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.getString('unmatch')),
        content: Text(l10n.getString('unmatchConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: Text(l10n.getString('unmatch')),
          ),
        ],
      ),
    );

    if (confirmed == true && widget.matchId.isNotEmpty) {
      try {
        // Call the RPC function to unmatch properly (uses auth.uid() internally)
        await supabase.rpc(
          'unmatch_from_system_match',
          params: {'p_match_id': widget.matchId},
        );

        // Show success message
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.getString('unmatchSuccess')),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }

        // Invalidate providers to refresh UI
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null && currentUserId.isNotEmpty) {
          ref.invalidate(recentMatchesProvider(currentUserId));
          ref.invalidate(recentChatsProvider(currentUserId));
          ref.invalidate(userChatIdsProvider(currentUserId));
        }

        // Navigate back to matches screen
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          ref.read(navigationIndexProvider.notifier).setIndex(1);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.getString('generalError')),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;

    // Keep rating + pinned-partner realtime alive while viewing a profile.
    // Pinned pin/unpin broadcasts invalidate pinnedPartnerProvider(otherUserId)
    // so the home-base chip below updates immediately without leaving the
    // screen (same guarantee as the match row).
    ref.watch(pinnedPartnerRealtimeProvider);
    ref.listen<int>(pinnedPartnerRealtimeProvider, (prev, next) {
      if (!mounted || prev == next) return;
      if (widget.otherUserId.isEmpty) return;
      final lastChanged = ref
          .read(pinnedPartnerRealtimeProvider.notifier)
          .lastUpdatedUserId;
      if (lastChanged != null && lastChanged != widget.otherUserId) return;
      // Provider invalidation already happened in the notifier; a rebuild
      // picks it up. This listen only ensures setState-driven sections that
      // don't watch the provider still refresh.
      if (mounted) setState(() {});
    });
    // Keep rating realtime alive while viewing a profile; when this
    // profile's ratee gets a new rating, refresh the summary future so
    // stars update without leaving the screen. Bulk refreshes (poll/resume
    // set lastUpdatedRateeId to null) refresh unconditionally.
    ref.watch(ratingSummaryRealtimeProvider);
    ref.listen<int>(ratingSummaryRealtimeProvider, (prev, next) {
      if (!mounted || prev == next) return;
      if (widget.otherUserId.isEmpty) return;
      final lastRatee = ref
          .read(ratingSummaryRealtimeProvider.notifier)
          .lastUpdatedRateeId;
      if (lastRatee != null && lastRatee != widget.otherUserId) return;
      setState(() {
        _otherRatingSummaryFuture = _ratingService.getUserRatingSummary(
          widget.otherUserId,
        );
      });
      try {
        ref.invalidate(userRatingSummaryProvider(widget.otherUserId));
      } catch (_) {}
    });

    final currentUserId = supabase.auth.currentUser?.id ?? '';

    // aggregated local profiles (fast, from local DB)
    final otherProfileAsync = ref.watch(
      otherUserProfileProvider(widget.otherUserId),
    );
    final currentProfileAsync = ref.watch(userProfileProvider(currentUserId));

    // Get verification status for the badge
    final isOtherUserVerified =
        otherProfileAsync.asData?.value?.isVerified ?? false;

    // Check if other user is new (under 1 week)
    final otherProfileCreatedAt = otherProfileAsync.asData?.value?.createdAt;
    final otherProfileGender = otherProfileAsync.asData?.value?.gender;
    bool isOtherUserNew = false;
    if (otherProfileCreatedAt != null) {
      final now = DateTime.now();
      final difference = now.difference(otherProfileCreatedAt);
      isOtherUserNew = difference.inDays < 7;
    }

    // fallback remote intent-specific provider (fetches profile_data for the intent)
    final specificProvider = specificProfileProvider({
      'userId': widget.otherUserId,
      'intentType': widget.matchedIntent,
    });

    // This watch MUST be at the top level of the build method to avoid provider creation inside branches.
    final specificAsync = ref.watch(specificProvider);

    // Option providers for rendering labels
    final interestDisplayMap = ref.watch(interestDisplayMapProvider);
    final languageOptionsAsync = ref.watch(languageOptionsProvider);

    // Offline-first display name: cached profile -> constructor arg -> Unknown.
    final effectiveOtherUserName = _effectiveOtherUserName(
      otherProfileAsync.asData?.value,
      l10n,
      isLoading: otherProfileAsync.isLoading,
      isOnline: isOnline,
    );

    // Two-line AppBar title: the badges + offline chip used to consume the
    // whole title width and squeeze the name to zero (it rendered as a tiny
    // dash). The name now gets the full title width on line 1 and the badges
    // sit on line 2 — nothing truncates, online or offline, no ellipsis.
    final hasTitleBadges = isOtherUserVerified || isOtherUserNew;

    return Scaffold(
      appBar: AppBar(
        // Taller only when the badges line is present; default height otherwise.
        toolbarHeight: hasTitleBadges ? 78 : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // No ellipsis allowed: the name must always show in full.
            // FittedBox with scaleDown shrinks the font only when needed so
            // the complete name stays visible on its own full-width line.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                effectiveOtherUserName,
                maxLines: 2,
                softWrap: true,
                textDirection:
                    RegExp(r'[a-zA-Z]').hasMatch(effectiveOtherUserName)
                    ? ui.TextDirection.ltr
                    : (effectiveOtherUserName.isRtl()
                          ? ui.TextDirection.rtl
                          : ui.TextDirection.ltr),
              ),
            ),
            if (hasTitleBadges) ...[
              const SizedBox(height: 4),
              // Badges get their own full-width line; scaleDown keeps both
              // chips fully visible (never truncated) on narrow screens.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isOtherUserVerified)
                      VerifiedBadge(
                        size: 18,
                        showText: true,
                        text: (() {
                          final normalizedGender = otherProfileGender
                              ?.trim()
                              .toLowerCase();
                          if (normalizedGender == 'female') {
                            final translated = l10n.getString(
                              'profileVerifiedBadgeFemale',
                            );
                            return translated != 'profileVerifiedBadgeFemale' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'Verified';
                          } else if (normalizedGender == 'non_binary' ||
                              normalizedGender == 'nonbinary') {
                            final translated = l10n.getString(
                              'profileVerifiedBadgeNeutral',
                            );
                            return translated !=
                                        'profileVerifiedBadgeNeutral' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'Verified';
                          } else {
                            final translated = l10n.getString(
                              'profileVerifiedBadge',
                            );
                            return translated != 'profileVerifiedBadge' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'Verified';
                          }
                        })(),
                      ),
                    if (isOtherUserVerified && isOtherUserNew)
                      const SizedBox(width: 8),
                    if (isOtherUserNew)
                      // Use gender-specific translation key based on other user's gender
                      NewUserBadge(
                        size: 18,
                        showText: true,
                        text: (() {
                          final normalizedGender = otherProfileGender
                              ?.trim()
                              .toLowerCase();
                          if (normalizedGender == 'female') {
                            final translated = l10n.getString(
                              'profileNewUserBadgeFemale',
                            );
                            return translated != 'profileNewUserBadgeFemale' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'New here!';
                          } else if (normalizedGender == 'non_binary' ||
                              normalizedGender == 'nonbinary') {
                            final translated = l10n.getString(
                              'profileNewUserBadgeNeutral',
                            );
                            return translated != 'profileNewUserBadgeNeutral' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'New here!';
                          } else {
                            final translated = l10n.getString(
                              'profileNewUserBadge',
                            );
                            return translated != 'profileNewUserBadge' &&
                                    translated.isNotEmpty
                                ? translated
                                : 'New here!';
                          }
                        })(),
                        gender: otherProfileGender,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (!isOnline)
            Container(
              margin: const EdgeInsets.only(right: 8.0),
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.wifi_off,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l10n.getString('generalOffline'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: Center(
        child: Builder(
          builder: (ctx) {
            final intentProfile = specificAsync.asData?.value;

            // If both aggregated profiles are present we can compute intersections locally and render immediately.
            final UserProfile? otherProfile = otherProfileAsync.asData?.value;
            final UserProfile? currentProfile =
                currentProfileAsync.asData?.value;

            if (otherProfile != null && currentProfile != null) {
              // Gate by active intents: stashed selections for inactive intents
              // are preserved for quick re-activation but must stay hidden.
              final otherActive = otherProfile.activeModes
                  .map(_normalizeKey)
                  .toSet();
              final currentActive = currentProfile.activeModes
                  .map(_normalizeKey)
                  .toSet();
              final showBusiness =
                  _hasBusinessIntent(otherProfile) &&
                  _hasBusinessIntent(currentProfile);
              final showPersonal =
                  _hasSocialIntent(otherProfile) &&
                  _hasSocialIntent(currentProfile);
              // Compute ALL shared data between the two users (not just for the matched intent)
              final Map<String, List<String>> allSharedSubIntents = {};

              for (final intentKey in otherProfile.subIntents.keys) {
                final normIntent = _normalizeKey(intentKey);
                if (!otherActive.contains(normIntent) ||
                    !currentActive.contains(normIntent)) {
                  continue;
                }
                if (currentProfile.subIntents.containsKey(intentKey)) {
                  final otherSubs = otherProfile.subIntents[intentKey] ?? [];
                  final currentSubs =
                      currentProfile.subIntents[intentKey] ?? [];
                  final intersected = _intersectLists(otherSubs, currentSubs);
                  if (intersected.isNotEmpty) {
                    allSharedSubIntents[intentKey] = intersected;
                  }
                }
              }

              // Compute ALL shared interests between the two users
              final Map<String, List<String>> allSharedInterests = {};

              if (showPersonal) {
                for (final entry in otherProfile.personalInterests.entries) {
                  final cat = entry.key;
                  final otherList = entry.value;
                  final currentList =
                      currentProfile.personalInterests[cat] ?? [];
                  final intersected = _intersectLists(otherList, currentList);
                  final bothHaveCategory = currentProfile.personalInterests
                      .containsKey(cat);
                  if (intersected.isNotEmpty || bothHaveCategory) {
                    allSharedInterests[cat] = intersected;
                  }
                }
              }

              if (showBusiness) {
                for (final entry in otherProfile.businessInterests.entries) {
                  final cat = entry.key;
                  final otherList = entry.value;
                  final currentList =
                      currentProfile.businessInterests[cat] ?? [];
                  final intersected = _intersectLists(otherList, currentList);
                  final bothHaveCategory = currentProfile.businessInterests
                      .containsKey(cat);
                  if (intersected.isNotEmpty || bothHaveCategory) {
                    allSharedInterests['business_networking::$cat'] =
                        intersected;
                  }
                }
              }

              // derive shared languages and skills
              final Map<String, List<String>> sharedLanguages = {};
              for (final langEntry in otherProfile.languagesKnown.entries) {
                final lang = langEntry.key;
                final otherSkills = langEntry.value
                    .map((s) => s.toLowerCase())
                    .toList();
                final currentSkills =
                    currentProfile.languagesKnown[lang]
                        ?.map((s) => s.toLowerCase())
                        .toList() ??
                    [];
                final skillsIntersect = _intersectLists(
                  otherSkills,
                  currentSkills,
                );
                if (skillsIntersect.isNotEmpty) {
                  sharedLanguages[lang] = skillsIntersect;
                } else {
                  // include language even if no shared skills? Show only languages in common:
                  if (currentProfile.languagesKnown.containsKey(lang)) {
                    // no shared skills but both have the language; include without skills
                    sharedLanguages[lang] = [];
                  }
                }
              }

              // Realtime: prefer the aggregated (local-DB-watched) bio so the
              // other user's edits and realtime syncs reflect instantly. The
              // one-shot remote intent fetch (specificAsync) is fallback only.
              final bio =
                  otherProfile.bio ??
                  intentProfile?.bio ??
                  l10n.getString('matchProfileNoBio');

              // Build an IntentProfileData-like object with ALL shared data
              final IntentProfileData derived = IntentProfileData(
                bio: bio,
                subIntents: allSharedSubIntents.values
                    .expand((list) => list)
                    .toList(),
                interests: allSharedInterests,
              );

              // Render UI (pass ref so helper can read providers)
              return _buildProfileUI(
                context,
                ref,
                l10n,
                derived,
                interestDisplayMap,
                languageOptionsAsync,
                sharedLanguages,
                isOnline,
                otherProfile,
                currentProfileAsync.asData?.value,
                _scrollController,
                effectiveOtherUserName,
              );
            }

            // Else: attempt using specificProvider (remote intent-specific row) + currentProfile
            if (currentProfileAsync.isLoading) {
              // Wait for current user's profile: it's needed to compute intersections for "matched only"
              // but avoid blocking forever: also trigger a sync
              Future.microtask(() {
                if (currentUserId.isNotEmpty) {
                  ref
                      .read(profileSyncProvider)
                      .syncProfile(
                        currentUserId,
                        source: 'match-profile-current-user-loading',
                      );
                }
              });
              return const CircularProgressIndicator();
            }

            // If current profile failed or is not present, fall back to showing other user's available data
            final UserProfile? currentProfileAvailable =
                currentProfileAsync.asData?.value;

            return specificAsync.when(
              data: (intentProfile) {
                final IntentProfileData otherIntentData =
                    intentProfile ?? IntentProfileData.fromJson(null);

                // If current profile is present, compute intersections using current profile and otherIntentData
                Map<String, List<String>> matchedInterests = {};
                List<String> matchedSubIntents = [];
                Map<String, List<String>> sharedLanguages = {};

                if (currentProfileAvailable != null) {
                  // Get the other user's full profile to compute ALL shared data
                  final otherProfileAvailable = otherProfileAsync.asData?.value;

                  if (otherProfileAvailable != null) {
                    final otherActiveAv = otherProfileAvailable.activeModes
                        .map(_normalizeKey)
                        .toSet();
                    final currentActiveAv = currentProfileAvailable.activeModes
                        .map(_normalizeKey)
                        .toSet();
                    final showBusinessAv =
                        _hasBusinessIntent(otherProfileAvailable) &&
                        _hasBusinessIntent(currentProfileAvailable);
                    final showPersonalAv =
                        _hasSocialIntent(otherProfileAvailable) &&
                        _hasSocialIntent(currentProfileAvailable);
                    // Compute ALL shared data between the two users (not just for the matched intent)
                    final Map<String, List<String>> allSharedSubIntents = {};
                    for (final intentKey
                        in otherProfileAvailable.subIntents.keys) {
                      final normAv = _normalizeKey(intentKey);
                      if (!otherActiveAv.contains(normAv) ||
                          !currentActiveAv.contains(normAv)) {
                        continue;
                      }
                      if (currentProfileAvailable.subIntents.containsKey(
                        intentKey,
                      )) {
                        final otherSubs =
                            otherProfileAvailable.subIntents[intentKey] ?? [];
                        final currentSubs =
                            currentProfileAvailable.subIntents[intentKey] ?? [];
                        final intersected = _intersectLists(
                          otherSubs,
                          currentSubs,
                        );
                        if (intersected.isNotEmpty) {
                          allSharedSubIntents[intentKey] = intersected;
                        }
                      }
                    }

                    // Compute ALL shared interests between the two users
                    final Map<String, List<String>> allSharedInterests = {};

                    if (showPersonalAv) {
                      for (final entry
                          in otherProfileAvailable.personalInterests.entries) {
                        final cat = entry.key;
                        final otherList = entry.value;
                        final currentList =
                            currentProfileAvailable.personalInterests[cat] ??
                            [];
                        final intersected = _intersectLists(
                          otherList,
                          currentList,
                        );
                        final bothHaveCategory = currentProfileAvailable
                            .personalInterests
                            .containsKey(cat);
                        if (intersected.isNotEmpty || bothHaveCategory) {
                          allSharedInterests[cat] = intersected;
                        }
                      }
                    }

                    if (showBusinessAv) {
                      for (final entry
                          in otherProfileAvailable.businessInterests.entries) {
                        final cat = entry.key;
                        final otherList = entry.value;
                        final currentList =
                            currentProfileAvailable.businessInterests[cat] ??
                            [];
                        final intersected = _intersectLists(
                          otherList,
                          currentList,
                        );
                        final bothHaveCategory = currentProfileAvailable
                            .businessInterests
                            .containsKey(cat);
                        if (intersected.isNotEmpty || bothHaveCategory) {
                          allSharedInterests['business_networking::$cat'] =
                              intersected;
                        }
                      }
                    }

                    matchedSubIntents = allSharedSubIntents.values
                        .expand((list) => list)
                        .toList();
                    matchedInterests = allSharedInterests;
                  } else {
                    // Fallback to intent-specific data if we can't get the full profile
                    matchedSubIntents = otherIntentData.subIntents;
                    matchedInterests = otherIntentData.interests;
                  }

                  // languages: shared languages from profiles (use aggregated otherProfile if available)
                  final UserProfile? otherAgg = otherProfileAsync.asData?.value;
                  if (otherAgg != null) {
                    for (final langEntry in otherAgg.languagesKnown.entries) {
                      final lang = langEntry.key;
                      final otherSkills = langEntry.value
                          .map((s) => s.toLowerCase())
                          .toList();
                      final currentSkills =
                          currentProfileAvailable.languagesKnown[lang]
                              ?.map((s) => s.toLowerCase())
                              .toList() ??
                          [];
                      final skillsIntersect = _intersectLists(
                        otherSkills,
                        currentSkills,
                      );
                      if (skillsIntersect.isNotEmpty) {
                        sharedLanguages[lang] = skillsIntersect;
                      } else if (currentProfileAvailable.languagesKnown
                          .containsKey(lang)) {
                        sharedLanguages[lang] = [];
                      }
                    }
                  }
                } else {
                  matchedSubIntents = const [];
                  matchedInterests = const {};
                }

                // Render UI
                return _buildProfileUI(
                  context,
                  ref,
                  l10n,
                  IntentProfileData(
                    bio: otherIntentData.bio,
                    subIntents: matchedSubIntents,
                    interests: matchedInterests,
                  ),
                  interestDisplayMap,
                  languageOptionsAsync,
                  sharedLanguages,
                  isOnline,
                  // Pass the aggregate profile when available (may be null on
                  // first open): _buildProfileUI needs owner gender for
                  // gender-aware bio/occupation translation. Passing null
                  // drops the speaker gender, DeepL defaults to masculine,
                  // and the result is cached — female speakers mistranslated.
                  otherProfileAsync.asData?.value,
                  currentProfileAsync.asData?.value,
                  _scrollController,
                  effectiveOtherUserName,
                );
              },
              loading: () {
                // kick off a background sync to try populate local aggregated profiles
                Future.microtask(() {
                  if (currentUserId.isNotEmpty) {
                    ref
                        .read(profileSyncProvider)
                        .syncProfile(
                          currentUserId,
                          source: 'match-profile-current-user-loading',
                        );
                  }
                  ref
                      .read(profileSyncProvider)
                      .syncProfile(
                        widget.otherUserId,
                        source: 'match-profile-other-user-loading',
                      );
                });
                return const CircularProgressIndicator();
              },
              error: (err, stack) {
                return _buildErrorUI(
                  context,
                  ref,
                  err.toString(),
                  specificProvider,
                );
              },
            );
          },
        ),
      ),
      bottomNavigationBar: _buildQuickActions(context, ref, l10n),
    );
  }

  // Open a full-screen preview of the profile photos supporting swiping and gesture navigation
  void _openPhotoPreview(
    BuildContext context,
    int initialIndex,
    List<String> photos,
    LocalizationState l10n,
  ) {
    showDialog(
      context: context,
      builder: (_) => PhotoGalleryViewer(
        photos: photos,
        initialIndex: initialIndex,
        l10n: l10n,
      ),
    );
  }

  // Helper to open Event Matches screen for an eventId (falls back to link if not available)
  void _openEventMatches(
    BuildContext context, {
    String? eventId,
    String? eventName,
    String? eventLink,
  }) async {
    // If we have a valid event id, try to fetch the event and navigate to AttendeesScreen
    if (eventId != null && eventId.isNotEmpty) {
      try {
        final resp = await supabase
            .from('events')
            .select('id,event_name,event_venue,start_time,end_time,event_link')
            .eq('id', eventId)
            .maybeSingle();
        if (resp != null) {
          final event = EventModel.fromJson(resp);
          if (context.mounted) {
            ref.read(pendingEventTabRouteProvider.notifier).navigateTo(event);
            ref.read(navigationIndexProvider.notifier).setIndex(3);
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
          return;
        }
      } catch (e) {
        // ignore and fall back
      }
    }

    // Fall back to opening the link if available
    if (eventLink != null && eventLink.isNotEmpty) {
      final uri = Uri.parse(eventLink);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }

    // Nothing to open - show a message
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            eventName ??
                ref
                    .read(localizationProvider)
                    .getString('eventDetailsNotAvailable'),
          ),
        ),
      );
    }
  }

  // Intersection helper preserving order
  List<String> _intersectLists(List<String> a, List<String> b) {
    final setB = b.toSet();
    final seen = <String>{};
    final out = <String>[];
    for (final item in a) {
      if (setB.contains(item) && !seen.contains(item)) {
        seen.add(item);
        out.add(item);
      }
    }
    return out;
  }

  // Public helper used by tests and other modules
  List<String> intersectLists(List<String> a, List<String> b) =>
      _intersectLists(a, b);

  // Get intersection of sub-intents for a given intent key
  List<String> intersectSubIntentsForIntent(
    UserProfile current,
    IntentProfileData otherIntent,
    String intent,
  ) {
    final curSubs = current.subIntents[intent] ?? [];
    final otherSubs = otherIntent.subIntents;
    return _intersectLists(curSubs, otherSubs);
  }

  // Get intersection of interests for a given intent. The otherIntent keys are treated as base categories.
  // We consider matches against both the base category (e.g., 'outdoor') and intent-prefixed keys
  // present in the current user's interests (e.g., 'friendship::outdoor'). The resulting map's keys
  // are the base category names from otherIntent.
  Map<String, List<String>> intersectInterestsForIntent(
    UserProfile current,
    IntentProfileData otherIntent,
    String intent,
  ) {
    final out = <String, List<String>>{};
    final isBusiness = _normalizeKey(intent) == 'business_networking';
    final primaryBucket = isBusiness
        ? current.businessInterests
        : current.personalInterests;
    final fallbackBucket = isBusiness
        ? current.personalInterests
        : current.businessInterests;

    for (final entry in otherIntent.interests.entries) {
      final baseCat = entry.key;
      final otherVals = entry.value;

      // Check primary bucket first, then fallback for backward compatibility
      List<String> curVals = primaryBucket[baseCat] ?? [];
      if (curVals.isEmpty) {
        curVals = fallbackBucket[baseCat] ?? [];
      }
      if (curVals.isEmpty) {
        curVals = primaryBucket['$intent::$baseCat'] ?? [];
      }
      if (curVals.isEmpty) {
        curVals = fallbackBucket['$intent::$baseCat'] ?? [];
      }

      final inters = _intersectLists(otherVals, curVals);
      final bothHaveCategory =
          primaryBucket.containsKey(baseCat) ||
          fallbackBucket.containsKey(baseCat) ||
          primaryBucket.containsKey('$intent::$baseCat') ||
          fallbackBucket.containsKey('$intent::$baseCat');
      if (inters.isNotEmpty || bothHaveCategory) out[baseCat] = inters;
    }
    return out;
  }

  Widget _buildErrorUI(
    BuildContext context,
    WidgetRef ref,
    String error,
    dynamic provider,
  ) {
    final l10n = ref.read(localizationProvider);
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${l10n.getString('generalErrorLoadingProfile')}\n\n$error',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => ref.invalidate(provider),
            child: Text(l10n.getString('generalRetry')),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileUI(
    BuildContext context,
    // WidgetRef so we can read/watch providers inside the helper
    WidgetRef ref,
    LocalizationState l10n,
    IntentProfileData profileData,
    // interest display map: interestKey -> translationKey
    Map<String, String> interestDisplayMap,
    AsyncValue<List<Map<String, dynamic>>> languageOptionsAsync,
    Map<String, List<String>> sharedLanguages,
    bool isOnline,
    UserProfile? otherProfile,
    UserProfile? currentProfile,
    ScrollController scrollController,
    // Already-resolved display name from build(): identical string as the
    // AppBar title, so the two can never disagree (or show "Unknown" in one
    // place and the name in the other).
    String effectiveName,
  ) {
    // Safe intent label: prefer localized label but fall back to a readable form.
    final useImperial = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];

    return Shortcuts(
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
                _handleScroll(intent, scrollController),
          ),
        },
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(16.0),
          children: [
            const SizedBox(height: 20),
            // Photos: show thumbnails in order. If none, show placeholder.
            if (otherProfile?.photos.isNotEmpty == true)
              SizedBox(
                height: 140,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: otherProfile!.photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final source = otherProfile.photos[i];
                    final photoLabel = l10n.getString(
                      'profilePhotoPreviewLabel',
                      params: {'index': '${i + 1}'},
                    );
                    return ProfilePhotoThumbnail(
                      label: photoLabel,
                      onTap: () => _openPhotoPreview(
                        context,
                        i,
                        otherProfile.photos,
                        l10n,
                      ),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SignedImage(
                              source: source,
                              width: 140,
                              height: 140,
                              fit: BoxFit.cover,
                              placeholder: Container(
                                width: 140,
                                height: 140,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                              errorWidget: Container(
                                width: 140,
                                height: 140,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: Icon(
                                  Icons.broken_image,
                                  size: 36,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          if (i == 0)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                color: Colors.black54,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  l10n.getString(
                                    'profileWizardPrimaryPhotoBadge',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              )
            else
              SizedBox(
                height: 140,
                child: Center(child: Text(l10n.getString('profileNoPhotos'))),
              ),
            // Public completeness badge: positive 100% signal only. The raw
            // percentage is never shown for other users.
            if (otherProfile != null &&
                ProfileCompleteness.isFull(otherProfile)) ...[
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ProfileCompletePill(l10n: l10n),
              ),
            ],
            const SizedBox(height: 16),
            // NOTE: the matched user's name lives in the AppBar title (single
            // location, offline-first via _effectiveOtherUserName) — no body
            // header here, to avoid showing the name twice.
            // Grouped "why you matched" summary: proximity/event basis,
            // shared main intentions, and shared interest count in one
            // highlighted card.
            _buildMatchBasisCard(
              context,
              l10n,
              ref,
              otherProfile,
              currentProfile,
            ),
            // Pinned home-base: partner matches from elsewhere right now.
            // Realtime via pinnedPartnerProvider + pinnedPartnerRealtimeProvider
            // (broadcast on pin/unpin/extend/expire + 30s poll), so this
            // appears/disappears immediately without leaving the profile.
            if (widget.otherUserId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PinnedPartnerChip(
                    otherUserId: widget.otherUserId,
                  ),
                ),
              ),
            // Rematch indicator - now with name: "Rematch! This is your 2nd time matching with {name}"
            if (_effectiveOccurrence(ref) > 1) ...[
              const SizedBox(height: 12),
              _buildRematchBanner(
                context,
                l10n,
                _effectiveOccurrence(ref),
                effectiveName,
              ),
            ],
            if (widget.isRetroactive) ...[
              const SizedBox(height: 12),
              _buildRetroBanner(context, l10n),
            ],
            // Proximity location mini-map(s) - generic (no exact coords) for privacy.
            // Each map header already shows its own date+time, so the separate
            // Matched-on row below is hidden when maps are displayed.
            if (widget.matchType == 'proximity' ||
                widget.matchType == 'manual_test' ||
                widget.matchType == 'co_motion') ...[
              const SizedBox(height: 12),
              _buildMatchLocationSection(context, l10n, ref),
            ],
            if (!_hasDisplayableMaps(ref)) ...[
              const SizedBox(height: 8),
              Directionality(
                textDirection: l10n.textDirection,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Single-line matched-at display: "Matched at: January 3, 2026, at 21:53"
                    // Shown only when no maps (event matches / no location).
                    Text(
                      () {
                        final label = l10n.getString('matchedAt');
                        final dateText =
                            DateFormat(
                              'MMMM d, yyyy',
                              l10n.currentLocale.languageCode,
                            ).format(
                              (widget.createdAt ?? DateTime.now()).toLocal(),
                            );
                        final timeText = formatTimeOfDateTimeWithPrefs(
                          context,
                          ref,
                          l10n,
                          (widget.createdAt ?? DateTime.now()).toLocal(),
                        );
                        final connector = l10n.getString('at');
                        return '$label: $dateText, $connector $timeText';
                      }(),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
            if (otherProfile?.dateOfBirth != null) ...[
              const SizedBox(height: 8),
              _buildMatchProfileItem(
                context,
                Icons.calendar_month_outlined,
                () {
                  final age =
                      DateTime.now().year - otherProfile!.dateOfBirth!.year;
                  final hasHadBirthday =
                      DateTime.now().month > otherProfile.dateOfBirth!.month ||
                      (DateTime.now().month ==
                              otherProfile.dateOfBirth!.month &&
                          DateTime.now().day >= otherProfile.dateOfBirth!.day);
                  final actualAge = hasHadBirthday ? age : age - 1;

                  // Get the age label translation from Supabase
                  final ageLabel = l10n.getString('profileAgeLabel');

                  // Use Supabase translation with fallback to English
                  final displayLabel =
                      ageLabel != 'profileAgeLabel' && ageLabel.isNotEmpty
                      ? ageLabel
                      : 'Age';

                  return '$displayLabel: $actualAge';
                }(),
              ),
            ],
            if (otherProfile?.dateOfBirth != null) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final sign = calculateZodiacSign(otherProfile!.dateOfBirth);
                  if (sign == null) return const SizedBox.shrink();
                  return _buildMatchProfileItem(
                    context,
                    Icons.auto_awesome_outlined,
                    '${l10n.getString('profileZodiacSign')}: ${zodiacIcon(sign)} ${l10n.getString('zodiac${sign.capitalize()}')}',
                  );
                },
              ),
            ],
            if (otherProfile != null &&
                otherProfile.gender != null &&
                otherProfile.gender!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildMatchProfileItem(
                context,
                Icons.wc_outlined,
                () {
                  final genderLabel = _getGenderLabel(
                    otherProfile.gender!,
                    ref,
                    l10n,
                  );
                  return '${l10n.getString('profileGender')}: $genderLabel';
                }(),
                textDirection: (() {
                  final genderLabel = _getGenderLabel(
                    otherProfile.gender!,
                    ref,
                    l10n,
                  );
                  final genderText =
                      '${l10n.getString('profileGender')}: $genderLabel';
                  return RegExp(r'[a-zA-Z]').hasMatch(genderText)
                      ? ui.TextDirection.ltr
                      : (genderText.isRtl()
                            ? ui.TextDirection.rtl
                            : ui.TextDirection.ltr);
                })(),
              ),
            ],
            const SizedBox(height: 30),
            if (profileData.bio.isNotEmpty &&
                profileData.bio.trim() !=
                    l10n.getString('matchProfileNoBio').trim()) ...[
              _buildSectionHeader(context, l10n.getString('matchProfileBio')),
              _TranslatableProfileText(
                userId: widget.otherUserId,
                field: 'bio',
                originalText: profileData.bio,
                // Bio is self-description (first person): ONLY the
                // writer's gender inflects it. Passing the viewer's
                // gender would add a competing signal ("addressed is a
                // man") and DeepL resolves conflicts to the masculine
                // generic — exactly the אוהב-for-a-woman bug.
                speakerGender: otherProfile?.gender,
                bodyLarge: true,
              ),
              const Divider(height: 30),
            ],

            // Profile Details (filtered by match intent)
            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'occupation') &&
                otherProfile.occupation != null &&
                otherProfile.occupation!.trim().isNotEmpty) ...[
              _buildSectionHeader(context, l10n.getString('profileOccupation')),
              _TranslatableProfileText(
                userId: widget.otherUserId,
                field: 'occupation',
                originalText: otherProfile.occupation!.trim(),
                // Same as bio: self-description, writer's gender only.
                speakerGender: otherProfile.gender,
                bodyLarge: false,
              ),
              const Divider(height: 20),
            ],

            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'education') &&
                otherProfile.education != null &&
                otherProfile.education!.trim().isNotEmpty) ...[
              _buildSectionHeader(context, l10n.getString('profileEducation')),
              _buildMatchProfileItem(
                context,
                Icons.school_outlined,
                '${l10n.getString('profileEducation')}: ${_localizedEducationValue(l10n, otherProfile.education!)}',
              ),
              const Divider(height: 20),
            ],

            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'height') &&
                otherProfile.height != null) ...[
              _buildSectionHeader(context, l10n.getString('profileHeight')),
              _buildMatchProfileItem(
                context,
                Icons.straighten,
                '${l10n.getString('profileHeight')}: ${_formatHeight(l10n, otherProfile.height!, useImperial ? 'ft' : 'cm')}',
              ),
              const Divider(height: 20),
            ],

            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'lifestyle') &&
                otherProfile.lifestyle != null &&
                (otherProfile.lifestyle!['smoking'] != null ||
                    otherProfile.lifestyle!['drinking'] != null ||
                    otherProfile.lifestyle!['exercise'] != null ||
                    otherProfile.lifestyle!['diet'] != null)) ...[
              _buildSectionHeader(context, l10n.getString('profileLifestyle')),
              if (otherProfile.lifestyle!['smoking'] != null &&
                  (otherProfile.lifestyle!['smoking'] as String)
                      .trim()
                      .isNotEmpty)
                _buildMatchProfileItem(
                  context,
                  Icons.smoke_free_outlined,
                  '${l10n.getString('profileLifestyleSmoking')}: ${_localizedLifestyleValue(l10n, 'smoking', otherProfile.lifestyle!['smoking'] as String)}',
                ),
              if (otherProfile.lifestyle!['drinking'] != null &&
                  (otherProfile.lifestyle!['drinking'] as String)
                      .trim()
                      .isNotEmpty)
                _buildMatchProfileItem(
                  context,
                  Icons.local_bar_outlined,
                  '${l10n.getString('profileLifestyleDrinking')}: ${_localizedLifestyleValue(l10n, 'drinking', otherProfile.lifestyle!['drinking'] as String)}',
                ),
              if (otherProfile.lifestyle!['exercise'] != null &&
                  (otherProfile.lifestyle!['exercise'] as String)
                      .trim()
                      .isNotEmpty)
                _buildMatchProfileItem(
                  context,
                  Icons.fitness_center_outlined,
                  '${l10n.getString('profileLifestyleExercise')}: ${_localizedLifestyleValue(l10n, 'exercise', otherProfile.lifestyle!['exercise'] as String)}',
                ),
              if (otherProfile.lifestyle!['diet'] != null &&
                  (otherProfile.lifestyle!['diet'] as String).trim().isNotEmpty)
                _buildMatchProfileItem(
                  context,
                  Icons.restaurant_outlined,
                  '${l10n.getString('profileLifestyleDiet')}: ${_localizedLifestyleValue(l10n, 'diet', otherProfile.lifestyle!['diet'] as String)}',
                ),
              const Divider(height: 20),
            ],

            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'family') &&
                otherProfile.family != null &&
                (otherProfile.family!['has_children'] != null ||
                    (otherProfile.family!['wants_children'] != null &&
                        (otherProfile.family!['wants_children'] as String)
                            .trim()
                            .isNotEmpty))) ...[
              _buildSectionHeader(context, l10n.getString('profileFamily')),
              if (otherProfile.family!['has_children'] != null)
                _buildMatchProfileItem(
                  context,
                  Icons.child_care_outlined,
                  '${l10n.getString('profileFamilyHasChildren')}: ${(otherProfile.family!['has_children'] == true) ? l10n.getString('profileYes') : l10n.getString('profileNo')}',
                ),
              if (otherProfile.family!['wants_children'] != null &&
                  (otherProfile.family!['wants_children'] as String)
                      .trim()
                      .isNotEmpty)
                _buildMatchProfileItem(
                  context,
                  Icons.child_friendly_outlined,
                  '${l10n.getString('profileFamilyWantsChildren')}: ${_localizedFamilyWantsChildrenValue(l10n, otherProfile.family!['wants_children'] as String)}',
                ),
              const Divider(height: 20),
            ],

            if (otherProfile != null &&
                _shouldShowFieldForIntent(widget.matchedIntent, 'religion') &&
                otherProfile.religion != null &&
                otherProfile.religion!['religion'] != null &&
                (otherProfile.religion!['religion'] as String)
                    .trim()
                    .isNotEmpty) ...[
              _buildSectionHeader(context, l10n.getString('profileReligion')),
              _buildMatchProfileItem(
                context,
                Icons.self_improvement_outlined,
                '${l10n.getString('profileReligion')}: ${_localizedReligionValue(l10n, otherProfile.religion!['religion'] as String)}',
              ),
              const Divider(height: 20),
            ],

            // Social Links
            if (otherProfile != null && _hasAnySocialLinks(otherProfile)) ...[
              _buildSectionHeader(
                context,
                l10n.getString('profileSocialLinks'),
              ),
              _buildMatchSocialLinks(
                context,
                l10n,
                ref,
                otherProfile,
                widget.matchedIntent,
              ),
              const Divider(height: 30),
            ],

            if (profileData.subIntents.isNotEmpty) ...[
              _buildSectionHeader(
                context,
                l10n.getString('matchProfileSharedIntent'),
              ),
              _buildSharedIntentsSection(
                context,
                ref,
                l10n,
                profileData.subIntents,
                allIntents,
              ),
              const Divider(height: 30),
            ],

            if (profileData.interests.isNotEmpty) ...[
              _buildSectionHeader(
                context,
                l10n.getString('matchProfileSharedInterests'),
              ),
              _buildSharedInterestsSection(
                context,
                ref,
                l10n,
                profileData.interests,
                interestDisplayMap,
              ),
            ],

            const SizedBox(height: 20),
            _buildSectionHeader(
              context,
              l10n.getString('profileLanguagesKnown'),
            ),
            if (otherProfile == null ||
                otherProfile.languagesKnown.isEmpty ||
                otherProfile.languagesKnown.entries
                    .where((e) => e.key != 'languages' && e.value.isNotEmpty)
                    .isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: Text(
                  l10n.getString('matchProfileNoLanguages'),
                  textDirection: ui.TextDirection.ltr,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children:
                    (otherProfile.languagesKnown.entries
                            .where(
                              (e) => e.key != 'languages' && e.value.isNotEmpty,
                            )
                            .toList()
                          ..sort((a, b) => a.key.compareTo(b.key)))
                        .map((e) {
                          final langCode = e.key;
                          final skills = _orderedLanguageSkills(e.value);
                          // Get display name for language
                          String displayName = langCode;
                          try {
                            final translatedName = l10n.getString(
                              'lang_$langCode',
                            );
                            if (translatedName.isNotEmpty &&
                                !translatedName.startsWith('lang_')) {
                              displayName = translatedName;
                            }
                          } catch (_) {
                            displayName = langCode.toUpperCase();
                          }

                          // Format skills with localization
                          final skillsText = skills
                              .map((skill) {
                                final skillName = l10n.getString(skill);
                                return skillName;
                              })
                              .join(', ');

                          return _buildMatchProfileItem(
                            context,
                            Icons.language_outlined,
                            '$displayName: $skillsText',
                            textDirection:
                                RegExp(r'[a-zA-Z]').hasMatch(skillsText)
                                ? ui.TextDirection.ltr
                                : (skillsText.isRtl()
                                      ? ui.TextDirection.rtl
                                      : ui.TextDirection.ltr),
                          );
                        })
                        .toList(),
              ),

            const SizedBox(height: 40),
            if (widget.otherUserId.isNotEmpty) ...[
              FutureBuilder(
                future: Future.wait([
                  _otherRatingSummaryFuture ??
                      _ratingService.getUserRatingSummary(widget.otherUserId),
                  _ratingQuestionsFuture ?? _ratingService.getQuestions(),
                  _hasRatedThisMatchFuture ?? Future.value(false),
                  _hasPendingRatingPromptFuture ?? Future.value(false),
                ]),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox.shrink();
                  }
                  final data = snapshot.data!;
                  final summary = data[0] as UserRatingSummary;
                  final questions = (data[1] as List<RatingQuestion>)
                      .take(5)
                      .toList();
                  final hasRatedThisMatch = (data[2] as bool?) ?? false;
                  final hasPendingRatingPrompt = (data[3] as bool?) ?? false;

                  final hasRatings = summary.overallAvg != null;
                  final questionAverages = <double?>[
                    summary.q1Avg,
                    summary.q2Avg,
                    summary.q3Avg,
                    summary.q4Avg,
                    summary.q5Avg,
                  ];

                  Future<void> showQuestion(
                    String headerKey,
                    String questionKey,
                  ) async {
                    final header = l10n.getString(headerKey);
                    final question = l10n.getString(questionKey);
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(header),
                        content: Text(question),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(l10n.getString('generalCancel')),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hasRatings) ...[
                        _buildSectionHeader(
                          context,
                          l10n.getString('ratingSectionTitle'),
                        ),
                        Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                              width: 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (
                                  var i = 0;
                                  i < questions.length &&
                                      i < questionAverages.length;
                                  i++
                                )
                                  if (questionAverages[i] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 2.0,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Row(
                                              children: [
                                                Flexible(
                                                  // No ellipsis: question headers always show in full (wraps).
                                                  child: Text(
                                                    l10n.getString(
                                                      _headerKeyForQuestion(
                                                        questions[i],
                                                      ),
                                                    ),
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.bodyMedium,
                                                  ),
                                                ),
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  icon: const Icon(
                                                    Icons.info_outline,
                                                    size: 18,
                                                  ),
                                                  onPressed: () => showQuestion(
                                                    _headerKeyForQuestion(
                                                      questions[i],
                                                    ),
                                                    questions[i].translationKey,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            _formatScore(
                                              questionAverages[i]!,
                                              decimals: 1,
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                const Divider(height: 18),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        l10n.getString('ratingOverall'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                    Text(
                                      _formatScore(
                                        summary.overallAvg!,
                                        decimals: 2,
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (hasPendingRatingPrompt && !hasRatedThisMatch)
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: widget.matchId.isEmpty
                                ? null
                                : () async {
                                    final result = await Navigator.of(context)
                                        .push<bool>(
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                MatchRatingScreen(
                                                  matchId: widget.matchId,
                                                  otherUserId:
                                                      widget.otherUserId,
                                                  otherUserName: effectiveName,
                                                ),
                                          ),
                                        );
                                    if (result == true && mounted) {
                                      setState(() {
                                        _otherRatingSummaryFuture =
                                            _ratingService.getUserRatingSummary(
                                              widget.otherUserId,
                                            );
                                        _hasRatedThisMatchFuture =
                                            _ratingService.hasUserRatedMatch(
                                              widget.matchId,
                                            );
                                        _hasPendingRatingPromptFuture =
                                            _ratingService
                                                .hasPendingRatingPrompt(
                                                  widget.matchId,
                                                );
                                      });
                                      ref.invalidate(
                                        userRatingSummaryProvider(
                                          widget.otherUserId,
                                        ),
                                      );
                                      final currentUserId =
                                          supabase.auth.currentUser?.id;
                                      if (currentUserId != null &&
                                          currentUserId.isNotEmpty) {
                                        ref.invalidate(
                                          userRatingSummaryProvider(
                                            currentUserId,
                                          ),
                                        );
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.star_outline),
                            label: Text(l10n.getString('ratingPromptTitle')),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
            Consumer(
              builder: (context, ref, _) {
                final session = ref.watch(locationShareProvider);
                final hasActiveSession =
                    session != null &&
                    session.matchId == widget.matchId &&
                    (session.myStatus == ShareStatus.sharing ||
                        session.otherStatus == ShareStatus.sharing ||
                        session.otherStatus == ShareStatus.unknown);
                if (hasActiveSession) {
                  return LocationShareBanner(
                    otherUserId: widget.otherUserId,
                    otherUserName: effectiveName,
                    onViewMap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const LocationShareMapScreen(),
                        ),
                      );
                    },
                    onStopSharing: () async {
                      await ref
                          .read(locationShareProvider.notifier)
                          .stopSharing();
                    },
                    onChangeDuration: () => _handleChangeDuration(context, ref),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            const SizedBox(height: 12),
            _MatchExtensionSection(
              matchId: widget.matchId,
              otherUserId: widget.otherUserId,
              otherUserName: effectiveName,
              createdAt: widget.createdAt,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.matchId.isNotEmpty
                    ? () => _showUnmatchDialog(context, l10n)
                    : null,
                icon: const Icon(Icons.person_remove_outlined),
                label: Text(l10n.getString('unmatch')),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  List<MatchLocation> _collectAllLocations(WidgetRef ref) {
    if (widget.allMatchLocationsOverride.isNotEmpty) {
      final list = List<MatchLocation>.from(widget.allMatchLocationsOverride);
      list.sort((a, b) => a.occurrence.compareTo(b.occurrence));
      return list;
    }
    // Direct DB fetch fallback (bypasses stale local cache)
    if (_directFetchedLocation != null &&
        _directFetchedLocation!.hasDisplayableLocation) {
      // For rematch, synthesize N maps up to occurrence using same coarse center
      final occ = _directFetchedLocation!.occurrence;
      if (occ > 1) {
        return List.generate(
          occ,
          (i) => i + 1 == occ
              ? _directFetchedLocation!
              : MatchLocation(
                  occurrence: i + 1,
                  mapCenterLat: _directFetchedLocation!.mapCenterLat,
                  mapCenterLng: _directFetchedLocation!.mapCenterLng,
                  mapZoom: _directFetchedLocation!.mapZoom,
                  matchedIntent: widget.matchedIntent,
                  createdAt: widget.createdAt,
                  matchId: widget.matchId,
                ),
        );
      }
      return [_directFetchedLocation!];
    }
    List<MatchLocation> widgetList = [];
    final hasCoarse =
        widget.mapCenterLat != null && widget.mapCenterLng != null;
    final hasCurrentExact =
        widget.user1Latitude != null &&
        widget.user1Longitude != null &&
        widget.user2Latitude != null &&
        widget.user2Longitude != null;
    final hasCurrent = hasCurrentExact || hasCoarse;
    final current = hasCurrent
        ? MatchLocation(
            occurrence: widget.matchOccurrence,
            user1Lat: widget.user1Latitude,
            user1Lng: widget.user1Longitude,
            user2Lat: widget.user2Latitude,
            user2Lng: widget.user2Longitude,
            mapCenterLat: widget.mapCenterLat,
            mapCenterLng: widget.mapCenterLng,
            mapZoom: widget.mapZoom,
            matchedIntent: widget.matchedIntent,
            createdAt: widget.createdAt,
            matchId: widget.matchId,
          )
        : null;
    for (final loc in widget.previousLocations) {
      if (!widgetList.any((e) => e.occurrence == loc.occurrence)) {
        widgetList.add(loc);
      }
    }
    if (current != null &&
        !widgetList.any((e) => e.occurrence == current.occurrence)) {
      widgetList.add(current);
    }
    if (widgetList.isNotEmpty) {
      widgetList.sort((a, b) => a.occurrence.compareTo(b.occurrence));
      if (widgetList.any((l) => l.hasDisplayableLocation)) return widgetList;
    }
    // Fallback to provider (coarse)
    try {
      final currentUserId = supabase.auth.currentUser?.id ?? '';
      final matches = ref
          .watch(recentMatchesProvider(currentUserId))
          .asData
          ?.value;
      if (matches != null) {
        final m = matches.where((e) => e.id == widget.matchId).firstOrNull;
        if (m != null) {
          final all = m.allMatchLocations
              .where((l) => l.hasDisplayableLocation)
              .toList();
          if (all.isNotEmpty) {
            // Persist for offline opens.
            Future.microtask(() => _persistMinimapSnapshot(all));
            return all;
          }
        }
      }
    } catch (_) {}
    // Offline fallback: locally persisted minimap snapshot (Hive settings box).
    if (_snapshotLocations.any((l) => l.hasDisplayableLocation)) {
      final list = List<MatchLocation>.from(_snapshotLocations)
        ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
      return list;
    }
    if (widgetList.isEmpty && current == null) return [];
    widgetList.sort((a, b) => a.occurrence.compareTo(b.occurrence));
    return widgetList;
  }

  int _effectiveOccurrence(WidgetRef ref) {
    int occ = widget.matchOccurrence;
    try {
      final currentUserId = supabase.auth.currentUser?.id ?? '';
      final matches = ref
          .watch(recentMatchesProvider(currentUserId))
          .asData
          ?.value;
      if (matches != null) {
        final m = matches.where((e) => e.id == widget.matchId).firstOrNull;
        if (m != null && m.matchOccurrence > occ) occ = m.matchOccurrence;
      }
    } catch (_) {}
    return occ;
  }

  bool _hasDisplayableMaps(WidgetRef ref) {
    if (widget.matchType != 'proximity' &&
        widget.matchType != 'manual_test' &&
        widget.matchType != 'co_motion') {
      return false;
    }
    try {
      return _collectAllLocations(ref).any((l) => l.hasDisplayableLocation);
    } catch (_) {
      return false;
    }
  }

  Widget _buildRematchBanner(
    BuildContext context,
    LocalizationState l10n,
    int occ, [
    String otherName = '',
  ]) {
    final name = otherName.trim().isNotEmpty
        ? otherName.formatAsFirstNameLastInitial()
        : otherName.trim();
    String text;
    if (occ == 2) {
      if (name.isNotEmpty) {
        text = l10n.getString('rematchBanner2', params: {'name': name});
        if (text == 'rematchBanner2' || text.isEmpty || !text.contains(name)) {
          final fb = l10n.getString(
            'rematchBanner',
            params: {'count': '2', 'name': name},
          );
          text = (fb != 'rematchBanner' && fb.contains(name)) ? fb : text;
        }
      } else {
        text = '';
      }
      if (text.isEmpty || text == 'rematchBanner2') {
        text = l10n.getString('rematchIndicator2');
        if (text == 'rematchIndicator2' || text.isEmpty) {
          text = l10n.getString('rematchIndicator', params: {'count': '2'});
        }
      }
    } else if (occ == 3) {
      if (name.isNotEmpty) {
        text = l10n.getString('rematchBanner3', params: {'name': name});
        if (text == 'rematchBanner3' || text.isEmpty || !text.contains(name)) {
          final fb = l10n.getString(
            'rematchBanner',
            params: {'count': '3', 'name': name},
          );
          text = (fb != 'rematchBanner' && fb.contains(name)) ? fb : text;
        }
      } else {
        text = '';
      }
      if (text.isEmpty || text == 'rematchBanner3') {
        text = l10n.getString('rematchIndicator3');
        if (text == 'rematchIndicator3' || text.isEmpty) {
          text = l10n.getString('rematchIndicator', params: {'count': '3'});
        }
      }
    } else {
      if (name.isNotEmpty) {
        text = l10n.getString(
          'rematchBanner',
          params: {'count': '$occ', 'name': name},
        );
        if (text == 'rematchBanner' || text.isEmpty || !text.contains(name)) {
          text = l10n.getString('rematchIndicator', params: {'count': '$occ'});
        }
      } else {
        text = l10n.getString('rematchIndicator', params: {'count': '$occ'});
      }
      if (text == 'rematchIndicator' ||
          text == 'rematchIndicator...' ||
          text.isEmpty) {
        text = l10n.getString('rematchIndicator', params: {'count': '$occ'});
      }
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rematchInk = AppThemeTokens.accentInk(
      Colors.purple.shade700,
      Theme.of(context).brightness,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? AppThemeTokens.accentSurface(
                Colors.purple.shade700,
                Brightness.dark,
              )
            : Colors.purple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.purple.shade700.withValues(alpha: 0.35)
              : Colors.purple.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.purple.shade700.withValues(alpha: 0.30)
                  : Colors.purple.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.repeat_rounded,
              size: 16,
              color: rematchInk,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: rematchInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRetroBanner(BuildContext context, LocalizationState l10n) {
    final text = l10n.getString('retroBanner');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final retroInk = AppThemeTokens.accentInk(
      Colors.teal.shade700,
      Theme.of(context).brightness,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? AppThemeTokens.accentSurface(
                Colors.teal.shade700,
                Brightness.dark,
              )
            : Colors.teal.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.teal.shade700.withValues(alpha: 0.35)
              : Colors.teal.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.teal.shade700.withValues(alpha: 0.30)
                  : Colors.teal.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.wifi_off_rounded,
              size: 16,
              color: retroInk,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: retroInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchLocationSection(
    BuildContext context,
    LocalizationState l10n,
    WidgetRef ref,
  ) {
    final all = _collectAllLocations(
      ref,
    ).where((l) => l.hasDisplayableLocation).toList();
    if (all.isEmpty) return const SizedBox.shrink();
    // Persist to local storage so the minimap renders when offline.
    Future.microtask(() => _persistMinimapSnapshot(all));
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 18,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.blue.shade300
                      : Colors.blue.shade700,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.getString('matchMiniMapTitle'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...all.map(
              (loc) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: MatchLocationMiniMap(
                  location: loc,
                  height: 140,
                  // Single match -> header shows just "Location" (no number);
                  // rematches -> "Location #1", "Location #2", etc.
                  showOccurrenceNumber: all.length > 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Grouped "why you matched" summary card.
  ///
  /// Groups the three parameters the match is based on in one highlighted,
  /// user-friendly card:
  /// 1) proximity / event / moving-together basis,
  /// 2) shared main intentions (e.g. "Shared Intentions: Romantic, Friendship"),
  /// 3) shared interests count.
  Widget _buildMatchBasisCard(
    BuildContext context,
    LocalizationState l10n,
    WidgetRef ref,
    UserProfile? otherProfile,
    UserProfile? currentProfile,
  ) {
    final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];

    final basisRow = _buildBasisProximityEventRow(context, l10n);

    // Shared main intentions: prefer the intents stored on the match row
    // (what the match was actually based on); fall back to the live
    // intersection of both users' active modes when the stored value is
    // empty (e.g. legacy rows).
    final intentKeys = _resolveSharedMainIntentKeys(
      currentProfile,
      otherProfile,
    );
    final intentNames = intentKeys
        .map((k) => _localizeMainIntentKey(k, l10n, allIntents))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final hasIntentions = intentNames.isNotEmpty;

    // Shared interests count: needs both profiles.
    int? sharedInterestCount;
    if (otherProfile != null && currentProfile != null) {
      sharedInterestCount = computeSharedInterestCount(
        currentProfile: currentProfile,
        otherProfile: otherProfile,
        matchedIntent: widget.matchedIntent,
      );
    }

    if (basisRow == null && !hasIntentions && sharedInterestCount == null) {
      return const SizedBox.shrink();
    }

    final primary = Theme.of(context).colorScheme.primary;
    final rows = <Widget>[];
    if (basisRow != null) rows.add(basisRow);
    if (hasIntentions) {
      if (rows.isNotEmpty) {
        rows.add(
          Divider(height: 20, thickness: 1),
        );
      }
      rows.add(
        _buildBasisRow(
          context,
          icon: Icons.handshake_outlined,
          iconBackground: Colors.purple.shade50,
          iconColor: Colors.purple.shade700,
          title: l10n.getString('matchProfileSharedIntent'),
          subtitle: intentNames.join(', '),
        ),
      );
    }
    if (sharedInterestCount != null) {
      if (rows.isNotEmpty) {
        rows.add(
          Divider(height: 20, thickness: 1),
        );
      }
      final scoreColor = sharedInterestColor(
        sharedInterestCount,
        Theme.of(context).brightness,
      );
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scoreColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.favorite_rounded, size: 18, color: scoreColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.getString(
                  'sharedInterestsCount',
                  params: {'count': '$sharedInterestCount'},
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: scoreColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: primary.withValues(alpha: 0.25), width: 1.2),
      ),
      color: primary.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  /// First row of the basis card: proximity / event / moving-together.
  /// Returns null for unknown match types (intentions + interests still show).
  Widget? _buildBasisProximityEventRow(
    BuildContext context,
    LocalizationState l10n,
  ) {
    final matchType = widget.matchType;
    if (matchType == 'proximity' || matchType == 'manual_test') {
      return _buildBasisRow(
        context,
        icon: Icons.location_on,
        iconBackground: Colors.blue.shade50,
        iconColor: Colors.blue.shade700,
        title: l10n.getString('matchedByProximityLabel'),
        subtitle: l10n.getString('matchReasonProximityText'),
      );
    }
    if (matchType == 'event') {
      final eventName = widget.eventName;
      Widget subtitle;
      if (eventName?.isNotEmpty == true) {
        subtitle = Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => _openEventMatches(
              context,
              eventId: widget.eventId,
              eventName: eventName,
              eventLink: widget.eventLink,
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              eventName!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
      } else {
        subtitle = Text(
          l10n.getString('matchReasonEvent'),
          style: Theme.of(context).textTheme.bodySmall,
        );
      }
      return _buildBasisRow(
        context,
        icon: Icons.event,
        iconBackground: Colors.orange.shade50,
        iconColor: Colors.orange.shade800,
        title: l10n.getString('attendingSharedEvent'),
        subtitleWidget: subtitle,
      );
    }
    if (matchType == 'co_motion') {
      final title = _resolveMovingTogetherLabel(l10n);
      return _buildBasisRow(
        context,
        icon: Icons.directions_walk,
        iconBackground: Colors.teal.shade50,
        iconColor: Colors.teal.shade700,
        title: title,
        subtitle: null,
      );
    }
    return null;
  }

  /// Generic icon + title + subtitle row used inside the basis card.
  Widget _buildBasisRow(
    BuildContext context, {
    required IconData icon,
    required Color iconBackground,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? subtitleWidget,
  }) {
    final brightness = Theme.of(context).brightness;
    final accent = AppThemeTokens.accentInk(iconColor, brightness);
    final accentBg = brightness == Brightness.dark
        ? AppThemeTokens.accentSurface(iconColor, brightness)
        : iconBackground;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: accentBg,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (subtitleWidget != null) ...[
                const SizedBox(height: 6),
                subtitleWidget,
              ] else if (subtitle?.isNotEmpty == true) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Shared main-intent keys behind this match, ordered for stable display.
  List<String> _resolveSharedMainIntentKeys(
    UserProfile? currentProfile,
    UserProfile? otherProfile,
  ) {
    final fromMatch = getIntentKeysFromMatchedIntent(widget.matchedIntent);
    if (fromMatch.isNotEmpty) return getOrderedSharedIntentKeys(fromMatch);
    if (currentProfile != null && otherProfile != null) {
      final shared = getSharedIntentKeys(
        currentProfile: currentProfile,
        otherProfile: otherProfile,
      );
      if (shared.isNotEmpty) return getOrderedSharedIntentKeys(shared);
    }
    return const <String>[];
  }

  /// Localized display name for a main-intent key, with readable fallback.
  String _localizeMainIntentKey(
    String key,
    LocalizationState l10n,
    List<AppIntent> allIntents,
  ) {
    final norm = key.trim().toLowerCase();
    if (norm.isEmpty) return '';
    try {
      final intent = allIntents.firstWhere(
        (i) => i.key.trim().toLowerCase() == norm,
      );
      if (intent.translationKey.isNotEmpty) {
        final v = l10n.getString(intent.translationKey);
        if (v != intent.translationKey &&
            v.trim().isNotEmpty &&
            !v.endsWith('...')) {
          return v;
        }
      }
    } catch (_) {}
    try {
      if (l10n.containsKey(norm)) {
        final v = l10n.getString(norm);
        if (v != norm && v.trim().isNotEmpty && !v.endsWith('...')) return v;
      }
    } catch (_) {}
    return norm
        .replaceAll('_', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  String _resolveMovingTogetherLabel(LocalizationState l10n) {
    try {
      final v = l10n.getString('matchReasonMovingTogether');
      if (v != 'matchReasonMovingTogether' &&
          v.trim().isNotEmpty &&
          !v.endsWith('...')) {
        return v;
      }
    } catch (_) {}
    try {
      final v = l10n.getString('Moving Together');
      if (v != 'Moving Together' && v.trim().isNotEmpty) return v;
    } catch (_) {}
    return 'Moving together';
  }

  // Build shared intents section with Romantic and Friendship categories
  Widget _buildSharedIntentsSection(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    List<String> subIntents,
    List<AppIntent> allIntents,
  ) {
    // Separate intents by category based on key patterns
    final romanticOriginals = <String>[];
    final friendshipOriginals = <String>[];
    final businessOriginals = <String>[];

    for (final originalIntent in subIntents) {
      // Check if intent is romantic (based on key patterns)
      final lowerKey = originalIntent.toLowerCase();
      if (lowerKey.contains('romantic') ||
          lowerKey.contains('relationship') ||
          lowerKey.contains('dating')) {
        romanticOriginals.add(originalIntent);
      }
      // Check if intent is friendship (based on key patterns)
      else if (lowerKey.contains('friendship') ||
          lowerKey.contains('friend') ||
          lowerKey.contains('social')) {
        friendshipOriginals.add(originalIntent);
      }
      // Check if intent is business/networking (based on key patterns)
      else if (lowerKey.contains('business_networking') ||
          lowerKey.contains('business') ||
          lowerKey.contains('networking')) {
        businessOriginals.add(originalIntent);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (romanticOriginals.isNotEmpty)
          _buildIntentCategory(
            context,
            l10n,
            allIntents,
            'intentCategoryRomantic',
            romanticOriginals,
          ),
        if (friendshipOriginals.isNotEmpty)
          _buildIntentCategory(
            context,
            l10n,
            allIntents,
            'intentCategoryFriendship',
            friendshipOriginals,
          ),
        if (businessOriginals.isNotEmpty)
          _buildIntentCategory(
            context,
            l10n,
            allIntents,
            'intentCategoryBusinessNetworking',
            businessOriginals,
          ),
      ],
    );
  }

  // Build a single intent category section
  Widget _buildIntentCategory(
    BuildContext context,
    LocalizationState l10n,
    List<AppIntent> allIntents,
    String categoryKey,
    List<String> originalIntents,
  ) {
    if (originalIntents.isEmpty) return Container();

    final categoryDisplay = l10n.getString(categoryKey);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            categoryDisplay,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.blue[800],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: originalIntents.map((originalIntent) {
              final intentObj = allIntents.firstWhere(
                (i) => i.key == originalIntent,
                orElse: () =>
                    AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
              );
              final keyToUse = intentObj.translationKey.isNotEmpty
                  ? intentObj.translationKey
                  : originalIntent.split('::').last;
              final displayText = l10n.getString(keyToUse);
              return Chip(
                label: Text(displayText, style: const TextStyle(fontSize: 12)),
                backgroundColor: Colors.blue[50],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.blue[200]!),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // Build shared interests section with Social and Business categories
  Widget _buildSharedInterestsSection(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    Map<String, List<String>> interests,
    Map<String, String> interestDisplayMap,
  ) {
    // Separate social and business interests based on the intent they belong to
    // Organized as categoryKey -> {subInterestKeys}
    final socialByCategory = <String, Set<String>>{};
    final businessByCategory = <String, Set<String>>{};
    final childlessSocial = <String>{};
    final childlessBusiness = <String>{};

    for (final entry in interests.entries) {
      final prefixedKey = entry.key;
      final originalValues = entry.value
          .where((k) => k != '0' && k.isNotEmpty)
          .toSet();

      String intentKey;
      String categoryKey;

      if (prefixedKey.contains('::')) {
        final parts = prefixedKey.split('::');
        if (parts.length < 2) continue;
        intentKey = parts[0];
        categoryKey = parts.sublist(1).join('::');
      } else {
        // Unprefixed key (e.g. from raw user_profiles data): treat as social/default
        intentKey = 'social';
        categoryKey = prefixedKey;
      }

      final interestKeys = originalValues
          .where((k) => k != categoryKey)
          .toSet();
      // The key existing in this map means both users selected this category
      // (from the intersection logic), so it is always "selected".
      // The parent key itself is stripped by toJsonForProfileTableSave,
      // so we cannot rely on originalValues.contains(categoryKey).
      final lowerKey = intentKey.toLowerCase();
      if (interestKeys.isEmpty) {
        // Child-less interest: display as category header, not as chip
        if (lowerKey.contains('friendship') ||
            lowerKey.contains('activity_partner') ||
            lowerKey == 'social') {
          childlessSocial.add(categoryKey);
        } else if (lowerKey.contains('business_networking')) {
          childlessBusiness.add(categoryKey);
        }
      } else {
        // Has sub-interests, use the normal category+chips display
        if (lowerKey.contains('friendship') ||
            lowerKey.contains('activity_partner') ||
            lowerKey == 'social') {
          socialByCategory.putIfAbsent(categoryKey, () => <String>{});
          socialByCategory[categoryKey]!.addAll(interestKeys);
        } else if (lowerKey.contains('business_networking')) {
          businessByCategory.putIfAbsent(categoryKey, () => <String>{});
          businessByCategory[categoryKey]!.addAll(interestKeys);
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (socialByCategory.isNotEmpty || childlessSocial.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              l10n.getString('interestsCategorySocial'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          ..._buildCategoryGroups(
            context,
            l10n,
            socialByCategory,
            interestDisplayMap,
          ),
          ...childlessSocial.map(
            (catKey) => _buildChildlessInterestLabel(
              context,
              l10n,
              catKey,
              interestDisplayMap,
            ),
          ),
        ],
        if (businessByCategory.isNotEmpty || childlessBusiness.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              l10n.getString('interestsCategoryBusiness'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          ..._buildCategoryGroups(
            context,
            l10n,
            businessByCategory,
            interestDisplayMap,
          ),
          ...childlessBusiness.map(
            (catKey) => _buildChildlessInterestLabel(
              context,
              l10n,
              catKey,
              interestDisplayMap,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildChildlessInterestLabel(
    BuildContext context,
    LocalizationState l10n,
    String categoryKey,
    Map<String, String> interestDisplayMap,
  ) {
    final display = _resolveInterestDisplayText(
      l10n,
      categoryKey,
      interestDisplayMap,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
      child: Text(
        display,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.green[700],
        ),
      ),
    );
  }

  List<Widget> _buildCategoryGroups(
    BuildContext context,
    LocalizationState l10n,
    Map<String, Set<String>> categoryMap,
    Map<String, String> interestDisplayMap,
  ) {
    final sortedCategories = categoryMap.keys.toList(growable: false)..sort();
    return sortedCategories.map((categoryKey) {
      final categoryDisplay = _resolveInterestDisplayText(
        l10n,
        categoryKey,
        interestDisplayMap,
      );
      final subKeys = categoryMap[categoryKey]!.toList(growable: false)
        ..sort((a, b) {
          final aName = _resolveInterestDisplayText(
            l10n,
            a,
            interestDisplayMap,
          ).toLowerCase();
          final bName = _resolveInterestDisplayText(
            l10n,
            b,
            interestDisplayMap,
          ).toLowerCase();
          return aName.compareTo(bName);
        });

      return Padding(
        padding: const EdgeInsets.only(left: 8.0, bottom: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              categoryDisplay,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Colors.green[700],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 12.0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: subKeys.map((interestKey) {
                  final displayText = _resolveInterestDisplayText(
                    l10n,
                    interestKey,
                    interestDisplayMap,
                  );
                  return Chip(
                    label: Text(
                      displayText,
                      style: const TextStyle(fontSize: 12),
                    ),
                    backgroundColor: Colors.green[50],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.green[200]!),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  String _getGenderLabel(
    String genderKey,
    WidgetRef ref,
    LocalizationState l10n,
  ) {
    if (genderKey.trim().isEmpty) {
      return l10n.getString('profileNotSet');
    }

    final options = ref.read(genderOptionsProvider).asData?.value ?? [];

    final Map<String, String> found = options.firstWhere(
      (o) => (o['key'] ?? '') == genderKey,
      orElse: () => <String, String>{},
    );

    if (found.isNotEmpty) {
      final displayKey = found['displayKey'] ?? '';
      try {
        final normalizedDisplayKey = _normalizeGenderDisplayKey(displayKey);
        final localized = _tryGetString(l10n, normalizedDisplayKey);
        if (localized != null) return localized;
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final normalizedGenderKey = _normalizeGenderDisplayKey(genderKey);
      final directTranslation = _tryGetString(l10n, normalizedGenderKey);
      if (directTranslation != null) return directTranslation;
    } catch (_) {}

    // Final fallback to humanized key
    return genderKey
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
        .join(' ');
  }

  bool _hasAnySocialLinks(UserProfile profile) {
    return (profile.instagramUrl?.isNotEmpty == true) ||
        (profile.linkedinUrl?.isNotEmpty == true) ||
        (profile.facebookUrl?.isNotEmpty == true);
  }

  Widget _buildMatchSocialLinks(
    BuildContext context,
    LocalizationState l10n,
    WidgetRef ref,
    UserProfile? profile,
    String matchedIntent,
  ) {
    if (profile == null) return const SizedBox.shrink();
    final List<Widget> links = [];
    final isBusinessMatch =
        _normalizeKey(matchedIntent) == 'business_networking';

    if (profile.instagramUrl?.isNotEmpty == true) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.camera_alt_outlined,
          Colors.pink,
          l10n.getString('profileInstagramUrl'),
          profile.instagramUrl!,
        ),
      );
    }

    if (profile.facebookUrl?.isNotEmpty == true) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.group,
          Colors.blue,
          l10n.getString('profileFacebookUrl'),
          profile.facebookUrl!,
        ),
      );
    }

    if (profile.linkedinUrl?.isNotEmpty == true && isBusinessMatch) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.business_center_outlined,
          Colors.blue,
          l10n.getString('profileLinkedinUrl'),
          profile.linkedinUrl!,
        ),
      );
    }

    return Column(children: links);
  }

  Widget _buildSocialLinkTile(
    BuildContext context,
    IconData icon,
    Color iconColor,
    String label,
    String url,
  ) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      margin: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppThemeTokens.accentSurface(
            iconColor,
            Theme.of(context).brightness,
          ),
          child: Icon(
            icon,
            color: AppThemeTokens.accentInk(
              iconColor,
              Theme.of(context).brightness,
            ),
          ),
        ),
        title: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          url,
          style: TextStyle(
            color: AppThemeTokens.accentInk(
              Colors.blue.shade700,
              Theme.of(context).brightness,
            ),
            fontSize: 13,
          ),
          textDirection: ui.TextDirection.ltr,
        ),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => _openUrl(url),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        final fallbackUri = Uri.tryParse(url);
        if (fallbackUri != null) {
          await launchUrl(fallbackUri, mode: LaunchMode.platformDefault);
        }
      }
    } catch (_) {
      // Ignore
    }
  }

  bool _shouldShowFieldForIntent(String matchedIntent, String field) {
    final intent = _normalizeKey(matchedIntent);
    switch (field) {
      case 'height':
      case 'family':
        return intent == 'romantic';
      case 'lifestyle':
        return intent == 'romantic' ||
            intent == 'friendship' ||
            intent == 'activity_partner';
      case 'religion':
        return intent == 'romantic' || intent == 'friendship';
      default:
        return true;
    }
  }

  Widget _buildMatchProfileItem(
    BuildContext context,
    IconData icon,
    String value, {
    ui.TextDirection? textDirection,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      margin: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textDirection: textDirection,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Localized label for the user-initiated profile translate button.
/// Sourced from Supabase (`translations` table) via [LocalizationState];
/// English fallback lives in `locale_provider.dart` `_defaultTranslations`.
String _profileTranslateLabel(LocalizationState l10n) {
  return l10n.getString('profileTranslateButton');
}

/// Localized label for the "show original" toggle (see [_profileTranslateLabel]).
String _profileShowOriginalLabel(LocalizationState l10n) {
  return l10n.getString('profileShowOriginalButton');
}

/// Binary-gender cache key matching [profileTextTranslationProvider]'s
/// `_profileGenderKey` with a null addressee (bio/occupation are
/// first-person self-descriptions, writer's gender only). Kept in sync so
/// user-initiated translations reuse previously cached auto-translations.
String _translatableFieldGenderKey(String? speakerGender) {
  String? norm(String? raw) {
    if (raw == null) return null;
    var g = raw.trim().toLowerCase().replaceAll('-', '_');
    if (g.startsWith('gender_')) g = g.substring('gender_'.length);
    if (g == 'male' || g == 'm') return 'male';
    if (g == 'female' || g == 'f') return 'female';
    return null;
  }

  return '${norm(speakerGender) ?? ''}|';
}

/// User-initiated translation for a profile free-text field (bio/occupation).
///
/// Shows the original text plus a localized Translate button only when the
/// detected source language differs from the viewer's UI language. Tapping
/// translates into the UI language; the button then becomes "Show original",
/// which reverts to the stored text without re-translating.
class _TranslatableProfileText extends ConsumerStatefulWidget {
  final String userId;
  final String field;
  final String originalText;
  final String? speakerGender;
  final bool bodyLarge;

  const _TranslatableProfileText({
    required this.userId,
    required this.field,
    required this.originalText,
    this.speakerGender,
    this.bodyLarge = true,
  });

  @override
  ConsumerState<_TranslatableProfileText> createState() =>
      _TranslatableProfileTextState();
}

class _TranslatableProfileTextState
    extends ConsumerState<_TranslatableProfileText> {
  bool _showingTranslated = false;
  bool _isTranslating = false;
  String? _translatedText;
  String? _translatedTarget;

  @override
  void didUpdateWidget(covariant _TranslatableProfileText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalText != widget.originalText ||
        oldWidget.userId != widget.userId ||
        oldWidget.field != widget.field) {
      _showingTranslated = false;
      _isTranslating = false;
      _translatedText = null;
      _translatedTarget = null;
    }
  }

  bool _canOfferTranslation(String targetLanguage) {
    final text = widget.originalText.trim();
    if (text.isEmpty) return false;
    if (targetLanguage == 'und') return false;
    final source = normalizeLanguageCode(guessLanguageCode(text));
    if (source == 'und') return false;
    return source != targetLanguage;
  }

  Future<void> _onToggle(LocalizationState l10n, String targetLanguage) async {
    if (_isTranslating) return;
    if (_showingTranslated && _translatedTarget == targetLanguage) {
      setState(() => _showingTranslated = false);
      return;
    }
    if (_translatedText != null &&
        _translatedText!.trim().isNotEmpty &&
        _translatedTarget == targetLanguage) {
      setState(() => _showingTranslated = true);
      return;
    }
    setState(() => _isTranslating = true);
    try {
      final text = widget.originalText.trim();
      final genderKey = _translatableFieldGenderKey(widget.speakerGender);
      final localDb = ref.read(localDbProvider);
      final cached = await localDb.getCachedProfileTranslation(
        userId: widget.userId,
        field: widget.field,
        sourceText: text,
        targetLanguage: targetLanguage,
        genderKey: genderKey,
      );
      if (!mounted) return;
      if (cached != null && cached.trim().isNotEmpty) {
        setState(() {
          _translatedText = cached;
          _translatedTarget = targetLanguage;
          _showingTranslated = true;
        });
        return;
      }
      final service = ref.read(translationServiceProvider);
      final sourceLanguage = await service.identifyLanguage(text);
      if (!mounted) return;
      if (sourceLanguage == 'und' ||
          targetLanguage == 'und' ||
          sourceLanguage == targetLanguage) {
        return;
      }
      String translated;
      try {
        translated = await service
            .translateText(
              text,
              sourceLanguage,
              targetLanguage,
              speakerGender: widget.speakerGender,
            )
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        translated = text;
      }
      if (!mounted) return;
      if (translated.trim().isEmpty || translated.trim() == text) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.getString('chatTranslateFailed'))),
          );
        }
        return;
      }
      await localDb.saveCachedProfileTranslation(
        userId: widget.userId,
        field: widget.field,
        sourceText: text,
        targetLanguage: targetLanguage,
        genderKey: genderKey,
        translatedText: translated,
      );
      if (!mounted) return;
      setState(() {
        _translatedText = translated;
        _translatedTarget = targetLanguage;
        _showingTranslated = true;
      });
    } catch (_) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('chatTranslateFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _isTranslating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final targetLanguage = normalizeLanguageCode(
      l10n.currentLocale.languageCode,
    );
    final offersTranslation = _canOfferTranslation(targetLanguage);
    final hasValidTranslation =
        _translatedText != null &&
        _translatedText!.trim().isNotEmpty &&
        _translatedTarget == targetLanguage;
    final showingTranslated =
        _showingTranslated && hasValidTranslation && offersTranslation;
    final displayText = showingTranslated
        ? _translatedText!.trim()
        : widget.originalText.trim();
    final textDirection = RegExp(r'[a-zA-Z]').hasMatch(displayText)
        ? ui.TextDirection.ltr
        : ui.TextDirection.rtl;
    final textAlign = displayText.isRtl() ? TextAlign.right : TextAlign.left;
    final textStyle = widget.bodyLarge
        ? Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4)
        : Theme.of(context).textTheme.bodyMedium;

    Widget textWidget = Text(
      displayText,
      textDirection: textDirection,
      textAlign: textAlign,
      style: textStyle,
    );

    if (!offersTranslation) {
      if (widget.bodyLarge) return textWidget;
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        margin: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.work_outline, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
              const SizedBox(width: 12),
              Expanded(child: textWidget),
            ],
          ),
        ),
      );
    }

    final buttonLabel = showingTranslated
        ? _profileShowOriginalLabel(l10n)
        : _profileTranslateLabel(l10n);
    final toggleButton = Align(
      alignment: AlignmentDirectional.centerStart,
      child: _isTranslating
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.getString('chatTranslating'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            )
          : TextButton(
              onPressed: () => _onToggle(l10n, targetLanguage),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(buttonLabel),
            ),
    );

    if (widget.bodyLarge) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [textWidget, const SizedBox(height: 4), toggleButton],
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      margin: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.work_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [textWidget, toggleButton],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wrapper that flashes/blinks its child when [enabled] is true (<=15m remaining).
class _FlashingCountdown extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _FlashingCountdown({required this.child, required this.enabled});

  @override
  State<_FlashingCountdown> createState() => _FlashingCountdownState();
}

class _FlashingCountdownState extends State<_FlashingCountdown> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _start();
  }

  @override
  void didUpdateWidget(covariant _FlashingCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      if (widget.enabled) {
        _visible = true;
        _start();
      } else {
        _timer?.cancel();
        _timer = null;
        if (_visible != true && mounted) setState(() => _visible = true);
      }
    }
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) return;
      setState(() => _visible = !_visible);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.25,
      duration: const Duration(milliseconds: 300),
      child: widget.child,
    );
  }
}

class _MatchExtensionSection extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final DateTime? createdAt;

  const _MatchExtensionSection({
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    required this.createdAt,
  });

  @override
  ConsumerState<_MatchExtensionSection> createState() =>
      _MatchExtensionSectionState();
}

class _MatchExtensionSectionState
    extends ConsumerState<_MatchExtensionSection> {
  bool _isExtending = false;

  @override
  void initState() {
    super.initState();
    // On first build (including after hot restart), trigger a sync to ensure extension data is fresh
    Future.microtask(() {
      if (mounted) {
        final userId = supabase.auth.currentUser?.id;
        if (userId != null && userId.isNotEmpty) {
          ref
              .read(globalSyncManagerProvider)
              .syncMatchesNow(userId)
              .catchError((_) {});
        }
      }
    });
  }

  String _formatDuration(LocalizationState l10n, int seconds) {
    if (seconds >= 3600 && seconds % 3600 == 0) {
      final hours = (seconds / 3600).round();
      final key = hours == 1
          ? 'matchExtensionDurationHours'
          : 'matchExtensionDurationHoursPlural';
      return l10n.getString(key, params: {'count': '$hours'});
    }
    final minutes = (seconds / 60).ceil();
    final key = minutes == 1
        ? 'matchExtensionDurationMinutes'
        : 'matchExtensionDurationMinutesPlural';
    return l10n.getString(key, params: {'count': '$minutes'});
  }

  /// Text for the green extension badge:
  /// both extended -> "Both of you have extended this match.",
  /// current user extended -> "Extended by you",
  /// other user extended -> "Extended by {name}" (fallback: "Extended").
  String _extensionBadgeText(
    LocalizationState l10n,
    String otherName, {
    required bool hasExtended,
    required int extensionCount,
  }) {
    if (extensionCount >= 2) {
      return l10n.getString('matchExtendBothExtended');
    }
    if (hasExtended) {
      return l10n.getString('matchExtendedByYou');
    }
    final name = otherName.trim();
    if (name.isNotEmpty) {
      return l10n.getString('matchExtendedByOther', params: {'name': name});
    }
    return l10n.getString('matchExtendedBadge');
  }

  Future<void> _handleExtend(
    LocalizationState l10n,
    String otherName,
    int extSeconds,
  ) async {
    final durationLabel = _formatDuration(l10n, extSeconds);
    final confirmBody = l10n.getString(
      'matchExtendConfirmBodyBoth',
      params: {'duration': durationLabel, 'name': otherName},
    );
    final fallback = l10n.getString(
      'matchExtendConfirmBody',
      params: {'duration': durationLabel},
    );
    final body =
        confirmBody != 'matchExtendConfirmBodyBoth' &&
            confirmBody.trim().isNotEmpty
        ? confirmBody
        : fallback;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('matchExtendConfirmTitle')),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.getString('matchExtendCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.getString('matchExtendConfirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isExtending = true);
    try {
      final result = await MatchExtensionService.instance.extendMatch(
        widget.matchId,
      );
      if (!mounted) return;
      final newExpiresAt = result['expires_at'] != null
          ? DateTime.tryParse(result['expires_at'].toString())
          : null;
      final remaining = newExpiresAt != null
          ? newExpiresAt.difference(DateTime.now().toUtc())
          : Duration(seconds: extSeconds);
      final remainingLabel = formatCountdownHmsWithPrefs(
        context,
        ref,
        remaining,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'matchExtendSuccess',
              params: {'duration': durationLabel, 'remaining': remainingLabel},
            ),
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
      final uid = supabase.auth.currentUser?.id;
      if (uid != null && uid.isNotEmpty) {
        try {
          await ref.read(globalSyncManagerProvider).syncMatchesNow(uid);
        } catch (_) {}
        ref.invalidate(recentMatchesProvider(uid));
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      String key = 'matchExtendError';
      if (msg.contains('already_extended')) {
        key = 'matchExtendAlreadyExtended';
      } else if (msg.contains('chat_already_started')) {
        key = 'matchExtendChatStarted';
      } else if (msg.contains('match_expired')) {
        key = 'matchExtendExpired';
      } else if (msg.contains('max_extensions_reached')) {
        key = 'matchExtendMaxReached';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString(key)),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExtending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final currentUserId = supabase.auth.currentUser?.id ?? '';
    if (widget.matchId.isEmpty || currentUserId.isEmpty) {
      return const SizedBox.shrink();
    }
    final matchesAsync = ref.watch(recentMatchesProvider(currentUserId));
    final chatIdsAsync = ref.watch(userChatIdsProvider(currentUserId));
    final hasChatStarted =
        chatIdsAsync.asData?.value.contains(widget.matchId) ?? false;
    if (hasChatStarted) return const SizedBox.shrink();

    return matchesAsync.when(
      data: (matches) {
        dynamic match;
        for (final m in matches) {
          if (m.id == widget.matchId) {
            match = m;
            break;
          }
        }
        if (match == null) {
          // Fallback: use widget.createdAt with default window to decide visibility
          final fallbackCreated = widget.createdAt ?? DateTime.now();
          final now = DateTime.now();
          final fallbackWindow = const Duration(hours: 24);
          final fallbackRemaining = fallbackCreated
              .toUtc()
              .add(fallbackWindow)
              .difference(now.toUtc());
          if (fallbackRemaining <= Duration.zero) {
            return const SizedBox.shrink();
          }
          return FutureBuilder<int>(
            future: appConfigService.getInt(
              'matches.chat_start_extension_seconds',
              defaultValue: const Duration(hours: 24).inSeconds,
            ),
            builder: (_, snap) {
              final ext = snap.data ?? const Duration(hours: 24).inSeconds;
              return _buildCard(
                context,
                l10n,
                hasExtended: false,
                extensionCount: 0,
                remaining: fallbackRemaining,
                extensionSeconds: ext,
                otherName: widget.otherUserName,
              );
            },
          );
        }
        final now =
            ref.watch(matchExpiryNowProvider).asData?.value ?? DateTime.now();
        final remaining = match.remainingFrom(now);
        if (remaining <= Duration.zero) return const SizedBox.shrink();
        return FutureBuilder<int>(
          future: appConfigService.getInt(
            'matches.chat_start_extension_seconds',
            defaultValue:
                match.chatStartWindowSeconds ??
                const Duration(hours: 24).inSeconds,
          ),
          builder: (_, snap) {
            final ext =
                snap.data ??
                match.chatStartWindowSeconds ??
                const Duration(hours: 24).inSeconds;
            return _buildCard(
              context,
              l10n,
              hasExtended: match.hasExtended,
              extensionCount: match.chatStartExtensionCount,
              remaining: remaining,
              extensionSeconds: ext,
              otherName: widget.otherUserName,
            );
          },
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) =>
          const SizedBox.shrink(), // ignore: unnecessary_underscores
    );
  }

  Color _countdownColor(Duration remaining, Brightness brightness) {
    // Shade-600/700 hues sink below text contrast on the dark card fills;
    // dark mode steps each status up to a lighter tone.
    final isDark = brightness == Brightness.dark;
    if (remaining <= const Duration(minutes: 60)) {
      return isDark ? Colors.red.shade300 : Colors.red.shade600;
    }
    if (remaining <= const Duration(hours: 24)) {
      return isDark ? Colors.amber.shade400 : Colors.amber.shade700;
    }
    return isDark
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Colors.grey.shade700;
  }

  String _hintText(LocalizationState l10n, String duration) {
    final hint = l10n.getString(
      'matchExpiryHint',
      params: {'duration': duration},
    );
    if (hint != 'matchExpiryHint' &&
        hint.isNotEmpty &&
        hint.contains(duration)) {
      return hint;
    }
    return '${l10n.getString('subscriptionTimeLeft')}: $duration';
  }

  Widget _buildCard(
    BuildContext context,
    LocalizationState l10n, {
    required bool hasExtended,
    required int extensionCount,
    required Duration remaining,
    required int extensionSeconds,
    required String otherName,
  }) {
    final countdownColor = _countdownColor(
      remaining,
      Theme.of(context).brightness,
    );
    final shouldFlash =
        remaining > Duration.zero && remaining <= const Duration(minutes: 15);
    final duration = formatCountdownHmsWithPrefs(context, ref, remaining);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Timer + Extend on SAME row
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _FlashingCountdown(
                    enabled: shouldFlash,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 14,
                          color: countdownColor,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          // No ellipsis: the countdown hint always shows in full (wraps).
                          child: Text(
                            _hintText(l10n, duration),
                            style: TextStyle(
                              fontSize: 12,
                              color: countdownColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!hasExtended) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _isExtending
                        ? null
                        : () =>
                              _handleExtend(l10n, otherName, extensionSeconds),
                    icon: _isExtending
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : Icon(
                            Icons.more_time_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    label: Text(
                      l10n.getString('matchExtendButton'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: const Size(0, 32),
                      side: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.5),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ],
            ),
            if (extensionCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.hourglass_top_rounded,
                    size: 12,
                    color: Colors.green.shade700,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _extensionBadgeText(
                        l10n,
                        otherName,
                        hasExtended: hasExtended,
                        extensionCount: extensionCount,
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Top-level helper functions used by tests and other widgets
List<String> intersectLists(List<String> a, List<String> b) {
  final setB = b.toSet();
  final seen = <String>{};
  final out = <String>[];
  for (final item in a) {
    if (setB.contains(item) && !seen.contains(item)) {
      seen.add(item);
      out.add(item);
    }
  }
  return out;
}

List<String> intersectSubIntentsForIntent(
  UserProfile current,
  IntentProfileData otherIntent,
  String intent,
) {
  final curSubs = current.subIntents[intent] ?? [];
  final otherSubs = otherIntent.subIntents;
  return intersectLists(curSubs, otherSubs);
}

Map<String, List<String>> intersectInterestsForIntent(
  UserProfile current,
  IntentProfileData otherIntent,
  String intent,
) {
  final out = <String, List<String>>{};
  final isBusiness = _normalizeKey(intent) == 'business_networking';
  final primaryBucket = isBusiness
      ? current.businessInterests
      : current.personalInterests;
  final fallbackBucket = isBusiness
      ? current.personalInterests
      : current.businessInterests;

  for (final entry in otherIntent.interests.entries) {
    final baseCat = entry.key;
    final otherVals = entry.value;

    List<String> curVals = primaryBucket[baseCat] ?? [];
    if (curVals.isEmpty) {
      curVals = fallbackBucket[baseCat] ?? [];
    }
    if (curVals.isEmpty) {
      curVals = primaryBucket['$intent::$baseCat'] ?? [];
    }
    if (curVals.isEmpty) {
      curVals = fallbackBucket['$intent::$baseCat'] ?? [];
    }

    final inters = intersectLists(otherVals, curVals);
    final bothHaveCategory =
        primaryBucket.containsKey(baseCat) ||
        fallbackBucket.containsKey(baseCat) ||
        primaryBucket.containsKey('$intent::$baseCat') ||
        fallbackBucket.containsKey('$intent::$baseCat');
    if (inters.isNotEmpty || bothHaveCategory) out[baseCat] = inters;
  }
  return out;
}
