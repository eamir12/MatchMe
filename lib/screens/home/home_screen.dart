// lib/screens/home/home_screen.dart
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(isVisibleProvider.notifier).ensureServiceStarted();
        // Update user activity when home screen loads
        _updateUserActivity();
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _updateUserActivity() async {
    final user = supabase.auth.currentUser;
    if (user != null) {
      try {
        debugPrint('Updating user activity from home screen for ${user.id}');
        await supabase.rpc('update_user_activity', params: {'p_user_id': user.id});
        debugPrint('User activity updated from home screen');
      } catch (e) {
        debugPrint('Error updating user activity from home screen: $e');
      }
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              child: Text(
                ref.watch(localizationProvider).getString('homeSeeAll'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator() =>
      const Center(heightFactor: 2, child: CircularProgressIndicator());
  Widget _buildErrorWidget(String error) => Center(
    heightFactor: 2,
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Text(
        "Error:\n$error",
        style: const TextStyle(color: Colors.red),
        textAlign: TextAlign.center,
      ),
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

  // Helper to format name from a profile
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

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isVisible = ref.watch(isVisibleProvider);
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      return Scaffold(
        body: Center(child: Text(l10n.getString('generalError'))),
      );
    }

    // Use helper (not ref.watch) — helper itself will watch the connectivityProvider safely.
    final isOnline = connectivityProviderChecker(ref) ?? true;

    final profileState = ref.watch(userProfileProvider(userId));
    final dashboardStats = ref.watch(dashboardStatsProvider);
    final recentMatchesAsync = ref.watch(recentMatchesProvider(userId));
    final recentChatsAsync = ref.watch(recentChatsProvider(userId));
    final List<ChatModel> currentChats = recentChatsAsync.asData?.value ?? [];
    final Set<String> matchIdsWithChats =
        currentChats.map((c) => c.matchId).toSet();
    final matches = recentMatchesAsync.asData?.value ?? [];

    // locale string for DateFormat (use app's current locale)
    final localeString = l10n.currentLocale.toString();

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(profileSyncProvider).syncProfile(userId);
        ref.invalidate(recentMatchesProvider(userId));
        ref.invalidate(recentChatsProvider(userId));
      },
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              bottom: 10.0,
            ),
            child: profileState.when(
                data:
                    (profile) {
                      final greeting = l10n.getString('homeWelcome');
                      final userName = profile?.name.split(' ').first ?? 'User';
                      // Remove trailing punctuation from greeting and ensure comma
                      final cleanGreeting = greeting.replaceAll(RegExp(r'[!,]*$'), '').trim();
                      final welcomeText = '$cleanGreeting, $userName!';
                      return Text(
                        welcomeText,
                        style: Theme.of(context).textTheme.headlineSmall,
                      );
                    },
                loading: () => const SizedBox.shrink(),
                error: (e, s) => const SizedBox.shrink(),
              ),
            ),

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
                      data:
                          (stats) => _buildStatCard(
                            context,
                            Icons.radar_outlined,
                            "${stats['nearby'] ?? 0}",
                            l10n.getString('homeNearby'),
                          ),
                      loading:
                          () => _buildStatCard(
                            context,
                            Icons.radar_outlined,
                            "...",
                            l10n.getString('homeNearby'),
                          ),
                      error:
                          (e, s) => _buildStatCard(
                            context,
                            Icons.radar_outlined,
                            "0",
                            l10n.getString('homeNearby'),
                          ),
                    ),
                  if (isOnline)
                    dashboardStats.when(
                      data:
                          (stats) => _buildStatCard(
                            context,
                            Icons.people_outline,
                            "${stats['online'] ?? 0}",
                            l10n.getString('homeOnline'),
                          ),
                      loading:
                          () => _buildStatCard(
                            context,
                            Icons.people_outline,
                            "...",
                            l10n.getString('homeOnline'),
                          ),
                      error:
                          (e, s) => _buildStatCard(
                            context,
                            Icons.people_outline,
                            "0",
                            l10n.getString('homeOnline'),
                          ),
                    ),
                  profileState.when(
                    data: (p) {
                      final tierKey =
                          'tier${p?.subscriptionTier.capitalize() ?? 'Free'}';
                      return _buildStatCard(
                        context,
                        Icons.star_outline,
                        l10n.getString(tierKey),
                        l10n.getString('homeTier'),
                      );
                    },
                    loading:
                        () => _buildStatCard(
                          context,
                          Icons.star_border_outlined,
                          "...",
                          l10n.getString('homeTier'),
                        ),
                    error:
                        (e, s) => _buildStatCard(
                          context,
                          Icons.error_outline,
                          "Error",
                          l10n.getString('homeTier'),
                        ),
                  ),
                ],
              ),
            ),
            _buildSectionTitle(
              context,
              l10n.getString('homeRecentMatches'),
              onSeeAll: () {
                ref.read(navigationIndexProvider.notifier).setIndex(1);
              },
            ),
            recentMatchesAsync.when(
              data: (matches) {
                if (matches.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: _buildEmptyList(l10n.getString('homeNoMatches')),
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Row(
                    children: matches
                        .map(
                          (match) => _buildMatchCard(
                            context,
                            match,
                            matchIdsWithChats,
                          ),
                        )
                        .toList(),
                  ),
                );
              },
              loading: _buildLoadingIndicator,
              error: (e, s) => _buildErrorWidget(e.toString()),
            ),
            const SizedBox(height: 10),
            _buildSectionTitle(
              context,
              l10n.getString('homeRecentChats'),
              onSeeAll: () {
                ref.read(navigationIndexProvider.notifier).setIndex(2);
              },
            ),
            recentChatsAsync.when(
              data: (chats) {
                if (chats.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: _buildEmptyList(l10n.getString('homeNoChats')),
                  );
                }
                return Column(
                  children:
                      chats
                          .map(
                            (chat) =>
                                _buildChatListItem(context, chat, matches, localeString),
                          )
                          .toList(),
                );
              },
              loading: _buildLoadingIndicator,
              error: (e, s) => _buildErrorWidget(e.toString()),
            ),
            const SizedBox(height: 20),
          ],
        ),
      );
    }

  Widget _buildStatCard(
    BuildContext context,
    IconData icon,
    String value,
    String label,
  ) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 30, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  // --- 1. UPDATED MATCH CARD ---
  Widget _buildMatchCard(
    BuildContext context,
    MatchModel match,
    Set<String> matchIdsWithChats,
  ) {
    final l10n = ref.watch(localizationProvider);
    // We can use 'ref' here because this method is part of ConsumerState
    final otherProfileAsync = ref.watch(userProfileProvider(match.otherUserId));
    final currentProfileAsync = ref.watch(userProfileProvider(supabase.auth.currentUser!.id));

    final String formattedName = otherProfileAsync.when(
      data: (profile) => profile?.name.formatAsFirstNameLastInitial() ?? l10n.getString('generalUnknown'),
      loading: () => l10n.getString('generalLoading'),
      error: (e, s) => l10n.getString('generalError'),
    );

    final String ageGender = otherProfileAsync.when(
      data: (profile) {
        final age = profile?.dateOfBirth != null
            ? calculateAgeFromDate(profile!.dateOfBirth!)
            : null;
        final gender = profile?.gender;
        final parts = <String>[];
        if (age != null) parts.add('${l10n.getString('profileAgeLabel')}: $age');
        if (gender != null && gender.isNotEmpty) {
          final localizedGender = _getGenderLabel(gender, ref, l10n);
          parts.add('${l10n.getString('profileGender')}: $localizedGender');
        }
        return parts.join('\n');
      },
      loading: () => "",
      error: (e, s) => "",
    );

    final String matchReason = _computeMatchReason(match, otherProfileAsync.value, currentProfileAsync.value, l10n);

    return SizedBox(
      width: 200,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 4.0),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // Always open the matched user's profile for the matched intent.
            // Use the reactive formattedName (may be "Loading..." if profile not yet available).
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
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Builder(
              builder: (context) {
                final List<Widget> children = [
                  otherProfileAsync.when(
                    data: (profile) {
                      if (profile?.photos.isNotEmpty == true) {
                        return ClipOval(
                          child: SignedImage(
                            source: profile!.photos[0],
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: Builder(builder: (ctx) {
                              final colors = Theme.of(ctx).colorScheme;
                              return Container(
                                width: 40,
                                height: 40,
                                color: colors.primary.withValues(alpha: 0.08),
                                child: Icon(Icons.person, size: 24, color: colors.primary),
                              );
                            }),
                            errorWidget: Builder(builder: (ctx) {
                              final colors = Theme.of(ctx).colorScheme;
                              return Container(
                                width: 40,
                                height: 40,
                                color: colors.primary.withValues(alpha: 0.08),
                                child: Icon(Icons.person, size: 24, color: colors.primary),
                              );
                            }),
                          ),
                        );
                      } else {
                        return Builder(builder: (ctx) {
                          final colors = Theme.of(ctx).colorScheme;
                          return CircleAvatar(
                            radius: 20,
                            backgroundColor: colors.primary.withValues(alpha: 0.08),
                            child: Icon(Icons.person, size: 24, color: colors.primary),
                          );
                        });
                      }
                    },
                    loading: () => Builder(builder: (ctx) { final colors = Theme.of(ctx).colorScheme; return CircleAvatar(radius: 20, backgroundColor: colors.primary.withValues(alpha:0.08), child: Icon(Icons.person, size:24, color: colors.primary)); }),
                    error: (e, s) => Builder(builder: (ctx) { final colors = Theme.of(ctx).colorScheme; return CircleAvatar(radius: 20, backgroundColor: colors.primary.withValues(alpha:0.08), child: Icon(Icons.person, size:24, color: colors.primary)); }),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formattedName, // Name only
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    textDirection: RegExp(r'[a-zA-Z]').hasMatch(formattedName)
                        ? ui.TextDirection.ltr
                        : (formattedName.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr),
                  ),
                ];

                if (ageGender.isNotEmpty) {
                  children.add(const SizedBox(height: 2));
                  children.add(Text(
                    ageGender,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7)),
                  ));
                }

                // Add proximity indication for proximity matches
                if (match.matchType == 'proximity') {
                  children.add(const SizedBox(height: 2));
                  children.add(Row(
                    mainAxisSize: MainAxisSize.min,
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
                  ));
                }

                children.add(const SizedBox(height: 2));
                children.add(Text(
                  matchReason,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.6)),
                ));

                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: children,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // --- 2. UPDATED CHAT LIST ITEM ---
  Widget _buildChatListItem(
    BuildContext context,
    ChatModel chat,
    List<MatchModel> matches,
    String localeString,
  ) {
    final l10n = ref.watch(localizationProvider);
    // We can use 'ref' here because this method is part of ConsumerState
    final otherProfileAsync = ref.watch(userProfileProvider(chat.otherUserId));

    final String formattedName = otherProfileAsync.when(
      data: (profile) => profile?.name.formatAsFirstNameLastInitial() ?? l10n.getString('generalUnknown'),
      loading: () => l10n.getString('generalLoading'),
      error: (e, s) => l10n.getString('generalError'),
    );

    final String ageGender = otherProfileAsync.when(
      data: (profile) {
        final age = profile?.dateOfBirth != null
            ? calculateAgeFromDate(profile!.dateOfBirth!)
            : null;
        final gender = profile?.gender;
        final parts = <String>[];
        if (age != null) parts.add('${l10n.getString('profileAgeLabel')}: $age');
        if (gender != null && gender.isNotEmpty) {
          final localizedGender = _getGenderLabel(gender, ref, l10n);
          parts.add('${l10n.getString('profileGender')}: $localizedGender');
        }
        return parts.join(', ');
      },
      loading: () => "",
      error: (e, s) => "",
    );

    return ListTile(
      leading: otherProfileAsync.when(
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.onSurface),
                ),
                errorWidget: Container(
                  width: 40,
                  height: 40,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(Icons.person, size: 24, color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            );
          } else {
            return CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(Icons.person, color: Theme.of(context).colorScheme.onSurface),
            );
          }
        },
        loading: () => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.person, color: Theme.of(context).colorScheme.onSurface),
        ),
        error: (e, s) => const CircleAvatar(
          backgroundColor: Colors.grey,
          child: Icon(Icons.person, color: Colors.white),
        ),
      ),
      title: Text(
        formattedName,
        textDirection: ref.watch(localizationProvider).textDirection,
        textAlign: ref.watch(localizationProvider).textDirection == ui.TextDirection.rtl
            ? TextAlign.right
            : TextAlign.left,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ageGender.isNotEmpty)
            Text(ageGender, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7))),
          Text(
            chat.lastMessage, 
            textDirection: RegExp(r'[a-zA-Z]').hasMatch(chat.lastMessage)
                ? ui.TextDirection.ltr
                : (chat.lastMessage.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatTimeOfDateTimeWithPrefs(context, ref, l10n, chat.lastMessageAt.toLocal()),
            style: TextStyle(fontSize: 12, color: Theme.of(context).disabledColor),
          ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 4),
            CircleAvatar(
              radius: 10,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                chat.unreadCount.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 10),
              ),
            ),
          ] else
            const SizedBox(height: 24),
        ],
      ),
      onTap: () {
        // Don't navigate if the profile isn't loaded yet
        final otherProfile = otherProfileAsync.value;
        if (otherProfile == null) return;

        final String resolvedName = otherProfile.name.formatAsFirstNameLastInitial();

        Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (context) => ChatScreen(
                  matchId: chat.matchId,
                  otherUserName: resolvedName,
                  otherUserId: chat.otherUserId,
                ),
          ),
        ).then((_) {
          ref.invalidate(recentChatsProvider(supabase.auth.currentUser!.id));
        });
      },
    );
  }

  // Helper to compute intersection of two lists
  List<String> _intersectLists(List<String> a, List<String> b) {
    final setA = a.toSet();
    final setB = b.toSet();
    return setA.intersection(setB).toList();
  }

  // Helper to compute match reason based on profiles
  String _computeMatchReason(MatchModel match, UserProfile? otherProfile, UserProfile? currentProfile, LocalizationState l10n) {
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
}

/// Helper to safely read connectivity provider value (used in build)
bool? connectivityProviderChecker(WidgetRef ref) {
  try {
    return ref.watch(connectivityProvider).value;
  } catch (_) {
    return true;
  }
}
