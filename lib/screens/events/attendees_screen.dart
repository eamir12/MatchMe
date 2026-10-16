// lib/screens/events/attendees_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/event_attendance_summary.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/match_reason_formatter.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/event_venue_utils.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/widgets/safe_text.dart';

final supabase = Supabase.instance.client;

// --- Event Matches Provider (with caching) ---
// Returns the users the current user has matched with (any match type) who
// are attending the event. Attendance is resolved server-side by the
// get_event_matched_attendees RPC because RLS hides other users' attendance.
final eventMatchesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, EventModel>((ref, event) async {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return [];

      final localDb = ref.read(localDbProvider);

      try {
        final isOffline = shouldSkipSupabaseCalls();
        // Try cached attendees first. Online, an EMPTY list is treated as a
        // miss because another user joining may not trip this user's realtime
        // subscription. Offline, return even an empty/stale snapshot instead
        // of replacing previously shown data with a network error.
        final cachedAttendees = await localDb.getEventAttendees(
          event.id,
          allowStale: isOffline,
        );
        if (cachedAttendees != null && cachedAttendees.isNotEmpty) {
          if (kIsWeb) {
            print(
              '?? [WEB] eventMatchesProvider - Using cached attendees for event: ${event.id}',
            );
          }
          return cachedAttendees;
        }

        if (isOffline) {
          return cachedAttendees ?? const <Map<String, dynamic>>[];
        }

        if (kIsWeb) {
          print(
            '🔍 [WEB] eventMatchesProvider - Fetching fresh attendees for event: ${event.id}',
          );
        }

        final response = await supabase.rpc(
          'get_event_matched_attendees',
          params: {'p_event_id': event.id},
        );

        final matches = (response as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();

        // Remove duplicates by ensuring each match pair appears only once
        final seenPairs = <String>{};
        final uniqueMatches = <Map<String, dynamic>>[];

        for (final match in matches) {
          final user1Id = match['user1_id'] as String;
          final user2Id = match['user2_id'] as String;

          // Create a consistent key for the pair (always smaller ID first)
          final pairKey = user1Id.compareTo(user2Id) < 0
              ? '$user1Id-$user2Id'
              : '$user2Id-$user1Id';

          if (!seenPairs.contains(pairKey)) {
            seenPairs.add(pairKey);
            uniqueMatches.add(match);
          }
        }

        // Cache the fetched attendees for future use
        await localDb.saveEventAttendees(event.id, uniqueMatches);

        return uniqueMatches;
      } catch (e) {
        print('Error fetching event attendees: $e');
        rethrow;
      }
    });

class AttendeesScreen extends ConsumerWidget {
  final EventModel event;
  final bool showAppBar;

  const AttendeesScreen({
    super.key,
    required this.event,
    this.showAppBar = true,
  });

  int? _calculateAge(DateTime? dob) {
    if (dob == null) return null;
    final now = DateTime.now();
    int age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  Future<void> _openEventLink(
    BuildContext context,
    LocalizationState l10n,
    String rawUrl,
  ) async {
    final uri = Uri.tryParse(rawUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty) {
      _showEventLinkOpenFailed(context, l10n, rawUrl);
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!launched) {
      try {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (_) {}
    }
    if (!launched) _showEventLinkOpenFailed(context, l10n, rawUrl);
  }

  void _showEventLinkOpenFailed(
    BuildContext context,
    LocalizationState l10n,
    String rawUrl,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.getString('eventLinkOpenFailed')),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(
          label: l10n.getString('generalRetry'),
          textColor: Theme.of(context).colorScheme.onError,
          onPressed: () {
            _openEventLink(context, l10n, rawUrl);
          },
        ),
      ),
    );
  }

  Widget _buildEventDetailRow(
    BuildContext context,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationRow(
    BuildContext context,
    LocalizationState l10n,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDateOnly(DateTime dateTime, LocalizationState l10n) {
    try {
      final curLocale = l10n.currentLocale;
      final langCode = curLocale.languageCode.toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(dateTime);
        } catch (e) {
          return DateFormat('EEEE, d MMMM y').format(dateTime);
        }
      } else {
        try {
          final localeTag = curLocale.toLanguageTag();
          final df = DateFormat('EEEE, MMMM d, y', localeTag);
          return df.format(dateTime);
        } catch (e) {
          return DateFormat('EEEE, MMMM d, y').format(dateTime);
        }
      }
    } catch (e) {
      // Fallback
      return DateFormat('EEEE, MMMM d, yyyy').format(dateTime);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final eventTitle = l10n.getString(
      'eventMatchesTitle',
      params: {'eventName': event.eventName},
    );

    // We only need to watch the one provider that finds matches
    final matchesAsync = ref.watch(eventMatchesProvider(event));

    return Scaffold(
      appBar: showAppBar ? AppBar(title: ShrinkText(eventTitle)) : null,
      body: Column(
        children: [
          if (!showAppBar) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: l10n.getString('backToEvents'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      eventTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.visible,
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Event card: details and matched attendees in one container.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.05),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      event.eventName,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      textAlign: event.eventName.isRtl()
                          ? TextAlign.right
                          : TextAlign.left,
                      textDirection: event.eventName.isRtl()
                          ? ui.TextDirection.rtl
                          : ui.TextDirection.ltr,
                    ),
                    const SizedBox(height: 8),
                    EventAttendanceSummary(
                      attendeeCount: event.attendeeCount,
                      l10n: l10n,
                    ),
                    const SizedBox(height: 8),
                    _buildLocationRow(
                      context,
                      l10n,
                      l10n.getString('eventLocationLabel'),
                      event.eventVenue?.trim().isNotEmpty == true
                          ? event.eventVenue!.trim()
                          : l10n.getString('eventVenueNotSpecified'),
                    ),
                    const SizedBox(height: 4),
                    _buildEventDetailRow(
                      context,
                      l10n.getString('eventDateLabel'),
                      _formatDateOnly(event.startTime, l10n),
                    ),
                    const SizedBox(height: 4),
                    _buildEventDetailRow(
                      context,
                      l10n.getString('eventTimeLabel'),
                      formatTimeOfDateTimeWithPrefs(
                        context,
                        ref,
                        l10n,
                        event.startTime,
                      ),
                    ),
                    if (event.eventLink?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () =>
                            _openEventLink(context, l10n, event.eventLink!),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          minimumSize: const Size(48, 48),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.link,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                l10n.getString('eventViewDetails'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (event.eventVenue != null &&
                        event.eventVenue!.isNotEmpty &&
                        !isVirtualMeetingLocation(event.eventVenue)) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: InkWell(
                          onTap: () async {
                            final success = await openGoogleMaps(
                              event.eventVenue!,
                            );
                            if (!success && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString('errorCouldNotOpenMaps'),
                                  ),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                            }
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.5),
                                width: 1,
                              ),
                            ),
                            child: Icon(
                              Icons.map_outlined,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      l10n.getString('eventMatchedAttendeesOnly'),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Matched attendees list (kept inside the event card)
                    Expanded(
                      child: matchesAsync.when(
                        data: (matches) {
                          if (matches.isEmpty) {
                            return SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: AppEmptyState(
                                icon: Icons.people_outline,
                                title: l10n.getString(
                                  'noMatchesFoundForThisEvent',
                                ),
                                message: l10n.getString('eventMatchingTooltip'),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (context, index) {
                              final match = matches[index];
                              final String matchId = match['id'];
                              final String user1Id = match['user1_id'];
                              final String user2Id = match['user2_id'];
                              final String matchedIntent =
                                  match['matched_intent'] ??
                                  l10n.getString('attendingSharedEvent');

                              // Determine the other user
                              final currentUserId =
                                  supabase.auth.currentUser?.id;
                              final String otherUserId =
                                  (user1Id == currentUserId)
                                  ? user2Id
                                  : user1Id;

                              final otherProfileAsync = ref.watch(
                                userProfileProvider(otherUserId),
                              );

                              return ListTile(
                                leading: otherProfileAsync.when(
                                  data: (profile) {
                                    final photo =
                                        (profile?.photos.isNotEmpty == true)
                                        ? profile!.photos.first
                                        : null;
                                    return CircleAvatar(
                                      radius: 22,
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      child: photo == null
                                          ? Icon(
                                              Icons.person,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                            )
                                          : ClipOval(
                                              child: SignedImage(
                                                source: photo,
                                                width: 44,
                                                height: 44,
                                                fit: BoxFit.cover,
                                                placeholder: const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                                errorWidget: Icon(
                                                  Icons.person,
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                                ),
                                              ),
                                            ),
                                    );
                                  },
                                  loading: () => const CircleAvatar(
                                    radius: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  error: (error, stack) => const CircleAvatar(
                                    radius: 22,
                                    child: Icon(Icons.person),
                                  ),
                                ),
                                title: otherProfileAsync.when(
                                  data: (profile) {
                                    final name =
                                        profile?.name
                                            .formatAsFirstNameLastInitial() ??
                                        l10n.getString('generalUnknown');
                                    final age = _calculateAge(
                                      profile?.dateOfBirth,
                                    );
                                    if (age == null) {
                                      final layout = name.displayTextLayout(
                                        Directionality.of(context),
                                      );
                                      return Text(
                                        name,
                                        textAlign: layout.textAlign,
                                        textDirection: layout.textDirection,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      );
                                    }
                                    return Text(
                                      l10n.getString(
                                        'generalNameAge',
                                        params: {
                                          'name': name,
                                          'age': age.toString(),
                                        },
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    );
                                  },
                                  loading: () => Text(
                                    l10n.getString('generalLoading'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  error: (error, stack) => Text(
                                    l10n.getString('generalUnknown'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                subtitle: Text(
                                  MatchReasonFormatter.formatMatchReasons(
                                    ref,
                                    matchedIntent,
                                    'event',
                                  ),
                                ),
                                onTap: () {
                                  // Resolve the cached name so the profile shows it offline.
                                  final cachedName =
                                      otherProfileAsync.asData?.value?.name
                                          .formatAsFirstNameLastInitial() ??
                                      l10n.getString('generalUnknown');
                                  // Navigate to existing MatchProfileScreen
                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).push(
                                    MaterialPageRoute(
                                      builder: (context) => MatchProfileScreen(
                                        matchId: matchId,
                                        otherUserId: otherUserId,
                                        otherUserName: cachedName,
                                        matchedIntent: matchedIntent,
                                        matchType:
                                            match['match_type'] ?? 'event',
                                        eventId: event.id,
                                        eventName: event.eventName,
                                        eventLink: event.eventLink,
                                        createdAt: DateTime.parse(
                                          match['created_at'],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, s) => AppEmptyState(
                          icon: Icons.cloud_off,
                          title: l10n.getString('eventLoadErrorTitle'),
                          message: l10n.getString('eventLoadErrorMessage'),
                          actionLabel: l10n.getString('generalRetry'),
                          onAction: () =>
                              ref.invalidate(eventMatchesProvider(event)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
