// lib/screens/main_navigation_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/screens/home/home_screen.dart';
import 'package:matchme/screens/chats/chats_screen.dart';
import 'package:matchme/screens/matches/matches_screen.dart';
import 'package:matchme/screens/profile/profile_screen.dart';
import 'package:matchme/screens/events/events_screen.dart';
import 'package:matchme/widgets/match_notification_overlay.dart';
import 'package:matchme/widgets/custom_app_bar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/screens/settings/settings_screen.dart';
import 'package:matchme/screens/settings/invisibility_rules_screen.dart';
import 'package:matchme/services/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final supabase = Supabase.instance.client;

class MainNavigationScreen extends ConsumerStatefulWidget {
  final int initialIndex;
  const MainNavigationScreen({super.key, this.initialIndex = 0});
  @override
  ConsumerState<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> with WidgetsBindingObserver {
  Timer? _activityTimer;
  final GlobalKey<NavigatorState> _eventsNavigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(isVisibleProvider.notifier).ensureServiceStarted();
        _updateUserActivity();
        ref.read(navigationIndexProvider.notifier).setIndex(widget.initialIndex);

        // Start background service for authenticated user
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null) {
          _saveLoginState(currentUserId);
          BackgroundService.start();
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activityTimer?.cancel();
    super.dispose();
  }

  Future<void> _updateUserActivity() async {
    final user = supabase.auth.currentUser;
    if (user != null) {
      try {
        debugPrint('Updating user activity from main navigation for ${user.id}');
        await supabase.rpc('update_user_activity', params: {'p_user_id': user.id});
        debugPrint('User activity updated from main navigation');
      } catch (e) {
        debugPrint('Error updating user activity from main navigation: $e');
      }
    }
  }

  Future<void> _saveLoginState(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('was_logged_in', true);
      await prefs.setString('user_id', userId);
      // Store Supabase config for background service
      // These are set during app initialization in main.dart
      final supabaseUrl = prefs.getString('supabase_url') ?? 'https://your-project.supabase.co';
      final supabaseKey = prefs.getString('supabase_key') ?? 'your-anon-key';
      await prefs.setString('stored_supabase_url', supabaseUrl);
      await prefs.setString('stored_supabase_key', supabaseKey);
    } catch (e) {
      debugPrint('Error saving login state: $e');
    }
  }

  Future<void> _clearLoginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('was_logged_in');
      await prefs.remove('user_id');
      await prefs.remove('supabase_url');
      await prefs.remove('supabase_key');
    } catch (e) {
      debugPrint('Error clearing login state: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final currentIndex = ref.watch(navigationIndexProvider);
    final userId = supabase.auth.currentUser?.id;
    // Profile tab is accessible from the bottom navigation; no need to show name in the top bar.
    ref.watch(currentLocationProvider);

    final isOnline = ref.watch(connectivityProvider).value ?? true;
    final isVisible = ref.watch(isVisibleProvider);
    final rules = ref.watch(invisibilityRulesProvider);
    final isLoaded = rules.isLoaded;
    final currentInvisibilityReasons = ref.watch(currentInvisibilityReasonsProvider);
    final currentInvisibilityReason = ref.watch(currentInvisibilityReasonProvider);
    final hasActiveRules = currentInvisibilityReasons.isNotEmpty;
    final currentLocation = ref.watch(currentLocationProvider);
    final hasLocationRules = rules.locationRules.isNotEmpty;
    final locationLoading = currentLocation == null && hasLocationRules;

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 400;
    final isVerySmallScreen = screenWidth < 350;
    final iconPadding = isSmallScreen ? 6.0 : 8.0;

    final List<Widget> screens = [
      const HomeScreen(),
      const MatchesScreen(),
      const ChatsScreen(),
      EventsTab(navigatorKey: _eventsNavigatorKey),
      const ProfileScreen(),
    ];

    final List<String> appBarTitleKeys = ['navHome', 'navMatches', 'navChats', 'navEvents', 'navProfile'];
    final safeIndex = currentIndex < 0 ? 0 : (currentIndex >= appBarTitleKeys.length ? appBarTitleKeys.length - 1 : currentIndex);
    final screenName = l10n.getString(appBarTitleKeys[safeIndex]);

    Widget? centerWidget;
    if (isLoaded) {
      if (hasActiveRules || locationLoading) {
        final reasonText = locationLoading
            ? '${l10n.getString('invisibleDueTo')} ${l10n.getString('settingsLocationRules').toLowerCase()}'
            : currentInvisibilityReason;
        centerWidget = _buildVisibilityWidget(
          context,
          l10n,
          hasActiveRules || locationLoading,
          reasonText,
          isOnline,
          isVisible,
          isLoaded,
          () {
            final activeRuleIds = ref.watch(activeRuleIdsProvider);
            final firstActiveRuleId = activeRuleIds.keys.isNotEmpty ? activeRuleIds.keys.first : null;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => InvisibilityRulesScreen(
                  highlightRuleId: firstActiveRuleId,
                ),
              ),
            );
          },
          null,
          isVerySmallScreen,
          isSmallScreen,
        );
      } else {
        String text;
        Color color;
        Widget? switchWidget;

        if (!isOnline) {
          text = isVerySmallScreen ? l10n.getString('generalOffShort') : (isSmallScreen ? l10n.getString('generalOffline') : l10n.getString('youAreOffline'));
          color = Theme.of(context).colorScheme.error;
          switchWidget = null;
          centerWidget = Container(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            decoration: BoxDecoration(
              color: color.withAlpha((0.1 * 255).round()),
              borderRadius: BorderRadius.circular(16.0),
              border: Border.all(
                color: color.withAlpha((0.2 * 255).round()),
                width: 1,
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        } else {
          if (isVisible) {
            text = isVerySmallScreen ? l10n.getString('generalOnShort') : (isSmallScreen ? l10n.getString('homeOnline') : l10n.getString('youAreCurrentlyOnlineAndVisible'));
            final semantic = Theme.of(context).extension<SemanticColors>();
            final Color color = semantic?.success ?? const Color(0xFF10B981);
            final Color bg = semantic?.successContainer ?? const Color(0xFFDCFCE7);
            switchWidget = Switch(
              value: isVisible,
              onChanged: (value) {
                ref.read(isVisibleProvider.notifier).setVisibility(value);
              },
              activeThumbColor: color,
              inactiveThumbColor: Theme.of(context).colorScheme.error,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
            centerWidget = Container(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16.0),
                border: Border.all(
                  color: color.withAlpha((0.2 * 255).round()),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  switchWidget,
                ],
              ),
            );
          } else {
            text = isVerySmallScreen
                ? l10n.getString('generalOnInvisibleShort')
                : (isSmallScreen
                    ? '${l10n.getString('homeOnline')} ${l10n.getString('homeStatusInvisible')}'
                    : '${l10n.getString('youAreCurrentlyOnline')} ${l10n.getString('andInvisible')}');
            color = Theme.of(context).colorScheme.error;
            switchWidget = Switch(
              value: isVisible,
              onChanged: (value) {
                ref.read(isVisibleProvider.notifier).setVisibility(value);
              },
              activeThumbColor: Theme.of(context).colorScheme.secondary,
              inactiveThumbColor: Theme.of(context).colorScheme.error,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
            centerWidget = Container(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
              decoration: BoxDecoration(
                color: color.withAlpha((0.1 * 255).round()),
                borderRadius: BorderRadius.circular(16.0),
                border: Border.all(
                  color: color.withAlpha((0.2 * 255).round()),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  switchWidget,
                ],
              ),
            );
          }
        }
      }
    }

    final List<Widget> actions = [
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: const Color.fromARGB(25, 99, 102, 241),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.calendar_today_outlined, color: Theme.of(context).colorScheme.primary),
        ),
        tooltip: l10n.getString('eventsScreenTitle'),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const EventsScreen()),
          );
        },
      ),
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.settings_outlined, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7)),
        ),
        tooltip: l10n.getString('settingsTitle'),
        onPressed: () {
          if (userId == null) return;
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const SettingsScreen()),
          );
        },
      ),
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error.withValues(alpha:0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              l10n.textDirection == TextDirection.rtl ? -1.0 : 1.0,
              1.0,
              1.0,
            ),
            child: Icon(Icons.logout_rounded, color: Theme.of(context).colorScheme.error),
          ),
        ),
        tooltip: l10n.getString('authLogout'),
        onPressed: () async {
          // Perform logout - the auth state listener in visibility_provider.dart
          // will automatically handle setting visibility to false after sign out completes.
          // This ensures the toggle is not touched during the logout process.
          try {
            ref.read(globalSyncManagerProvider).dispose();
            // BackgroundService.stop() is called automatically by auth state listener
            await _clearLoginState();

            // Revoke all active sessions for this user (best-effort)
            try {
              final user = supabase.auth.currentUser;
              if (user != null) {
                await supabase.rpc('revoke_all_user_sessions', params: {'p_user_id': user.id});
              }
            } catch (e) {
              debugPrint('revoke_all_user_sessions failed: $e');
            }

            await supabase.auth.signOut();
          } catch (e) {
            debugPrint('Logout error: $e');
            ref.read(globalSyncManagerProvider).dispose();
            await BackgroundService.stop();
            await _clearLoginState();
          }
        },
      ),
    ];

    return Stack(
      children: [
        Scaffold(
          appBar: buildCustomAppBar(context, ref, l10n, screenName, actions, centerWidget: centerWidget),
          body: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: safeIndex,
                  children: screens,
                ),
              ),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: safeIndex,
            onTap: (index) {
              ref.read(navigationIndexProvider.notifier).setIndex(index);
            },
            type: BottomNavigationBarType.fixed,
            selectedItemColor: Theme.of(context).colorScheme.primary,
            unselectedItemColor: Colors.grey,
            showUnselectedLabels: true,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.home_outlined),
                activeIcon: const Icon(Icons.home),
                label: l10n.getString('navHome'),
              ),
              BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.favorite_border, ref.watch(unreadMatchCountProvider)),
                activeIcon: _buildIconWithBadge(Icons.favorite, ref.watch(unreadMatchCountProvider)),
                label: l10n.getString('navMatches'),
              ),
              BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.chat_bubble_outline, ref.watch(totalUnreadChatCountProvider)),
                activeIcon: _buildIconWithBadge(Icons.chat_bubble, ref.watch(totalUnreadChatCountProvider)),
                label: l10n.getString('navChats'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.calendar_today_outlined),
                activeIcon: const Icon(Icons.calendar_today),
                label: l10n.getString('navEvents'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.person_outline),
                activeIcon: const Icon(Icons.person),
                label: l10n.getString('navProfile'),
              ),
            ],
          ),
        ),
        const MatchNotificationOverlay(),
      ],
    );
  }

  Widget _buildVisibilityWidget(BuildContext context, LocalizationState l10n, bool hasActiveRules, String? currentInvisibilityReason, bool isOnline, bool isVisible, bool isLoaded, VoidCallback? onTap, ValueChanged<bool>? onVisibilityChanged, bool isVerySmallScreen, bool isSmallScreen) {
    if (!isLoaded) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: Colors.grey.withAlpha((0.1 * 255).round()),
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: Colors.grey.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Text(
          l10n.getString('generalLoadingDots'),
          style: TextStyle(
            color: Colors.grey,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    Widget child;
    if (!isOnline) {
      // Offline: "You are Offline" all red
      final color = Theme.of(context).colorScheme.error;
      child = Container(
        padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: color.withAlpha((0.1 * 255).round()),
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: color.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Text(
          l10n.getString('youAreOffline'),
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    } else if (hasActiveRules) {
      // Online and Invisible due to rules: yellow, clickable
      final color = Theme.of(context).colorScheme.tertiary; // yellow
      final reasonText = currentInvisibilityReason!.replaceFirst(l10n.getString('youAreInvisibleDueTo'), l10n.getString('invisibleDueTo'));
      child = InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
          decoration: BoxDecoration(
            color: color.withAlpha((0.1 * 255).round()),
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: color.withAlpha((0.2 * 255).round()),
              width: 1,
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.visibility_off,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  l10n.getString('youAreCurrentlyOnlineAnd').replaceAll('{reason}', reasonText),
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Online, manual visibility
      if (isVisible) {
        // Online and Visible: semantic success color, toggle
        final semantic = Theme.of(context).extension<SemanticColors>();
        // Use the theme extension first; if it's missing, fall back to a known green
        final Color color = semantic?.success ?? const Color(0xFF10B981);
        final Color bg = semantic?.successContainer ?? const Color(0xFFDCFCE7);
        child = Container(
          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: color.withAlpha((0.2 * 255).round()),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  l10n.getString('youAreCurrentlyOnlineAndVisible'),
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Switch(
                value: isVisible,
                onChanged: (value) {
                  // ref.read(isVisibleProvider.notifier).setVisibility(value);
                },
                activeThumbColor: color,
                inactiveTrackColor: Colors.grey.shade300,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        );
      } else {
        // Online and Invisible: Online green, Invisible red, toggle
        final semantic = Theme.of(context).extension<SemanticColors>();
        final Color onlineColor = semantic?.success ?? Theme.of(context).colorScheme.secondary;
        final Color onlineBg = semantic?.successContainer ?? onlineColor.withAlpha((0.1 * 255).round());
        child = Container(
          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
          decoration: BoxDecoration(
            color: onlineBg, // green background
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: onlineColor.withAlpha((0.2 * 255).round()),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: l10n.getString('youAreCurrentlyOnline'),
                        style: TextStyle(
                          color: onlineColor, // green
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      TextSpan(
                        text: l10n.getString('andInvisible'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error, // red
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Switch(
                value: isVisible,
                onChanged: (value) {
                  // ref.read(isVisibleProvider.notifier).setVisibility(value);
                },
                activeThumbColor: onlineColor,
                inactiveTrackColor: Colors.grey.shade300,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        );
      }
    }

    return child;
  }

  Widget _buildIconWithBadge(IconData icon, int count) {
    return Stack(
      children: [
        Icon(icon),
        if (count > 0)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(
                minWidth: 16,
                minHeight: 16,
              ),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onError,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
