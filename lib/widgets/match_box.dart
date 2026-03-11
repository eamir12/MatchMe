import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui' as ui;

final supabase = Supabase.instance.client;
final Map<String, DateTime> _lastMatchBoxProfileSyncAt = <String, DateTime>{};

/// A shared match box widget that displays a single match with full width.
/// Used by both the home screen (Recent matches) and matches screen.
class MatchBox extends ConsumerStatefulWidget {
  final MatchModel match;
  final bool showDivider;

  const MatchBox({
    super.key,
    required this.match,
    this.showDivider = true,
  });

  @override
  ConsumerState<MatchBox> createState() => _MatchBoxState();
}

class _MatchBoxState extends ConsumerState<MatchBox> {
  final _ratingService = MatchRatingService();
  late Future<double?> _otherUserOverallRatingFuture;

  @override
  void initState() {
    super.initState();
    _otherUserOverallRatingFuture = _getOtherUserOverallRating();
  }

  @override
  void didUpdateWidget(covariant MatchBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.match.otherUserId != widget.match.otherUserId) {
      _otherUserOverallRatingFuture = _getOtherUserOverallRating();
    }
  }

  Future<double?> _getOtherUserOverallRating() async {
    final otherUserId = widget.match.otherUserId.trim();
    if (otherUserId.isEmpty) return null;
    final summary = await _ratingService.getUserRatingSummary(otherUserId);
    return summary.overallAvg;
  }

  void _syncOtherProfile() {
    final otherUserId = widget.match.otherUserId.trim();
    if (otherUserId.isEmpty) return;
    final now = DateTime.now();
    final last = _lastMatchBoxProfileSyncAt[otherUserId];
    if (last != null && now.difference(last) < const Duration(seconds: 15)) return;
    _lastMatchBoxProfileSyncAt[otherUserId] = now;
    ref.read(profileSyncProvider).syncProfile(otherUserId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final textDir = Directionality.of(context);
    _syncOtherProfile();
    ref.listen<AsyncValue<UserProfile?>>(userProfileProvider(widget.match.otherUserId), (previous, next) {
      final prevPhotos = previous?.asData?.value?.photos ?? const <String>[];
      final nextPhotos = next.asData?.value?.photos ?? const <String>[];
      if (listEquals(prevPhotos, nextPhotos)) return;
      developer.log('🏠 MatchBox profile change: otherUserId=${widget.match.otherUserId}, prev=${prevPhotos.length}, next=${nextPhotos.length}', name: 'MatchMeTrace');
      if (nextPhotos.isNotEmpty) {
        developer.log('🏠 MatchBox new first photo: ${nextPhotos.first}', name: 'MatchMeTrace');
      }
      final allPhotos = <String>{...prevPhotos, ...nextPhotos};
      for (final path in allPhotos) {
        if (path.isEmpty) continue;
        StorageHelper.evictImageCache(path);
      }
    });
    final otherProfileAsync = ref.watch(userProfileProvider(widget.match.otherUserId));
    final currentProfileAsync = ref.watch(
      userProfileProvider(supabase.auth.currentUser!.id),
    );
    final now = ref.watch(matchExpiryNowProvider).asData?.value ?? DateTime.now();
    final localDb = ref.watch(localDbProvider);

    final chatStartWindow = Duration(
      seconds: widget.match.chatStartWindowSeconds ?? const Duration(hours: 24).inSeconds,
    );

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: localDb.watchMessages(widget.match.id),
      builder: (context, snapshot) {
        final hasChatStarted = snapshot.data?.isNotEmpty == true;
        final remaining = _remainingBeforeExpiry(
          now,
          widget.match.createdAt,
          chatStartWindow: chatStartWindow,
        );

        return Column(
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
              remainingBeforeExpiry: remaining,
            ),
            if (widget.showDivider) const Divider(height: 1),
          ],
        );
      },
    );
  }

  Widget _buildMatchContent(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    AsyncValue<UserProfile?> currentProfileAsync,
    {required bool hasChatStarted,
    required Duration remainingBeforeExpiry,}
  ) {
    final matchDate = widget.match.createdAt.toLocal();
    final timeStr = formatTimeOfDateTimeWithPrefs(context, ref, l10n, matchDate);

    return InkWell(
      onTap: () {
        final otherName = otherProfileAsync.asData?.value?.name.formatAsFirstNameLastInitial() ??
            l10n.getString('generalUnknown');
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MatchProfileScreen(
              matchId: widget.match.id,
              otherUserId: widget.match.otherUserId,
              otherUserName: otherName,
              matchedIntent: widget.match.matchedIntent,
              matchType: widget.match.matchType,
              eventId: widget.match.eventId,
              eventName: widget.match.eventName,
              eventLink: widget.match.eventLink,
              createdAt: widget.match.createdAt,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          textDirection: textDir,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProfilePhoto(otherProfileAsync, context),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildContentColumn(context, ref, l10n, textDir, otherProfileAsync),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _buildDetailsSection(
              context,
              ref,
              l10n,
              textDir,
              otherProfileAsync,
              currentProfileAsync,
              matchDate,
              timeStr,
              hasChatStarted: hasChatStarted,
              remainingBeforeExpiry: remainingBeforeExpiry,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentColumn(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
  ) {
    return Column(
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: Name
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: otherProfileAsync.when(
                data: (profile) {
                  final name = profile?.name.formatAsFirstNameLastInitial() ??
                      l10n.getString('generalUnknown');
                  return Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.start,
                  );
                },
                loading: () => const Text(
                  '...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                error: (e, s) => Text(
                  l10n.getString('generalError'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            FutureBuilder<double?>(
              future: _otherUserOverallRatingFuture,
              builder: (context, snapshot) {
                final rating = snapshot.data;
                if (rating == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                      const SizedBox(width: 4),
                      Text(
                        _formatScore(rating, decimals: 1),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 3),
        // Row 2: Age and Gender info
        otherProfileAsync.when(
          data: (profile) {
            final age = profile?.dateOfBirth != null
                ? _calculateAge(profile!.dateOfBirth!)
                : null;
            final gender = profile?.gender;
            final List<String> infoParts = [];
            if (age != null) {
              infoParts.add('${l10n.getString('profileAgeLabel')}: $age');
            }
            if (gender != null && gender.isNotEmpty) {
              infoParts.add('${l10n.getString('profileGender')}: ${_getGenderLabel(gender, ref, l10n)}');
            }
            if (infoParts.isEmpty) return const SizedBox.shrink();
            return Text(
              infoParts.join('  •  '),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.start,
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (e, s) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  String _formatScore(double value, {int decimals = 1}) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Widget _buildDetailsSection(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    ui.TextDirection textDir,
    AsyncValue<UserProfile?> otherProfileAsync,
    AsyncValue<UserProfile?> currentProfileAsync,
    DateTime matchDate,
    String timeStr,
    {required bool hasChatStarted,
    required Duration remainingBeforeExpiry,}
  ) {
    final isAtOrUnderOneHour =
        !hasChatStarted &&
        remainingBeforeExpiry > Duration.zero &&
        remainingBeforeExpiry <= const Duration(minutes: 60);
    final countdownColor = isAtOrUnderOneHour
        ? Colors.red.shade600
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);

    return Column(
      textDirection: textDir,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.match.matchType == 'proximity')
          Row(
            children: [
              Icon(
                Icons.location_on,
                size: 12,
                color: Colors.blue.shade600,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  l10n.getString('matchedByProximityLabel'),
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.blue.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.start,
                ),
              ),
            ],
          ),
        Text(
          _computeMatchReason(
            widget.match,
            otherProfileAsync.asData?.value,
            currentProfileAsync.asData?.value,
            l10n,
          ),
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          textAlign: TextAlign.start,
        ),
        const SizedBox(height: 3),
        Text(
          () {
            final label = l10n.getString('matchedAt') != 'matchedAt' && l10n.getString('matchedAt').isNotEmpty ? l10n.getString('matchedAt') : 'Matched at';
            final dateText = DateFormat('MMMM d, yyyy', l10n.currentLocale.languageCode).format(matchDate);
            final connector = l10n.getString('at') != 'at' && l10n.getString('at').isNotEmpty ? l10n.getString('at') : 'at';
            return '$label: $dateText, $connector $timeStr';
          }(),
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[500],
          ),
          textAlign: TextAlign.start,
        ),
        if (!hasChatStarted && remainingBeforeExpiry > Duration.zero) ...[
          const SizedBox(height: 3),
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 12,
                color: countdownColor,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${l10n.getString('subscriptionTimeLeft')}: ${formatCountdownHmsWithPrefs(context, ref, remainingBeforeExpiry)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: countdownColor,
                  ),
                  textAlign: TextAlign.start,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildProfilePhoto(AsyncValue<UserProfile?> otherProfileAsync, BuildContext context) {
    return otherProfileAsync.when(
      data: (profile) {
        if (profile?.photos.isNotEmpty == true) {
          return ClipOval(
            child: SignedImage(
              source: profile!.photos[0],
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              placeholder: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.primary),
              ),
              errorWidget: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.primary),
              ),
            ),
          );
        } else {
          return CircleAvatar(
            radius: 20,
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.primary),
          );
        }
      },
      loading: () => CircleAvatar(
        radius: 20,
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.primary),
      ),
      error: (e, s) => CircleAvatar(
        radius: 20,
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    final monthDiff = today.month - birthDate.month;
    if (monthDiff < 0 ||
        (monthDiff == 0 && today.day < birthDate.day)) {
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

  // Helper to compute intersection of two lists
  List<String> _intersectLists(List<String> a, List<String> b) {
    final setA = a.toSet();
    final setB = b.toSet();
    return setA.intersection(setB).toList();
  }

  // Helper to compute match reason based on profiles
  String _computeMatchReason(
    MatchModel match,
    UserProfile? otherProfile,
    UserProfile? currentProfile,
    LocalizationState l10n,
  ) {
    String sharedIntentsText = '';

    // Try to compute shared intents from profiles or matchedIntent
    if (otherProfile != null && currentProfile != null) {
      // Compute shared main intents (the keys that have overlapping sub-intents)
      final sharedIntentKeys = <String>[];
      for (final intentKey in otherProfile.subIntents.keys) {
        if (currentProfile.subIntents.containsKey(intentKey)) {
          final otherSubs = otherProfile.subIntents[intentKey] ?? [];
          final currentSubs = currentProfile.subIntents[intentKey] ?? [];
          final intersected = _intersectLists(otherSubs, currentSubs);
          if (intersected.isNotEmpty) {
            sharedIntentKeys.add(intentKey);
          }
        }
      }

      if (sharedIntentKeys.isNotEmpty) {
        final localizedIntents = sharedIntentKeys.map((key) => l10n.getString(key)).join(', ');
        sharedIntentsText = '${l10n.getString('intentLabel')}: $localizedIntents';
      }
    }

    // Fallback to matchedIntent if no detailed shared found
    if (sharedIntentsText.isEmpty && match.matchedIntent.isNotEmpty) {
      final parsedIntents = match.matchedIntent.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      final localizedIntents = parsedIntents.map((key) => l10n.getString(key)).join(', ');
      sharedIntentsText = '${l10n.getString('intentLabel')}: $localizedIntents';
    }

    // If event match, include event info
    if (match.matchType == 'event' && match.eventName != null) {
      final eventText = '${l10n.getString('eventLabel')}: ${match.eventName}';
      if (sharedIntentsText.isNotEmpty) {
        return '$eventText\n$sharedIntentsText';
      } else {
        return eventText;
      }
    }

    // For non-event matches
    if (sharedIntentsText.isNotEmpty) {
      return sharedIntentsText;
    }

    // If profiles not loaded and no matchedIntent, show loading
    if (otherProfile == null || currentProfile == null) {
      return l10n.getString('loadingLabel');
    }

    return l10n.getString('matchedByProximityLabel');
  }

  Duration _remainingBeforeExpiry(
    DateTime now,
    DateTime createdAt, {
    required Duration chatStartWindow,
  }) {
    final expiresAt = createdAt.toUtc().add(chatStartWindow);
    return expiresAt.difference(now.toUtc());
  }
}

/// A container for multiple matches that displays them as a full-width list.
/// Used by both the home screen and matches screen.
class MatchBoxList extends ConsumerWidget {
  final List<MatchModel> matches;
  final String title;
  final VoidCallback? onSeeAll;
  final bool showTitle;

  const MatchBoxList({
    super.key,
    required this.matches,
    this.title = 'Recent Matches',
    this.onSeeAll,
    this.showTitle = true,
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
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold) ??
                        const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                return MatchBox(
                  match: match,
                  showDivider: !isLast,
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}
