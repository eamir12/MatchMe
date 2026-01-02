// lib/screens/chats/chats_screen.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/utils/time_format_utils.dart';

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
                  Text(
                    l10n.getString('chatsStartConversation'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: chats.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final ChatModel chat = chats[index];

            // Resolve other user's display name and profile image reactively via profile provider
            final otherProfileAsync = ref.watch(
              userProfileProvider(chat.otherUserId),
            );

            final profileData = otherProfileAsync.value;
            final otherName =
                profileData?.name.formatAsFirstNameLastInitial() ?? chat.otherUserName;
            final String? profileImage =
                profileData?.photos.isNotEmpty == true
                    ? profileData!.photos[0]
                    : null;

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).shadowColor.withValues(alpha:0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: Border.all(
                  color: chat.unreadCount > 0 ? Theme.of(context).colorScheme.primary.withValues(alpha:0.2) : Colors.transparent,
                  width: 1,
                ),
              ),
              child: ListTile(
                key: ValueKey('chat_${chat.matchId}'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                leading: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () {
                    // Also allow tapping avatar to open profile
                    _openMatchProfileFromRow(context, ref, chat, otherName);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.secondary,
                        ],
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      child:
                          profileImage != null
                              ? ClipOval(
                                child: SignedImage(
                                  source: profileImage,
                                  width: 36,
                                  height: 36,
                                  fit: BoxFit.cover,
                                  placeholder: const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1,
                                    ),
                                  ),
                                  errorWidget: Icon(
                                    Icons.person,
                                    color: Theme.of(context).colorScheme.primary,
                                    size: 20,
                                  ),
                                ),
                              )
                              : Icon(
                                Icons.person,
                                color: Theme.of(context).colorScheme.primary,
                                size: 20,
                              ),
                    ),
                  ),
                ),
                // Title: name + small "view profile" affordance
                title: Row(
                  children: [
                    // Name
                    Expanded(
                      child: Text(
                        otherName,
                        style: TextStyle(
                          fontWeight: chat.unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        textAlign:
                            ref
                                        .watch(localizationProvider)
                                        .textDirection ==
                                    ui.TextDirection.rtl
                                ? TextAlign.right
                                : TextAlign.left,
                        textDirection: ref.watch(localizationProvider).textDirection,
                      ),
                    ),
                    // Small profile button between name and trailing/time
                    IconButton(
                      icon: Icon(
                        Icons.person_outline,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.6),
                      ),
                      tooltip: l10n.getString('profileTitle'),
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      constraints: const BoxConstraints(),
                      onPressed:
                          () => _openMatchProfileFromRow(
                            context,
                            ref,
                            chat,
                            otherName,
                          ),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    chat.lastMessage,
                    textDirection: RegExp(r'[a-zA-Z]').hasMatch(chat.lastMessage)
                        ? ui.TextDirection.ltr
                        : (chat.lastMessage.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr),
                    textAlign:
                        ref.watch(localizationProvider).textDirection == ui.TextDirection.rtl
                            ? TextAlign.right
                            : TextAlign.left,
                    style: TextStyle(
                      fontSize: 14,
                      color:
                          chat.unreadCount > 0
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                      fontWeight:
                          chat.unreadCount > 0
                              ? FontWeight.w500
                              : FontWeight.normal,
                    ),
                  ),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatTimeOfDateTimeWithPrefs(context, ref, l10n, chat.lastMessageAt.toLocal()),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).disabledColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (chat.unreadCount > 0) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          chat.unreadCount.toString(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ] else
                      const SizedBox(height: 18),
                  ],
                ),
                onTap: () {
                  // Resolve display name synchronously if available
                  final resolvedName =
                      otherProfileAsync.value?.name.formatAsFirstNameLastInitial() ??
                      chat.otherUserName;
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
                    if (userId != null) {
                      ref.invalidate(recentChatsProvider(userId));
                    }
                  });
                },
              ),
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

  void _openMatchProfileFromRow(
    BuildContext context,
    WidgetRef ref,
    ChatModel chat,
    String otherName,
  ) {
    // Find the matchedIntent for this matchId if available from recent matches.
    // Use read() so tapping the button doesn't create a rebuild dependency for the whole list.
    final String? currentUserId = supabase.auth.currentUser?.id;
    final matches =
        (currentUserId != null)
            ? ref.read(recentMatchesProvider(currentUserId)).value
            : null;
    String matchedIntent = '';

    if (matches != null) {
      MatchModel? found;
      for (final m in matches) {
        if (m.id == chat.matchId) {
          found = m;
          break;
        }
      }
      if (found != null) matchedIntent = found.matchedIntent;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => MatchProfileScreen(
              matchId: chat.matchId,
              otherUserId: chat.otherUserId,
              otherUserName: otherName,
              matchedIntent: matchedIntent,
            ),
      ),
    );
  }
}
