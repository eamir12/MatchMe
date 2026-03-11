// lib/screens/home/home_screen.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/utils/greeting_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/screens/nearby/nearby_map_screen.dart';
import 'package:matchme/screens/paywall/paywall_screen.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:matchme/widgets/chat_list_item.dart';
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
    developer.log('🏠 HomeScreen init', name: 'MatchMeTrace');
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

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isVisible = ref.watch(isVisibleProvider);
    final remaining = ref.watch(subscriptionTimeRemainingProvider);
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      return Scaffold(
        body: Center(child: Text(l10n.getString('generalError'))),
      );
    }

    // Use helper (not ref.watch) — helper itself will watch the connectivityProvider safely.
    final isOnline = connectivityProviderChecker(ref) ?? true;
    developer.log('🏠 HomeScreen build: user=$userId, isVisible=$isVisible, isOnline=$isOnline', name: 'MatchMeTrace');

    ref.watch(matchNotificationProvider);

    final profileState = ref.watch(userProfileProvider(userId));
    final dashboardStats = ref.watch(dashboardStatsProvider);
    final recentMatchesAsync = ref.watch(recentMatchesProvider(userId));
    final recentChatsAsync = ref.watch(recentChatsProvider(userId));

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
              data: (profile) {
                final userName = profile?.name.split(' ').first ?? 'User';
                // Compute localized, gender-aware greeting based on time of day
                final greeting = localizedGreeting(l10n, DateTime.now(), gender: profile?.gender);
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
                    data: (stats) => _buildStatCard(
                      context,
                      Icons.radar_outlined,
                      "${stats['nearby'] ?? 0}",
                      l10n.getString('homeNearby'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const NearbyMapScreen()),
                        );
                      },
                    ),
                    loading: () => _buildStatCard(
                      context,
                      Icons.radar_outlined,
                      "...",
                      l10n.getString('homeNearby'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const NearbyMapScreen()),
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
                          MaterialPageRoute(builder: (_) => const NearbyMapScreen()),
                        );
                      },
                    ),
                  ),
                if (isOnline)
                  dashboardStats.when(
                    data: (stats) => _buildStatCard(
                      context,
                      Icons.people_outline,
                      "${stats['online'] ?? 0}",
                      l10n.getString('homeOnline'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OnlineWorldMapScreen()),
                        );
                      },
                    ),
                    loading: () => _buildStatCard(
                      context,
                      Icons.people_outline,
                      "...",
                      l10n.getString('homeOnline'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OnlineWorldMapScreen()),
                        );
                      },
                    ),
                    error: (e, s) => _buildStatCard(
                      context,
                      Icons.people_outline,
                      "0",
                      l10n.getString('homeOnline'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OnlineWorldMapScreen()),
                        );
                      },
                    ),
                  ),
                profileState.when(
                  data: (p) {
                    final tierKey =
                        'tier${p?.subscriptionTier.capitalize() ?? 'Free'}';
                    final remainingText =
                        (remaining != null && remaining > Duration.zero)
                            ? '${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
                            : null;
                    return _buildStatCard(
                      context,
                      Icons.star_outline,
                      l10n.getString(tierKey),
                      l10n.getString('homeTier'),
                      subValue: remainingText,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const PaywallScreen()),
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
                    "Error",
                    l10n.getString('homeTier'),
                  ),
                ),
              ],
            ),
          ),
          recentMatchesAsync.when(
            data: (matches) {
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
                  if (matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20.0),
                      child: _buildEmptyList(l10n.getString('homeNoMatches')),
                    )
                  else
                    MatchBoxList(
                      matches: matches,
                      showTitle: false,
                    ),
                ],
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
                children: chats
                    .map(
                      (chat) => ChatListItem(
                        chat: chat,
                        showUnreadBorder: true,
                      ),
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
    String label, {
    String? subValue,
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 30, color: Theme.of(context).colorScheme.secondary),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            if (subValue != null) ...[
              const SizedBox(height: 2),
              Text(
                subValue,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
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
