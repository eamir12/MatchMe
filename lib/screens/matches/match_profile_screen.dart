import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:extended_image/extended_image.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/screens/events/attendees_screen.dart';

final supabase = Supabase.instance.client;

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
  });

  @override
  ConsumerState<MatchProfileScreen> createState() => _MatchProfileScreenState();
}

class _MatchProfileScreenState extends ConsumerState<MatchProfileScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;

    final currentUserId = supabase.auth.currentUser?.id ?? '';

    // aggregated local profiles (fast, from local DB)
    final otherProfileAsync = ref.watch(
      userProfileProvider(widget.otherUserId),
    );
    final currentProfileAsync = ref.watch(userProfileProvider(currentUserId));

    // fallback remote intent-specific provider (fetches profile_data for the intent)
    final specificProvider = specificProfileProvider({
      'userId': widget.otherUserId,
      'intent': widget.matchedIntent,
    });

    // This watch MUST be at the top level of the build method to avoid provider creation inside branches.
    final specificAsync = ref.watch(specificProvider);

    // Option providers for rendering labels
    final interestDisplayMap = ref.watch(interestDisplayMapProvider);
    final languageOptionsAsync = ref.watch(languageOptionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.otherUserName,
          textDirection:
              RegExp(r'[a-zA-Z]').hasMatch(widget.otherUserName)
                  ? ui.TextDirection.ltr
                  : (widget.otherUserName.isRtl()
                      ? ui.TextDirection.rtl
                      : ui.TextDirection.ltr),
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
                  Icon(Icons.wifi_off, size: 14, color: Theme.of(context).colorScheme.onSurface),
                  const SizedBox(width: 4),
                  Text(
                    l10n.getString('generalOffline'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12),
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
              // Compute ALL shared data between the two users (not just for the matched intent)
              final Map<String, List<String>> allSharedSubIntents = {};

              for (final intentKey in otherProfile.subIntents.keys) {
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

              for (final entry in otherProfile.interests.entries) {
                final cat = entry.key;
                final otherList = entry.value;
                final currentList = currentProfile.interests[cat] ?? [];
                final intersected = _intersectLists(otherList, currentList);
                if (intersected.isNotEmpty) {
                  allSharedInterests[cat] = intersected;
                }
              }

              // derive shared languages and skills
              final Map<String, List<String>> sharedLanguages = {};
              for (final langEntry in otherProfile.languagesKnown.entries) {
                final lang = langEntry.key;
                final otherSkills =
                    langEntry.value.map((s) => s.toLowerCase()).toList();
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

              // Use intent-specific bio if available, else global bio from profile
              final bio =
                  intentProfile?.bio ?? otherProfile.bio ?? 'No bio provided.';

              // Build an IntentProfileData-like object with ALL shared data
              final IntentProfileData derived = IntentProfileData(
                bio: bio,
                subIntents:
                    allSharedSubIntents.values.expand((list) => list).toList(),
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
                _scrollController,
              );
            }

            // Else: attempt using specificProvider (remote intent-specific row) + currentProfile
            if (currentProfileAsync.isLoading) {
              // Wait for current user's profile: it's needed to compute intersections for "matched only"
              // but avoid blocking forever: also trigger a sync
              Future.microtask(() {
                if (currentUserId.isNotEmpty) {
                  ref.read(profileSyncProvider).syncProfile(currentUserId);
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
                    // Compute ALL shared data between the two users (not just for the matched intent)
                    final Map<String, List<String>> allSharedSubIntents = {};
                    for (final intentKey
                        in otherProfileAvailable.subIntents.keys) {
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

                    for (final entry
                        in otherProfileAvailable.interests.entries) {
                      final cat = entry.key;
                      final otherList = entry.value;
                      final currentList =
                          currentProfileAvailable.interests[cat] ?? [];
                      final intersected = _intersectLists(
                        otherList,
                        currentList,
                      );
                      if (intersected.isNotEmpty) {
                        allSharedInterests[cat] = intersected;
                      }
                    }

                    matchedSubIntents =
                        allSharedSubIntents.values
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
                      final otherSkills =
                          langEntry.value.map((s) => s.toLowerCase()).toList();
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
                  // No current profile: show otherIntentData but we cannot compute intersections -> show all otherIntentData
                  matchedSubIntents = otherIntentData.subIntents;
                  matchedInterests = otherIntentData.interests;
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
                  null,
                  _scrollController,
                );
              },
              loading: () {
                // kick off a background sync to try populate local aggregated profiles
                Future.microtask(() {
                  if (currentUserId.isNotEmpty) {
                    ref.read(profileSyncProvider).syncProfile(currentUserId);
                  }
                  ref.read(profileSyncProvider).syncProfile(widget.otherUserId);
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
    );
  }

  // Open a full-screen preview of the image source (objectPath or url)
  void _openPhotoPreview(
    BuildContext context,
    LocalizationState l10n,
    String source,
  ) async {
    String? url = source;
    try {
      // If source is not an http url, get signed url for objectPath
      if (!source.startsWith('http://') && !source.startsWith('https://')) {
        url = await StorageHelper.getSignedUrl(source, ttlSeconds: 3600);
      } else {
        // Source is an http url. It may be:
        //  - already a signed URL (has token) -> use directly
        //  - a Supabase "public" storage URL without token -> request signed URL
        //  - some external URL -> use directly
        final uri = Uri.tryParse(source);
        if (uri != null) {
          if (uri.queryParameters.containsKey('token') ||
              uri.query.contains('X-Amz-')) {
            // Already signed; use as-is
            url = source;
          } else {
            // Try to convert Supabase public object URL to signed URL (StorageHelper handles extraction)
            final signed = await StorageHelper.getSignedUrl(
              source,
              ttlSeconds: 3600,
            );
            if (signed != null && signed.isNotEmpty) {
              url = signed;
            } else {
              // Fallback to original source (may fail if bucket is private)
              url = source;
            }
          }
        }
      }
    } catch (e) {
      url = source;
    }

    if (url == null || url.isEmpty) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('failedToLoadImage'))),
      );
      return;
    }

    // url is non-null and non-empty here; assert for NetworkImage
    final displayUrl = url;

    if (context.mounted) {
      showDialog(
        context: context,
        builder:
            (_) => Dialog(
              insetPadding: const EdgeInsets.all(8.0),
              backgroundColor: Colors.black,
              child: SizedBox(
                width: double.infinity,
                height: double.infinity,
                child: Stack(
                  children: [
                    ExtendedImage.network(
                      displayUrl,
                      cache: true,
                      cacheKey: StorageHelper.cacheKeyForSource(source),
                      mode: ExtendedImageMode.gesture,
                      fit: BoxFit.contain,
                      initGestureConfigHandler: (_) => GestureConfig(
                        minScale: 1.0,
                        maxScale: 5.0,
                        animationMinScale: 0.8,
                        animationMaxScale: 6.0,
                        speed: 1.0,
                        inertialSpeed: 100.0,
                        initialScale: 1.0,
                        inPageView: false,
                      ),
                      loadStateChanged: (state) {
                        switch (state.extendedImageLoadState) {
                          case LoadState.loading:
                            return const Center(
                              child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                            );
                          case LoadState.completed:
                            return ExtendedRawImage(
                              image: state.extendedImageInfo?.image,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              height: double.infinity,
                            );
                          case LoadState.failed:
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  l10n.getString('failedToLoadImage'),
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            );
                        }
                      },
                    ),
                    Positioned(
                      top: 24,
                      right: 8,
                      child: IconButton(
                        icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurface),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      );
    }
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
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AttendeesScreen(event: event),
              ),
            );
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
        SnackBar(content: Text(eventName ?? 'Event details not available')),
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
    AsyncValue<List<Map<String, String>>> languageOptionsAsync,
    Map<String, List<String>> sharedLanguages,
    bool isOnline,
    UserProfile? otherProfile,
    ScrollController scrollController,
  ) {
    // Safe intent label: prefer localized label but fall back to a readable form.
    final rawIntentKey = widget.matchedIntent.replaceAll('/', '');
    final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];
    // Collect main intent and subintents for uniform formatting
    List<String> allReasons = [rawIntentKey];
    if (profileData.subIntents.isNotEmpty) {
      // Format subintents by removing prefixes
      final formattedSubIntents =
          profileData.subIntents.map((s) {
            final parts = s.split('::');
            return parts.length > 1 ? parts.last : s;
          }).toList();
      allReasons.addAll(formattedSubIntents);
    }
    // Format reasons: replace underscores, capitalize, comma-separated
    final formattedReasons =
        allReasons
            .where((r) => r.trim().isNotEmpty)
            .map((r) => r.replaceAll('_', ' ').trim())
            .map(
              (r) => r
                  .split(' ')
                  .map(
                    (w) =>
                        w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '',
                  )
                  .join(' '),
            )
            .toList();
    String type = '';
    if (widget.matchType == 'proximity' || widget.matchType == 'manual_test') {
      type = 'Proximity';
    } else if (widget.matchType == 'event') {
      type = l10n.getString('matchReasonEvent');
    } else if (widget.matchType == 'co_motion') {
      type = l10n.getString('matchReasonMovingTogether');
    }
    if (type.isNotEmpty) {
      formattedReasons.add(type);
    }
    final intentLabel = formattedReasons.join(', ');

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
            onInvoke:
                (ScrollIntent intent) =>
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
                    return GestureDetector(
                      onTap: () => _openPhotoPreview(context, l10n, source),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SignedImage(
                          source: source,
                          width: 140,
                          height: 140,
                          fit: BoxFit.cover,
                          placeholder: Container(
                            width: 140,
                            height: 140,
                            color: Colors.grey.shade100,
                          ),
                          errorWidget: Container(
                            width: 140,
                            height: 140,
                            color: Colors.grey.shade200,
                            child: const Icon(
                              Icons.broken_image,
                              size: 36,
                              color: Colors.grey,
                            ),
                          ),
                        ),
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
            const SizedBox(height: 16),
            if (widget.matchType == 'event')
              _buildEventMatchCard(
                context,
                l10n,
                eventName: widget.eventName,
                eventLink: widget.eventLink,
                eventId: widget.eventId,
              )
            else if (widget.matchType == 'proximity' ||
                widget.matchType == 'manual_test')
              _buildMatchReasonCard(
                context,
                l10n,
                icon: Icons.location_on,
                title: l10n.getString('matchedByProximityLabel'),
                content: Text(
                  l10n.getString('matchReasonProximityText'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              _buildMatchReasonCard(
                context,
                l10n,
                icon: Icons.favorite,
                title: l10n.getString('matchReasonShared'),
                subtitle: l10n.getString('matchReasonCommon'),
                content: Text(
                  intentLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: l10n.textDirection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString('matchedAt') != 'matchedAt' && l10n.getString('matchedAt').isNotEmpty ? l10n.getString('matchedAt') : 'Matched at',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('MMMM d, yyyy', l10n.currentLocale.languageCode).format((widget.createdAt ?? DateTime.now()).toLocal()),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  ),
                  Text(
                    DateFormat('h:mm a', l10n.currentLocale.languageCode).format((widget.createdAt ?? DateTime.now()).toLocal()),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            if (otherProfile?.dateOfBirth != null) ...[
              const SizedBox(height: 8),
              Text(
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
                textDirection:
                    (() {
                      final age =
                          DateTime.now().year - otherProfile!.dateOfBirth!.year;
                      final hasHadBirthday =
                          DateTime.now().month >
                              otherProfile.dateOfBirth!.month ||
                          (DateTime.now().month ==
                                  otherProfile.dateOfBirth!.month &&
                              DateTime.now().day >=
                                  otherProfile.dateOfBirth!.day);
                      final actualAge = hasHadBirthday ? age : age - 1;

                      // Get the age label translation from Supabase
                      final ageLabel = l10n.getString('profileAgeLabel');

                      // Use Supabase translation with fallback to English
                      final displayLabel =
                          ageLabel != 'profileAgeLabel' && ageLabel.isNotEmpty
                              ? ageLabel
                              : 'Age';

                      final ageText = '$displayLabel: $actualAge';
                      return RegExp(r'[a-zA-Z]').hasMatch(ageText)
                          ? ui.TextDirection.ltr
                          : (ageText.isRtl()
                              ? ui.TextDirection.rtl
                              : ui.TextDirection.ltr);
                    })(),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              ),
            ],
            if (otherProfile != null &&
                otherProfile.gender != null &&
                otherProfile.gender!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                () {
                  final genderLabel = _getGenderLabel(
                    otherProfile.gender!,
                    ref,
                    l10n,
                  );
                  return '${l10n.getString('profileGender')}: $genderLabel';
                }(),
                textDirection:
                    (() {
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
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              ),
            ],
            const SizedBox(height: 30),
            if (profileData.bio.isNotEmpty &&
                profileData.bio != 'No bio provided.') ...[
              _buildSectionHeader(context, l10n.getString('matchProfileBio')),
              Text(
                profileData.bio,
                textDirection: ui.TextDirection.ltr,
                textAlign: l10n.currentLocale.languageCode == 'he'
                    ? TextAlign.right
                    : TextAlign.left,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.4),
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
                  'No languages listed',
                  textDirection:
                      RegExp(r'[a-zA-Z]').hasMatch('No languages listed')
                          ? ui.TextDirection.ltr
                          : ('No languages listed'.isRtl()
                              ? ui.TextDirection.rtl
                              : ui.TextDirection.ltr),
                  style: const TextStyle(color: Colors.grey),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 8.0, right: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:
                      otherProfile.languagesKnown.entries
                          .where(
                            (e) => e.key != 'languages' && e.value.isNotEmpty,
                          )
                          .map((e) {
                            final langCode = e.key;
                            final skills = e.value;
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

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6.0),
                              child: RichText(
                                textDirection:
                                    RegExp(r'[a-zA-Z]').hasMatch(skillsText)
                                        ? ui.TextDirection.ltr
                                        : (skillsText.isRtl()
                                            ? ui.TextDirection.rtl
                                            : ui.TextDirection.ltr),
                                text: TextSpan(
                                  style: TextStyle(
                                    fontSize: 15,
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: '$displayName: ',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(text: skillsText),
                                  ],
                                ),
                              ),
                            );
                          })
                          .toList(),
                ),
              ),

            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed:
                  widget.matchId.isNotEmpty
                      ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => ChatScreen(
                                  matchId: widget.matchId,
                                  otherUserName: widget.otherUserName,
                                  otherUserId: widget.otherUserId,
                                ),
                          ),
                        );
                      }
                      : null,
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(l10n.getString('chatButton')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
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
          color: Colors.grey[600],
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildMatchReasonCard(
    BuildContext context,
    LocalizationState l10n, {
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget content,
  }) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[800],
                  ),
                ),
                if (subtitle != null) ...[
                  const Spacer(),
                  Text(
                    subtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            content,
          ],
        ),
      ),
    );
  }

  Widget _buildEventMatchCard(
    BuildContext context,
    LocalizationState l10n, {
    required String? eventName,
    required String? eventLink,
    required String? eventId,
  }) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event, size: 18, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 0,
                    runSpacing: 4,
                    children: [
                      Text(
                        l10n.getString('attendingSharedEvent'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[800],
                        ),
                      ),
                      if (eventName?.isNotEmpty == true) ...[
                        Text(
                          ': ',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[800],
                          ),
                        ),

                        // Event name rendered inside a subtle button for a clear affordance
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: eventName!.isRtl()
                              ? [
                                  Tooltip(
                                    message: l10n.getString('viewEventMatches') != 'viewEventMatches' && l10n.getString('viewEventMatches').isNotEmpty
                                        ? l10n.getString('viewEventMatches')
                                        : 'View event matches',
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 16,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 260),
                                    child: TextButton(
                                      onPressed: () => _openEventMatches(
                                        context,
                                        eventId: eventId,
                                        eventName: eventName,
                                        eventLink: eventLink,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          eventName,
                                          textAlign: TextAlign.right,
                                          textDirection: ui.TextDirection.rtl,
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context).colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ]
                              : [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 260),
                                    child: TextButton(
                                      onPressed: () => _openEventMatches(
                                        context,
                                        eventId: eventId,
                                        eventName: eventName,
                                        eventLink: eventLink,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          eventName,
                                          textAlign: TextAlign.left,
                                          textDirection: ui.TextDirection.ltr,
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context).colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  Tooltip(
                                    message: l10n.getString('viewEventMatches') != 'viewEventMatches' && l10n.getString('viewEventMatches').isNotEmpty
                                        ? l10n.getString('viewEventMatches')
                                        : 'View event matches',
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 16,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
            children:
                originalIntents.map((originalIntent) {
                  final intentObj = allIntents.firstWhere(
                    (i) => i.key == originalIntent,
                    orElse:
                        () => AppIntent(
                          id: 0,
                          key: '',
                          translationKey: '',
                          sortOrder: 0,
                        ),
                  );
                  final keyToUse =
                      intentObj.translationKey.isNotEmpty
                          ? intentObj.translationKey
                          : originalIntent.split('::').last;
                  final displayText = l10n.getString(keyToUse);
                  return Chip(
                    label: Text(
                      displayText,
                      style: const TextStyle(fontSize: 12),
                    ),
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
    final socialInterests = <String, List<String>>{};
    final businessInterests = <String, List<String>>{};

    for (final entry in interests.entries) {
      final categoryKey = entry.key;
      final interestKeys = entry.value;

      // Determine intent type from category key
      final lowerKey = categoryKey.toLowerCase();
      bool isSocial = false;
      bool isBusiness = false;

      if (lowerKey.contains('friendship') ||
          lowerKey.contains('activity_partner')) {
        isSocial = true;
      } else if (lowerKey.contains('business_networking')) {
        isBusiness = true;
      }

      if (isSocial) {
        socialInterests[categoryKey] = interestKeys;
      } else if (isBusiness) {
        businessInterests[categoryKey] = interestKeys;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (socialInterests.isNotEmpty)
          _buildInterestsCategory(
            context,
            l10n,
            'interestsCategorySocial',
            socialInterests,
            interestDisplayMap,
          ),
        if (businessInterests.isNotEmpty)
          _buildInterestsCategory(
            context,
            l10n,
            'interestsCategoryBusiness',
            businessInterests,
            interestDisplayMap,
          ),
      ],
    );
  }

  // Build a single interests category section
  Widget _buildInterestsCategory(
    BuildContext context,
    LocalizationState l10n,
    String categoryKey,
    Map<String, List<String>> interests,
    Map<String, String> interestDisplayMap,
  ) {
    if (interests.isEmpty) return Container();

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
              color: Colors.green[800],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children:
                interests.entries.expand((entry) {
                  final interestKeys = entry.value;
                  return interestKeys.map((interestKey) {
                    final translationKey =
                        interestDisplayMap[interestKey] ?? interestKey;
                    final displayText = l10n.getString(translationKey);
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
                  });
                }).toList(),
          ),
        ],
      ),
    );
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
        final localized = l10n.getString(displayKey);
        if (localized != displayKey && localized.isNotEmpty) {
          return localized;
        }
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final directTranslation = l10n.getString(genderKey);
      if (directTranslation != genderKey && directTranslation.isNotEmpty) {
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
}
