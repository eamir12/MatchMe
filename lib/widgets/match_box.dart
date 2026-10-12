import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/widgets/pinned_partner_chip.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/match_extension_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/utils/match_score_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/widgets/match_profile_navigation_cue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui' as ui;

final supabase = Supabase.instance.client;

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

/// Live countdown row - ONLY this small widget rebuilds every second.
/// Parent MatchBox watches expiry bool via select (rebuilds once on expiry flip),
/// so photos/names don't flicker on every tick. Keeps yellow<=24h, red<=1h, flash<=15m.
class _LiveCountdownRow extends ConsumerWidget {
  final MatchModel match;
  final bool hasChatStarted;
  final LocalizationState l10n;
  const _LiveCountdownRow({
    required this.match,
    required this.hasChatStarted,
    required this.l10n,
  });

  Color _color(Duration remaining, BuildContext context) {
    if (remaining <= Duration.zero) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    }
    if (remaining <= const Duration(minutes: 60)) {
      return Theme.of(context).colorScheme.error;
    }
    if (remaining <= const Duration(hours: 24)) {
      return Theme.of(context).colorScheme.tertiary;
    }
    return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
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
    // Fallback to old concise style if translation missing
    return '${l10n.getString('subscriptionTimeLeft')}: $duration';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hasChatStarted) return const SizedBox.shrink();
    final now =
        ref.watch(matchExpiryNowProvider).asData?.value ?? DateTime.now();
    final remaining = match.remainingFrom(now);
    if (remaining <= Duration.zero) return const SizedBox.shrink();
    final color = _color(remaining, context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldFlash =
        !reduceMotion && remaining <= const Duration(minutes: 15);
    final duration = formatCountdownHmsWithPrefs(context, ref, remaining);
    final hint = _hintText(l10n, duration);
    return _FlashingCountdown(
      enabled: shouldFlash,
      child: Semantics(
        label: hint,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 12, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                hint,
                style: TextStyle(fontSize: 11, color: color),
                textAlign: TextAlign.start,
                overflow: TextOverflow.visible,
                maxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A shared match box widget that displays a single match with full width.
/// Used by both the home screen (Recent matches) and matches screen.
class MatchBox extends ConsumerStatefulWidget {
  final MatchModel match;
  final bool showDivider;

  const MatchBox({super.key, required this.match, this.showDivider = true});

  @override
  ConsumerState<MatchBox> createState() => _MatchBoxState();
}

class _MatchBoxState extends ConsumerState<MatchBox> {
  bool _isExtending = false;

  String _formatExtensionDuration(LocalizationState l10n, int seconds) {
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
  String _buildExtensionBadgeText(
    LocalizationState l10n,
    AsyncValue<UserProfile?> otherProfileAsync,
    String fallbackName,
  ) {
    if (widget.match.chatStartExtensionCount >= 2) {
      return l10n.getString('matchExtendBothExtended');
    }
    if (widget.match.hasExtended) {
      return l10n.getString('matchExtendedByYou');
    }
    final otherName = otherProfileAsync.asData?.value?.name
        .formatAsFirstNameLastInitial();
    if (otherName != null && otherName.trim().isNotEmpty) {
      return l10n.getString(
        'matchExtendedByOther',
        params: {'name': otherName},
      );
    }
    if (fallbackName.trim().isNotEmpty &&
        fallbackName != l10n.getString('generalUnknown')) {
      return l10n.getString(
        'matchExtendedByOther',
        params: {'name': fallbackName},
      );
    }
    return l10n.getString('matchExtendedBadge');
  }

  Future<void> _handleExtend(LocalizationState l10n) async {
    if (_isExtending) return;
    final otherProfile = ref
        .read(otherUserProfileProvider(widget.match.otherUserId))
        .asData
        ?.value;
    final otherName =
        otherProfile?.name.formatAsFirstNameLastInitial() ??
        l10n.getString('generalUnknown');
    final extensionSeconds = await appConfigService.getInt(
      'matches.chat_start_extension_seconds',
      defaultValue:
          widget.match.chatStartWindowSeconds ??
          const Duration(hours: 24).inSeconds,
    );
    final durationLabel = _formatExtensionDuration(l10n, extensionSeconds);
    final confirmBody = l10n.getString(
      'matchExtendConfirmBodyBoth',
      params: {'duration': durationLabel, 'name': otherName},
    );
    final fallbackBody = l10n.getString(
      'matchExtendConfirmBody',
      params: {'duration': durationLabel},
    );
    final body =
        confirmBody != 'matchExtendConfirmBodyBoth' &&
            confirmBody.trim().isNotEmpty
        ? confirmBody
        : fallbackBody;

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
        widget.match.id,
      );
      if (!mounted) return;
      final newExpiresAt = result['expires_at'] != null
          ? DateTime.tryParse(result['expires_at'].toString())
          : null;
      final Duration remaining = newExpiresAt != null
          ? newExpiresAt.difference(DateTime.now().toUtc())
          : widget.match.remainingFrom(DateTime.now()).inSeconds > 0
          ? widget.match.remainingFrom(DateTime.now()) +
                Duration(seconds: extensionSeconds)
          : Duration(seconds: extensionSeconds);
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
      // Refresh from server so local cache includes the new extension
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        try {
          await ref
              .read(globalSyncManagerProvider)
              .syncMatchesNow(currentUserId);
        } catch (_) {}
        ref.invalidate(recentMatchesProvider(currentUserId));
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
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return const SizedBox.shrink();

    final l10n = ref.watch(localizationProvider);
    final textDir = Directionality.of(context);
    ref.listen<AsyncValue<UserProfile?>>(
      otherUserProfileProvider(widget.match.otherUserId),
      (previous, next) {
        final prevPhotos =
            previous?.asData?.value?.photos ?? const <String>[];
        final nextPhotos = next.asData?.value?.photos ?? const <String>[];
        if (listEquals(prevPhotos, nextPhotos)) return;
        developer.log(
          '🏠 MatchBox profile change: otherUserId=${widget.match.otherUserId}, prev=${prevPhotos.length}, next=${nextPhotos.length}',
          name: 'MatchMeTrace',
        );
        if (nextPhotos.isNotEmpty) {
          developer.log(
            '🏠 MatchBox new first photo: ${nextPhotos.first}',
            name: 'MatchMeTrace',
          );
        }
        final allPhotos = <String>{...prevPhotos, ...nextPhotos};
        for (final path in allPhotos) {
          if (path.isEmpty) continue;
          StorageHelper.evictImageCache(path);
        }
      },
    );
    final otherProfileAsync = ref.watch(
      otherUserProfileProvider(widget.match.otherUserId),
    );
    final currentProfileAsync = ref.watch(userProfileProvider(currentUserId));
    final cachedChats =
        ref.watch(recentChatsProvider(currentUserId)).asData?.value ??
        const <ChatModel>[];
    String cachedChatName = '';
    List<String> cachedChatPhotos = const [];
    for (final chat in cachedChats) {
      if (chat.otherUserId != widget.match.otherUserId) continue;
      cachedChatName = chat.otherUserName;
      cachedChatPhotos = chat.otherUserPhotos;
      break;
    }
    final profileName = otherProfileAsync.asData?.value?.name
        .formatAsFirstNameLastInitial()
        .trim();
    final fallbackName = profileName != null &&
            profileName.isNotEmpty &&
            profileName != l10n.getString('generalUnknown')
        ? profileName
        : cachedChatName.trim().isNotEmpty
        ? cachedChatName
        : l10n.getString('generalUnknown');

    // Determine whether a chat has been started for this match by reading
    // the same source the "Recent Chats" list uses (`userChatIdsProvider`).
    // Previously this was derived from the per-match messages box, which can
    // hold stale rows from a prior session (e.g. a chat that was opened and
    // then deleted, or a sync that left orphaned messages). On one device the
    // messages box would be non-empty (`hasChatStarted = true`, countdown
    // hidden) while on another it would be empty (`hasChatStarted = false`,
    // countdown shown), causing the same user to see different UI on Android
    // vs Chrome. Using the chats set keeps the countdown in lock-step with
    // the "Recent Chats" empty/non-empty state on every device.
    final chatIdsAsync = ref.watch(userChatIdsProvider(currentUserId));
    final hasChatStarted =
        chatIdsAsync.asData?.value.contains(widget.match.id) ?? false;

    // Hide expired without chat. Use select on bool so parent rebuilds ONLY when
    // expiry flips false->true, not every second (prevents visible flicker).
    // Per-second ticking lives in _LiveCountdown below.
    final isExpired = ref.watch(
      matchExpiryNowProvider.select((asyncNow) {
        final now = asyncNow.asData?.value;
        if (now == null) return false;
        return widget.match.remainingFrom(now) <= Duration.zero;
      }),
    );
    if (chatIdsAsync.hasValue && !hasChatStarted && isExpired) {
      return const SizedBox.shrink();
    }

    return Column(
      key: ValueKey('matchbox_${widget.match.id}'),
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMatchContent(
          context,
          ref,
          l10n,
          textDir,
          otherProfileAsync,
          currentProfileAsync,
          hasChatStarted: hasChatStarted,
          isExpired: isExpired,
          fallbackName: fallbackName,
          fallbackPhotos: cachedChatPhotos,
        ),
        if (widget.showDivider) const Divider(height: 1),
      ],
    );
  }

  Widget _buildMatchContent(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    AsyncValue<UserProfile?> currentProfileAsync, {
    required bool hasChatStarted,
    required bool isExpired,
    required String fallbackName,
    required List<String> fallbackPhotos,
  }) {
    final semanticName = fallbackName;

    return Semantics(
      container: true,
      button: true,
      label: '$semanticName. ${l10n.getString('viewMatch')}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.04),
        focusColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.08),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MatchProfileScreen(
                matchId: widget.match.id,
                otherUserId: widget.match.otherUserId,
                otherUserName: fallbackName,
                matchedIntent: widget.match.matchedIntent,
                matchType: widget.match.matchType,
                eventId: widget.match.eventId,
                eventName: widget.match.eventName,
                eventLink: widget.match.eventLink,
                createdAt: widget.match.createdAt,
                matchOccurrence: widget.match.matchOccurrence,
                user1Latitude: widget.match.user1Latitude,
                user1Longitude: widget.match.user1Longitude,
                user2Latitude: widget.match.user2Latitude,
                user2Longitude: widget.match.user2Longitude,
                mapCenterLat: widget.match.mapCenterLat,
                mapCenterLng: widget.match.mapCenterLng,
                mapZoom: widget.match.mapZoom,
                previousLocations: widget.match.previousLocations,
                allMatchLocationsOverride: widget.match.allMatchLocations,
                isRetroactive: widget.match.isRetroactive,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          child: Column(
            textDirection: textDir,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildProfilePhoto(
                    otherProfileAsync,
                    context,
                    l10n,
                    fallbackPhotos,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildContentColumn(
                      context,
                      ref,
                      l10n,
                      textDir,
                      otherProfileAsync,
                      fallbackName,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Rating kept top-right but quiet, so the name stays primary.
                  _RatingSummaryWidget(otherUserId: widget.match.otherUserId),
                  MatchProfileNavigationCue(
                    textDirection: textDir,
                    label: l10n.getString('viewMatch'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _buildMetaLine(
                context,
                ref,
                l10n,
                textDir,
                otherProfileAsync,
                currentProfileAsync,
              ),
              _buildExceptionPills(context, textDir),
              _buildDetailsSection(
                context,
                ref,
                l10n,
                textDir,
                otherProfileAsync,
                currentProfileAsync,
                hasChatStarted: hasChatStarted,
                isExpired: isExpired,
                fallbackName: fallbackName,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Identity column: bold name (+ "Verified"/"New here!" pills when
  /// applicable) on line 1, quiet "67 · Male" on line 2 — no "Age:"/"Gender:"
  /// labels, and the name's trailing last-initial period never collides with
  /// the age. The avatar keeps a bare check overlay as a quick status mark,
  /// so the pill spells the status out for anyone who does not know what the
  /// check means; rating sits top-right of the card (rendered by the caller).
  Widget _buildContentColumn(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    String fallbackName,
  ) {
    final profile = otherProfileAsync.asData?.value;
    final name = profile?.name.formatAsFirstNameLastInitial().trim().isNotEmpty ==
            true
        ? profile!.name.formatAsFirstNameLastInitial()
        : fallbackName;
    final age = profile?.dateOfBirth != null
        ? _calculateAge(profile!.dateOfBirth!)
        : null;
    final rawGender = profile?.gender;
    final genderText =
        (rawGender != null && rawGender.trim().isNotEmpty)
            ? _getGenderLabel(rawGender, ref, l10n)
            : null;
    bool isNewUser = false;
    if (profile?.createdAt != null) {
      isNewUser = DateTime.now().difference(profile!.createdAt!).inDays < 7;
    }
    final isVerified = profile?.isVerified ?? false;

    final metaParts = <String>[
      if (age != null) '$age',
      ?genderText,
    ];

    final nameLayout = name.displayTextLayout(textDir);

    return Column(
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: nameLayout.textAlign,
                textDirection: nameLayout.textDirection,
              ),
            ),
            if (isVerified) ...[
              const SizedBox(width: 6),
              _buildVerifiedPill(context, l10n, profile!),
            ],
            if (isNewUser) ...[
              const SizedBox(width: 6),
              _buildNewUserPill(context, l10n, profile!),
            ],
          ],
        ),
        if (metaParts.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            metaParts.join('  ·  '),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurface.withValues(
                alpha: 0.55,
              ),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.start,
          ),
        ],
      ],
    );
  }

  /// Compact "Verified" pill shown inline after the name. The avatar check
  /// overlay alone was not self-explanatory, so the card always spells the
  /// status out next to the name it belongs to.
  Widget _buildVerifiedPill(
    BuildContext context,
    LocalizationState l10n,
    UserProfile profile,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: Directionality.of(context),
        children: [
          Icon(Icons.verified, size: 12, color: color),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              _verifiedBadgeText(l10n, profile.gender),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact "New here!" accent pill shown inline after the name.
  Widget _buildNewUserPill(
    BuildContext context,
    LocalizationState l10n,
    UserProfile profile,
  ) {
    final color = Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: Directionality.of(context),
        children: [
          Icon(Icons.fiber_new_rounded, size: 12, color: color),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              _newUserBadgeText(l10n, profile.gender),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _verifiedBadgeText(LocalizationState l10n, String? gender) {
    final normalized = (gender ?? '').trim().toLowerCase();
    final key = normalized == 'female'
        ? 'profileVerifiedBadgeFemale'
        : (normalized == 'non_binary' || normalized == 'nonbinary')
            ? 'profileVerifiedBadgeNeutral'
            : 'profileVerifiedBadge';
    final translated = l10n.getString(key);
    if (translated == key ||
        translated == '[$key]' ||
        translated == '$key...' ||
        translated.startsWith(key)) {
      return 'Verified';
    }
    if (translated.trim().isEmpty) return 'Verified';
    return translated;
  }

  String _newUserBadgeText(LocalizationState l10n, String? gender) {
    final normalized = (gender ?? '').trim().toLowerCase();
    final key = normalized == 'female'
        ? 'profileNewUserBadgeFemale'
        : (normalized == 'non_binary' || normalized == 'nonbinary')
            ? 'profileNewUserBadgeNeutral'
            : 'profileNewUserBadge';
    final translated = l10n.getString(key);
    if (translated == key ||
        translated == '[$key]' ||
        translated == '$key...' ||
        translated.startsWith(key)) {
      return 'New here!';
    }
    if (translated.trim().isEmpty) return 'New here!';
    return translated;
  }

  Widget _buildDetailsSection(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    AsyncValue<UserProfile?> currentProfileAsync, {
    required bool hasChatStarted,
    required bool isExpired,
    required String fallbackName,
  }) {
    final successColor =
        Theme.of(context).extension<SemanticColors>()?.success ??
        Theme.of(context).colorScheme.primary;
    return Column(
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Rematch banner below the chips row
        if (widget.match.isRematch) ...[
          const SizedBox(height: 4),
          _buildRematchIndicator(
            context,
            l10n,
            otherProfileAsync,
            fallbackName,
          ),
        ],
        if (widget.match.isRetroactive) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.wifi_off_rounded,
                size: 14,
                color: Colors.teal.shade700,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.getString('retroBanner'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.teal.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 3),
        // Timer + Extend on SAME row. Countdown ticks via child, Extend static.
        // Parent rebuilds only on expiry flip (isExpired via select), no flicker.
        if (!hasChatStarted && !isExpired) ...[
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _LiveCountdownRow(
                  match: widget.match,
                  hasChatStarted: hasChatStarted,
                  l10n: l10n,
                ),
              ),
              if (!widget.match.hasExtended) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isExtending ? null : () => _handleExtend(l10n),
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
                      horizontal: 12,
                      vertical: 8,
                    ),
                    minimumSize: const Size(0, 48),
                    side: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        // Extension badge (green) below timer+extend row when someone extended
        if (!hasChatStarted && widget.match.chatStartExtensionCount > 0) ...[
          const SizedBox(height: 3),
          Row(
            children: [
              Icon(Icons.hourglass_top_rounded, size: 11, color: successColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  _buildExtensionBadgeText(
                    l10n,
                    otherProfileAsync,
                    fallbackName,
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: successColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Quiet single-line meta: icon-prefixed facts separated by dots, no chip
  /// backgrounds — "📍 Proximity · 💬 Friendship · ❤ Shared interests: 3".
  /// Repeating facts (reason, intents, shared interests) live here; only
  /// exceptional signals get pills (see [_buildExceptionPills]). Single line
  /// that ellipsizes, so every card keeps the same height.
  Widget _buildMetaLine(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    AsyncValue<UserProfile?> currentProfileAsync,
  ) {
    final metaColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    final spans = <InlineSpan>[];

    void addSegment(IconData icon, String text, {Color? color}) {
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(text: '   ·   '));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(icon, size: 13, color: color ?? metaColor),
        ),
      );
      spans.add(
        TextSpan(
          text: ' $text',
          style: TextStyle(
            fontSize: 12,
            fontWeight: color != null ? FontWeight.w600 : FontWeight.w400,
            color: color ?? metaColor,
          ),
        ),
      );
    }

    // Match reason
    final matchType = widget.match.matchType;
    if (matchType == 'proximity' || matchType == 'manual_test') {
      addSegment(
        Icons.location_on_rounded,
        l10n.getString('matchedByProximityLabel'),
      );
    } else if (matchType == 'co_motion') {
      addSegment(
        Icons.directions_walk_rounded,
        l10n.getString('matchedByCoMotionLabel'),
      );
    }

    // Matched intent(s) — no "Intent:" label
    for (final intent in widget.match.matchedIntent.split(',')) {
      final trimmed = intent.trim();
      if (trimmed.isEmpty) continue;
      addSegment(
        Icons.chat_bubble_outline_rounded,
        _getIntentTranslation(trimmed, ref, l10n),
      );
    }

    // Shared interests — the only colored element in the band
    final otherProfile = otherProfileAsync.asData?.value;
    final currentProfile = currentProfileAsync.asData?.value;
    if (otherProfile != null && currentProfile != null) {
      final count = computeSharedInterestCount(
        currentProfile: currentProfile,
        otherProfile: otherProfile,
        matchedIntent: widget.match.matchedIntent,
      );
      addSegment(
        Icons.favorite_rounded,
        l10n.getString('sharedInterestsCount', params: {'count': '$count'}),
        color: sharedInterestColor(count),
      );
    }

    if (spans.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text.rich(
        TextSpan(children: spans),
        style: TextStyle(fontSize: 12, color: metaColor),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: textDir,
        textAlign: TextAlign.start,
      ),
    );
  }

  /// Pills reserved for exceptional signals that differ card-to-card: the
  /// event a match came from, and the pinned-location chip (which hides
  /// itself when the partner isn't pinned).
  Widget _buildExceptionPills(
    BuildContext context,
    ui.TextDirection textDir,
  ) {
    final pills = <Widget>[];
    if (widget.match.matchType == 'event' &&
        (widget.match.eventName?.isNotEmpty ?? false)) {
      pills.add(
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: _InfoChip(
            icon: Icons.event_rounded,
            label: widget.match.eventName!,
          ),
        ),
      );
    }
    pills.add(
      Padding(
        padding: const EdgeInsets.only(top: 5),
        child: PinnedPartnerChip(otherUserId: widget.match.otherUserId),
      ),
    );

    return Wrap(
      textDirection: textDir,
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: pills,
    );
  }

  Widget _buildRematchIndicator(
    BuildContext context,
    LocalizationState l10n,
    AsyncValue<UserProfile?> otherProfileAsync,
    String fallbackName,
  ) {
    final occ = widget.match.matchOccurrence;
    final profileName =
        otherProfileAsync.asData?.value?.name
            .formatAsFirstNameLastInitial()
            .trim() ??
        '';
    final otherName = profileName.isNotEmpty ? profileName : fallbackName;
    String text;
    // Prefer banner with name: "Rematch! This is your 2nd time matching with {name}"
    if (occ == 2) {
      if (otherName.isNotEmpty) {
        text = l10n.getString('rematchBanner2', params: {'name': otherName});
        if (text == 'rematchBanner2' ||
            text.isEmpty ||
            !text.contains(otherName)) {
          // Fallback to old key or generic banner with name
          final fallback = l10n.getString(
            'rematchBanner',
            params: {'count': '2', 'name': otherName},
          );
          text = (fallback != 'rematchBanner' && fallback.contains(otherName))
              ? fallback
              : text;
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
      if (otherName.isNotEmpty) {
        text = l10n.getString('rematchBanner3', params: {'name': otherName});
        if (text == 'rematchBanner3' ||
            text.isEmpty ||
            !text.contains(otherName)) {
          final fallback = l10n.getString(
            'rematchBanner',
            params: {'count': '3', 'name': otherName},
          );
          text = (fallback != 'rematchBanner' && fallback.contains(otherName))
              ? fallback
              : text;
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
      if (otherName.isNotEmpty) {
        text = l10n.getString(
          'rematchBanner',
          params: {'count': '$occ', 'name': otherName},
        );
        if (text == 'rematchBanner' ||
            text.isEmpty ||
            !text.contains(otherName)) {
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.repeat_rounded,
            size: 12,
            color: Theme.of(context).colorScheme.tertiary,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.tertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 56px avatar with a small verified check overlaid on the leading corner —
  /// replaces the old full-width "Verified" pill. Semantics keep the
  /// localized verified label so screen readers still announce it.
  Widget _buildProfilePhoto(
    AsyncValue<UserProfile?> otherProfileAsync,
    BuildContext context,
    LocalizationState l10n,
    List<String> fallbackPhotos,
  ) {
    final profile = otherProfileAsync.asData?.value;
    final isVerified = profile?.isVerified ?? false;
    final placeholderColor = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.08);
    final placeholderIcon = Icon(
      Icons.person,
      size: 28,
      color: Theme.of(context).colorScheme.primary,
    );

    Widget avatar;
    final photoSource = profile?.photos.isNotEmpty == true
        ? profile!.photos.first
        : fallbackPhotos.firstOrNull;
    if (photoSource != null && photoSource.isNotEmpty) {
      avatar = ClipOval(
        child: SignedImage(
          source: photoSource,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          placeholder: Container(
            width: 56,
            height: 56,
            color: placeholderColor,
            child: placeholderIcon,
          ),
          errorWidget: Container(
            width: 56,
            height: 56,
            color: placeholderColor,
            child: placeholderIcon,
          ),
        ),
      );
    } else {
      avatar = CircleAvatar(
        radius: 28,
        backgroundColor: placeholderColor,
        child: placeholderIcon,
      );
    }

    return Semantics(
      label: isVerified
          ? _verifiedBadgeText(l10n, profile?.gender)
          : null,
      excludeSemantics: isVerified,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          if (isVerified)
            PositionedDirectional(
              end: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 10,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    final monthDiff = today.month - birthDate.month;
    if (monthDiff < 0 || (monthDiff == 0 && today.day < birthDate.day)) {
      age--;
    }
    return age;
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
        final keyToUse = displayKey.toLowerCase().startsWith('gender_')
            ? displayKey.toLowerCase()
            : 'gender_${displayKey.toLowerCase()}';
        final localized = l10n.getString(keyToUse);
        if (localized != keyToUse && localized.isNotEmpty) {
          return localized;
        }
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final keyToUse = genderKey.toLowerCase().startsWith('gender_')
          ? genderKey.toLowerCase()
          : 'gender_${genderKey.toLowerCase()}';
      final directTranslation = l10n.getString(keyToUse);
      if (directTranslation != keyToUse && directTranslation.isNotEmpty) {
        return directTranslation;
      }
    } catch (_) {}

    // Final fallback to humanized key
    return genderKey
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
        .join(' ');
  }

  /// Helper to get the localized translation for an intent key.
  /// Looks up the AppIntent by key and uses its translationKey.
  String _getIntentTranslation(
    String intentKey,
    WidgetRef ref,
    LocalizationState l10n,
  ) {
    try {
      final allIntents = ref.read(allIntentsProvider).asData?.value ?? [];
      final intent = allIntents.firstWhere(
        (i) => i.key == intentKey,
        orElse: () =>
            AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
      );

      if (intent.translationKey.isNotEmpty) {
        return l10n.getString(intent.translationKey);
      }
    } catch (_) {
      // If lookup fails, fall back to bare key
    }

    // Fallback: use the key directly if it has a translation
    if (l10n.containsKey(intentKey)) return l10n.getString(intentKey);
    return intentKey
        .replaceAll('_', ' ')
        .split(' ')
        .map(
          (w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '',
        )
        .join(' ');
  }

  // Keep for backward-compat; prefer MatchModel.remainingFrom which includes extensions.
  // ignore: unused_element
  Duration _remainingBeforeExpiry(
    DateTime now,
    DateTime createdAt, {
    required Duration chatStartWindow,
  }) {
    final expiresAt = createdAt.toUtc().add(chatStartWindow);
    return expiresAt.difference(now.toUtc());
  }
}

/// Small uniform pill used across the match card: neutral surface background,
/// leading icon, compact text. Currently used for the event-name pill.
class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = theme.colorScheme.onSurface.withValues(alpha: 0.75);
    final background = theme.colorScheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: Directionality.of(context),
        children: [
          Icon(icon, size: 12, color: effectiveColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: effectiveColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingSummaryWidget extends ConsumerWidget {
  final String otherUserId;

  const _RatingSummaryWidget({required this.otherUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final summaryAsync = ref.watch(userRatingSummaryProvider(otherUserId));
    return summaryAsync.when(
      data: (summary) {
        final rating = summary.overallAvg;
        if (rating == null) return const SizedBox.shrink();
        final ratingText = _formatScore(rating, decimals: 1);
        final countText = l10n.getString(
          'ratingRatedBy',
          params: {'count': summary.ratedByCount.toString()},
        );
        return Semantics(
          label: '$ratingText. $countText',
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star_rounded, size: 14, color: Colors.amber.shade700),
                const SizedBox(width: 2),
                Text(
                  ratingText,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // Rated-by count intentionally omitted at list level; it
                // lives on the profile screen.
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (e, s) => const SizedBox.shrink(),
    );
  }

  String _formatScore(double value, {int decimals = 1}) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

/// A container for multiple matches that displays them as a full-width list.
/// Used by both the home screen and matches screen.
class MatchBoxList extends ConsumerWidget {
  final List<MatchModel> matches;
  final String? title;
  final VoidCallback? onSeeAll;
  final bool showTitle;
  final Widget? inlineContent;
  final int inlineContentAfterIndex;

  const MatchBoxList({
    super.key,
    required this.matches,
    this.title,
    this.onSeeAll,
    this.showTitle = true,
    this.inlineContent,
    this.inlineContentAfterIndex = -1,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final textDir = Directionality.of(context);

    if (matches.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title ?? l10n.getString('recentMatches'),
                    style:
                        Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ) ??
                        const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.start,
                  ),
                ),
                if (onSeeAll != null)
                  TextButton(
                    onPressed: onSeeAll,
                    child: Text(l10n.getString('homeSeeAll')),
                  ),
              ],
            ),
          ),
        Card(
          elevation: 2,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Match items (no "New matches: X" header)
              ...matches.asMap().entries.map((entry) {
                final index = entry.key;
                final match = entry.value;
                final isLast = index == matches.length - 1;
                return Column(
                  children: [
                    MatchBox(match: match, showDivider: !isLast),
                    if (inlineContent != null &&
                        index == inlineContentAfterIndex &&
                        index < matches.length - 1)
                      inlineContent!,
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}
