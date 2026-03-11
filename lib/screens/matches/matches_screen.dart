// lib/screens/matches/matches_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

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
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.favorite_border,
                          size: 64,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.getString('homeNoMatches'),
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return MatchBoxList(
                  matches: matches,
                  showTitle: false,
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
