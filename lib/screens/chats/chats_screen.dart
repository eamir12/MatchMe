// lib/screens/chats/chats_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

/// ChatsScreen
/// - By default this widget does NOT render its own AppBar (so it can be used inside
///   the app's top-level Scaffold in MainNavigationScreen without producing duplicate bars).
/// - Set [showAppBar] to true if you want a self-contained Scaffold + AppBar (e.g., when
///   navigating to ChatsScreen directly).
class ChatsScreen extends ConsumerWidget {
  final bool showAppBar;
  const ChatsScreen({super.key, this.showAppBar = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final userId = supabase.auth.currentUser?.id;

    // recent chats stream
    final recentChatsAsync =
        (userId != null)
            ? ref.watch(recentChatsProvider(userId))
            : const AsyncValue.loading();

    final content = recentChatsAsync.when(
      data: (chats) {
        if (chats.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                          Theme.of(context).colorScheme.secondary.withValues(alpha:0.1),
                        ],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.chat_bubble_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.getString('homeNoChats'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (ctx) {
                      final currentGender = userId != null ? ref.watch(userProfileProvider(userId)).asData?.value?.gender : null;
                      final startText = l10n.getString('chatsStartConversation', gender: currentGender);
                      return Text(
                        startText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: chats.length,
          itemBuilder: (context, index) {
            return ChatListItem(
              chat: chats[index],
              showUnreadBorder: true,
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, s) => Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${l10n.getString('generalError')}: $e',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (userId != null) {
                        ref.invalidate(recentChatsProvider(userId));
                      }
                    },
                    child: Text(l10n.getString('generalRetry')),
                  ),
                ],
              ),
            ),
          ),
    );

    // If caller asked this widget to be self-contained, render a Scaffold with AppBar,
    // otherwise render the content only (to avoid duplicate app bars when shown inside MainNavigationScreen).
    if (showAppBar) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.getString('chatsScreenTitle'))),
        body: content,
      );
    }
    return content;
  }

}
