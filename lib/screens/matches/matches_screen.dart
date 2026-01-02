// lib/screens/matches/matches_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/match_reason_formatter.dart';
import 'package:matchme/utils/time_format_utils.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  // Helper to format name from a profile
  String _getFormattedName(UserProfile? profile, LocalizationState l10n) {
    if (profile == null) return l10n.getString('generalError');
    final name = profile.name;
    final parts = name.trim().split(' ');
    if (parts.length > 1 && parts[1].isNotEmpty) {
      return '\u200E${parts[0]} ${parts[1][0].toUpperCase()}.\u200E';
    }
    return '\u200E${parts[0]}\u200E';
  }

  // Helper to calculate age from dateOfBirth
  String _getAgeString(UserProfile? profile) {
    if (profile == null || profile.dateOfBirth == null) return '';
    // Use shared helper to ensure consistent age calculation across app
    final age = calculateAgeFromDate(profile.dateOfBirth!);
    return '$age';
  }

  // Helper to get gender display label
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
        final keyToUse = displayKey.toLowerCase().startsWith('gender_') ? displayKey.toLowerCase() : 'gender_${displayKey.toLowerCase()}';
        final localized = l10n.getString(keyToUse);
        if (localized != keyToUse && localized.isNotEmpty) {
          return localized;
        }
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final keyToUse = genderKey.toLowerCase().startsWith('gender_') ? genderKey.toLowerCase() : 'gender_${genderKey.toLowerCase()}';
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
  Widget build(BuildContext context, WidgetRef ref) {
    final ScrollController scrollController = ScrollController();
    final l10n = ref.watch(localizationProvider);
    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final userId = currentUser.id;
    final allMatchesAsync = ref.watch(recentMatchesProvider(userId));

    // Keep match notification provider alive for realtime subscriptions
    ref.watch(matchNotificationProvider);

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
              onInvoke:
                  (ScrollIntent intent) =>
                      _handleScroll(intent, scrollController),
            ),
          },
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(recentMatchesProvider(userId));
              ref.invalidate(recentChatsProvider(userId));
            },
            child: allMatchesAsync.when(
              data: (matches) {
                if (matches.isEmpty) {
                  return Center(child: Text(l10n.getString('homeNoMatches')));
                }
                return GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.all(8.0),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.8,
                    mainAxisSpacing: 8.0,
                    crossAxisSpacing: 8.0,
                  ),
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final match = matches[index];

                    // --- We wrap the card in a Consumer to get access to ref ---
                    return Consumer(
                      builder: (context, ref, child) {
                        // Watch the profile for this specific match (reactive name resolution)
                        final otherProfileAsync = ref.watch(
                          userProfileProvider(match.otherUserId),
                        );

                        // Get the name and profile image, or a loading/error state
                        final profileData = otherProfileAsync.when(
                          data: (profile) => profile,
                          loading: () => null,
                          error: (e, s) => null,
                        );

                        final String formattedName =
                            profileData != null
                                ? _getFormattedName(profileData, l10n)
                                : l10n.getString('generalLoading');
                        final String ageString =
                            profileData != null
                                ? _getAgeString(profileData)
                                : '';
                        final String genderString =
                            profileData != null &&
                                    profileData.gender != null &&
                                    profileData.gender!.trim().isNotEmpty
                                ? _getGenderLabel(
                                  profileData.gender!,
                                  ref,
                                  l10n,
                                )
                                : '';
                        final String? profileImage =
                            profileData?.photos.isNotEmpty == true
                                ? profileData!.photos[0]
                                : null;

                        return Card(
                          clipBehavior: Clip.antiAlias,
                          elevation: 2,
                          child: InkWell(
                            onTap: () {
                              // Mark match notification as viewed
                              ref
                                  .read(matchNotificationProvider.notifier)
                                  .markAsViewed(match.id);

                              // Always open the matched user's profile (not directly the chat).
                              final String resolvedName = formattedName;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder:
                                      (context) => MatchProfileScreen(
                                        matchId: match.id,
                                        otherUserId: match.otherUserId,
                                        otherUserName: resolvedName,
                                        matchedIntent: match.matchedIntent,
                                        matchType: match.matchType,
                                        eventId: match.eventId,
                                        eventName: match.eventName,
                                        eventLink: match.eventLink,
                                        createdAt: match.createdAt,
                                      ),
                                ),
                              );
                            },
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                Container(
                                  width: 70,
                                  height: 70,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.grey.shade200,
                                  ),
                                  child:
                                      profileImage != null
                                          ? ClipOval(
                                            child: SignedImage(
                                              source: profileImage,
                                              width: 70,
                                              height: 70,
                                              fit: BoxFit.cover,
                                              placeholder: const Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              ),
                                              errorWidget: const Icon(
                                                Icons.person,
                                                size: 35,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          )
                                          : const Icon(
                                            Icons.person,
                                            size: 35,
                                            color: Colors.grey,
                                          ),
                                ),
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4.0,
                                  ),
                                  child:
                                      ageString.isNotEmpty
                                          ? Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                formattedName,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                ),
                                                textAlign: TextAlign.center,
                                                textDirection:
                                                    RegExp(
                                                          r'[a-zA-Z]',
                                                        ).hasMatch(
                                                          formattedName,
                                                        )
                                                        ? ui.TextDirection.ltr
                                                        : (formattedName.isRtl()
                                                            ? ui
                                                                .TextDirection
                                                                .rtl
                                                            : ui
                                                                .TextDirection
                                                                .ltr),
                                              ),
                                              Text(
                                                '${l10n.getString('profileAgeLabel')}: $ageString',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                ),
                                                textAlign: TextAlign.center,
                                                textDirection:
                                                    RegExp(
                                                          r'[a-zA-Z]',
                                                        ).hasMatch(
                                                          '${l10n.getString('profileAgeLabel')}: $ageString',
                                                        )
                                                        ? ui.TextDirection.ltr
                                                        : ('${l10n.getString('profileAgeLabel')}: $ageString'
                                                                .isRtl()
                                                            ? ui
                                                                .TextDirection
                                                                .rtl
                                                            : ui
                                                                .TextDirection
                                                                .ltr),
                                              ),
                                              if (genderString.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  '${l10n.getString('profileGender')}: $genderString',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  textDirection:
                                                      RegExp(
                                                            r'[a-zA-Z]',
                                                          ).hasMatch(
                                                            '${l10n.getString('profileGender')}: $genderString',
                                                          )
                                                          ? ui.TextDirection.ltr
                                                          : ('${l10n.getString('profileGender')}: $genderString'
                                                                  .isRtl()
                                                              ? ui
                                                                  .TextDirection
                                                                  .rtl
                                                              : ui
                                                                  .TextDirection
                                                                  .ltr),
                                                ),
                                              ],
                                            ],
                                          )
                                          : Text(
                                            formattedName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                            textAlign: TextAlign.center,
                                            textDirection:
                                                RegExp(
                                                      r'[a-zA-Z]',
                                                    ).hasMatch(formattedName)
                                                    ? ui.TextDirection.ltr
                                                    : (formattedName.isRtl()
                                                        ? ui.TextDirection.rtl
                                                        : ui.TextDirection.ltr),
                                          ),
                                ),
                                const SizedBox(height: 4),
                                // Add proximity indication for proximity matches
                                if (match.matchType == 'proximity') ...[
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.location_on,
                                        size: 12,
                                        color: Colors.blue.shade600,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        l10n.getString('matchedByProximityLabel'),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.blue.shade600,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                ],
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4.0,
                                  ),
                                  child: Text(
                                    MatchReasonFormatter.formatMatchReasons(
                                      ref,
                                      match.matchedIntent,
                                      match.matchType,
                                      eventName: match.eventName,
                                    ),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4.0,
                                  ),
                                  child: Directionality(
                                  textDirection: l10n.textDirection,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Text(
                                        l10n.getString('matchedAt') != 'matchedAt' && l10n.getString('matchedAt').isNotEmpty ? l10n.getString('matchedAt') : 'Matched at',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        DateFormat('MMMM d, yyyy', l10n.currentLocale.languageCode).format(match.createdAt.toLocal()),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      Text(
                                        DateFormat('h:mm a', l10n.currentLocale.languageCode).format(match.createdAt.toLocal()),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }, // --- End Consumer builder
                    ); // --- End Consumer
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error:
                  (e, s) => Center(
                    child: Text("${l10n.getString('generalError')}: $e"),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
