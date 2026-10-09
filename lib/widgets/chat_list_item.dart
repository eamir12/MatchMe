// lib/widgets/chat_list_item.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/typing_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/multi_select.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

final supabase = Supabase.instance.client;

/// Unified chat list item used by Home recent chats and the Chats screen.
///
/// When [searchQuery] and [searchSnippet] are both non-empty, the row shows
/// the matching snippet instead of the last-message preview, and tapping the
/// row opens the chat with in-chat search pre-loaded on the query so it
/// auto-scrolls to the found text.
class ChatListItem extends ConsumerWidget {
  final ChatModel chat;
  final bool showUnreadBorder;
  final String? searchQuery;
  final String? searchSnippet;
  final String? searchMessageId;

  /// Multi-select support (see lib/widgets/multi_select.dart). While
  /// [selectionMode] is true the row renders a leading check circle and taps
  /// toggle the selection instead of opening the chat. [onLongPress] is the
  /// conventional selection-mode entry point and works in both modes.
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onLongPress;

  /// Per-row menu actions (trailing ⋮ button). Null callbacks hide their menu
  /// entries; both null (or [selectionMode]) hides the button entirely, which
  /// is how Home's Recent Chats and selection mode opt out.
  final VoidCallback? onRowMenuArchive;
  final VoidCallback? onRowMenuSelect;

  const ChatListItem({
    super.key,
    required this.chat,
    this.showUnreadBorder = false,
    this.searchQuery,
    this.searchSnippet,
    this.searchMessageId,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
    this.onLongPress,
    this.onRowMenuArchive,
    this.onRowMenuSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final textDir = ref.watch(localizationProvider).textDirection;
    final otherProfileAsync = ref.watch(
      otherUserProfileProvider(chat.otherUserId),
    );

    final fallbackName = chat.otherUserName.trim().isNotEmpty
        ? chat.otherUserName
        : l10n.getString('generalUnknown');
    final String formattedName = otherProfileAsync.when(
      data: (profile) {
        final profileName = profile?.name.formatAsFirstNameLastInitial() ?? '';
        return profileName.trim().isNotEmpty ? profileName : fallbackName;
      },
      loading: () => fallbackName,
      error: (e, s) => fallbackName,
    );

    final String ageGender = otherProfileAsync.when(
      data: (profile) {
        final age = profile?.dateOfBirth != null
            ? calculateAgeFromDate(profile!.dateOfBirth!)
            : null;
        final gender = profile?.gender;
        final parts = <String>[];
        if (age != null) {
          parts.add('${l10n.getString('profileAgeLabel')}: $age');
        }
        if (gender != null && gender.isNotEmpty) {
          final localizedGender = _getGenderLabel(gender, ref, l10n);
          parts.add('${l10n.getString('profileGender')}: $localizedGender');
        }
        return parts.join(', ');
      },
      loading: () => '',
      error: (e, s) => '',
    );

    final selfUserId = supabase.auth.currentUser?.id;
    bool isOtherTyping = false;
    if (selfUserId != null && selfUserId.isNotEmpty) {
      final typingParams = TypingParams(
        matchId: chat.matchId,
        selfUserId: selfUserId,
        otherUserId: chat.otherUserId,
      );
      isOtherTyping =
          ref.watch(isOtherTypingProvider(typingParams)).asData?.value == true;
    }

    // Only show translated message if:
    // 1. Translation is enabled AND
    // 2. Translated text exists AND
    // 3. Last message was from the other user (incoming)
    // 4. If incoming message is in a different language than UI, show NOTHING until translation exists
    final bool isIncomingMessage =
        chat.lastMessageSenderId != null &&
        chat.lastMessageSenderId != supabase.auth.currentUser?.id;

    // Determine what message to display based on translation status
    String displayMessage = '';

    if (isIncomingMessage && chat.translationEnabled) {
      final uiLang = normalizeLanguageCode(
        ref.watch(localizationProvider).currentLocale.languageCode,
      );
      // For incoming messages with translation enabled:
      // - If source language is different from UI and no translation exists, show nothing
      // - If source language matches UI, always show original message (even if translation exists)
      // - If source language is different from UI and translation exists, show translation

      // First check if source language matches UI - if so, show original
      if (chat.lastMessageSourceLanguage != null) {
        final sourceLang = normalizeLanguageCode(
          chat.lastMessageSourceLanguage!,
        );
        if (sourceLang == uiLang) {
          // Source matches UI - show original message
          displayMessage = chat.lastMessage;
        } else {
          // Source differs from UI - show translation if available,
          // otherwise nothing until it lands (never the untranslated
          // original, never a "Loading…" placeholder).
          if (chat.lastMessageTranslated != null &&
              chat.lastMessageTranslated!.isNotEmpty &&
              chat.lastMessageTranslated != 'null') {
            displayMessage = chat.lastMessageTranslated!;
          } else {
            displayMessage = '';
          }
        }
      } else {
        // No source language info - try to show translation if available,
        // otherwise nothing until the language is resolved/translated.
        if (chat.lastMessageTranslated != null &&
            chat.lastMessageTranslated!.isNotEmpty &&
            chat.lastMessageTranslated != 'null') {
          displayMessage = chat.lastMessageTranslated!;
        } else {
          displayMessage = '';
        }
      }
    } else {
      // For outgoing messages or when translation is disabled, show original message
      displayMessage = chat.lastMessage;
    }

    final otherGender = otherProfileAsync.asData?.value?.gender;
    final typingDisplayName = formattedName.isNotEmpty
        ? formattedName
        : l10n.getString('generalUnknown');
    final typed = l10n.getString(
      'chatIsTyping',
      gender: otherGender,
      params: {'name': typingDisplayName},
    );
    final typingWithName = l10n.getString(
      'chatIsTyping',
      params: {'name': typingDisplayName},
    );
    final typingMessage = typed.contains(typingDisplayName)
        ? typed
        : (typingWithName.contains(typingDisplayName)
              ? typingWithName
              : '$typingDisplayName ${typed.trim()}');

    // Encrypted last messages without decrypted content simply show an
    // empty preview — the key provider self-heals and populates it.
    // Last line of defence: the local cache field mirrors the RPC's
    // last_message_translated column, which carries base64 ciphertext for v1
    // messages. If any layer above failed to decrypt it, drop it here rather
    // than painting an unreadable blob in the user's chat list.
    // Qualify stored text for display so pre-fix rows (bare ⛱ U+26F1)
    // render in color. Display-only; DB rows are left untouched.
    final previewMessage = ensureEmojiPresentation(
      displaySafeText(displayMessage),
    );
    // Chats-list search: when a message body matched, the row previews the
    // matching text (newest match) instead of the last message.
    final activeSearchQuery = (searchQuery ?? '').trim();
    final activeSearchSnippet = ensureEmojiPresentation(
      displaySafeText((searchSnippet ?? '').trim()),
    );
    final showingSearchSnippet =
        activeSearchQuery.isNotEmpty && activeSearchSnippet.isNotEmpty;
    final listPreviewText = showingSearchSnippet
        ? activeSearchSnippet
        : previewMessage;
    final ui.TextDirection messageDir =
        RegExp(r'[a-zA-Z]').hasMatch(listPreviewText)
        ? ui.TextDirection.ltr
        : (listPreviewText.isRtl()
              ? ui.TextDirection.rtl
              : ui.TextDirection.ltr);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: 0.08)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.45)
                : showUnreadBorder && chat.unreadCount > 0
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onLongPress: onLongPress,
          onTap: selectionMode
              ? onToggleSelect
              : () async {
            final otherProfile = otherProfileAsync.value;
            final profileName =
                otherProfile?.name.formatAsFirstNameLastInitial() ?? '';
            final resolvedName = profileName.trim().isNotEmpty
                ? profileName
                : fallbackName;

            // When opened from a chats-list search, hand the query (and the
            // newest matching message id) to the chat so it auto-scrolls to
            // the found text instead of landing at the bottom.
            final pendingQuery = (searchQuery ?? '').trim();
            final pendingMessageId = (searchMessageId ?? '').trim();
            // The list search field holds focus (and the keyboard) while the
            // user types. Drop it before opening the chat: the opened chat
            // already shows the searched text via its pre-seeded in-chat
            // search, so no further typing is needed and the keyboard would
            // only hide the results.
            FocusManager.instance.primaryFocus?.unfocus();
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatScreen(
                  matchId: chat.matchId,
                  otherUserName: resolvedName,
                  otherUserId: chat.otherUserId,
                  initialSearchQuery: pendingQuery.isNotEmpty
                      ? pendingQuery
                      : null,
                  initialHighlightMessageId: pendingMessageId.isNotEmpty
                      ? pendingMessageId
                      : null,
                ),
              ),
            );

            final userId = supabase.auth.currentUser?.id;
            if (userId != null) {
              ref.invalidate(recentChatsProvider(userId));
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: child,
                  ),
                  child: selectionMode
                      ? SelectionCheckCircle(
                          key: const ValueKey('chat_check'),
                          selected: selected,
                        )
                      : KeyedSubtree(
                          key: const ValueKey('chat_avatar'),
                          child: _buildAvatar(context, otherProfileAsync),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              formattedName,
                              maxLines: 2,
                              overflow: TextOverflow.visible,
                              style: TextStyle(
                                fontWeight: chat.unreadCount > 0
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              textAlign: textDir == ui.TextDirection.rtl
                                  ? TextAlign.right
                                  : TextAlign.left,
                              textDirection: textDir,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                formatDateAndTimeOfDateTimeWithPrefs(
                                  context,
                                  ref,
                                  l10n,
                                  chat.lastMessageAt.toLocal(),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).disabledColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (chat.unreadCount > 0) ...[
                                const SizedBox(height: 6),
                                Semantics(
                                  container: true,
                                  label: l10n.getString(
                                    'chatsUnreadMessages',
                                    params: {
                                      'count': chat.unreadCount.toString(),
                                    },
                                  ),
                                  excludeSemantics: true,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      chat.unreadCount.toString(),
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      if (ageGender.isNotEmpty || isOtherTyping) ...[
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (ageGender.isNotEmpty)
                              Expanded(
                                child: Text(
                                  ageGender,
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                  textAlign: textDir == ui.TextDirection.rtl
                                      ? TextAlign.right
                                      : TextAlign.left,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontSize: 10,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.7),
                                      ),
                                ),
                              )
                            else
                              const Spacer(),
                            if (isOtherTyping) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  typingMessage,
                                  textAlign: TextAlign.end,
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w500,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      if (listPreviewText.isNotEmpty)
                        Builder(
                          builder: (context) {
                            // Unread preview stays w500 for text, but emoji
                            // runs force normal weight (bold CBDT goes
                            // transparent on Android).
                            final base = withEmojiFallback(
                              TextStyle(
                                inherit: false,
                                fontSize: 14,
                                color: chat.unreadCount > 0
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context).colorScheme.onSurface
                                          .withValues(alpha: 0.7),
                                fontWeight: FontWeight.normal,
                                letterSpacing: 0,
                                wordSpacing: 0,
                              ),
                            );
                            final List<InlineSpan> previewSpans;
                            if (showingSearchSnippet &&
                                listPreviewText.toLowerCase().contains(
                                  activeSearchQuery.toLowerCase(),
                                )) {
                              final highlightBg = Colors.yellow.withValues(
                                alpha: 0.65,
                              );
                              previewSpans = [
                                for (final (segment, isMatch)
                                    in chatSearchSplitMatches(
                                      listPreviewText,
                                      activeSearchQuery,
                                    ))
                                  if (!isMatch)
                                    ...emojiAwareSpans(segment, base)
                                  else
                                    ...emojiAwareSpans(
                                      segment,
                                      base.copyWith(
                                        backgroundColor: highlightBg,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                              ];
                            } else {
                              previewSpans = emojiAwareSpans(
                                listPreviewText,
                                base,
                              );
                            }
                            return Text.rich(
                              TextSpan(children: previewSpans),
                              textDirection: messageDir,
                              textAlign: textDir == ui.TextDirection.rtl
                                  ? TextAlign.right
                                  : TextAlign.left,
                              maxLines: 2,
                              overflow: TextOverflow.visible,
                            );
                          },
                        ),
                    ],
                  ),
                ),
                if (!selectionMode &&
                    (onRowMenuArchive != null || onRowMenuSelect != null))
                  _ChatRowMenuButton(
                    chat: chat,
                    onArchive: onRowMenuArchive,
                    onSelect: onRowMenuSelect,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(
    BuildContext context,
    AsyncValue<UserProfile?> otherProfileAsync,
  ) {
    return otherProfileAsync.when(
      data: (profile) {
        final String? photo = profile?.photos.isNotEmpty == true
            ? profile!.photos[0]
            : null;
        if (photo != null) {
          return ClipOval(
            child: SignedImage(
              source: photo,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              placeholder: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person,
                  size: 24,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              errorWidget: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person,
                  size: 24,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          );
        }
        return CircleAvatar(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.person,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        );
      },
      loading: () => CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.person,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      error: (e, s) => CircleAvatar(
        backgroundColor: Colors.grey.shade400,
        child: const Icon(Icons.person, color: Colors.white),
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
        final keyToUse = displayKey.toLowerCase().startsWith('gender_')
            ? displayKey.toLowerCase()
            : 'gender_${displayKey.toLowerCase()}';
        final localized = l10n.getString(keyToUse);
        if (localized != keyToUse && localized.isNotEmpty) {
          return localized;
        }
      } catch (_) {}
    }

    try {
      final keyToUse = genderKey.toLowerCase().startsWith('gender_')
          ? genderKey.toLowerCase()
          : 'gender_${genderKey.toLowerCase()}';
      final directTranslation = l10n.getString(keyToUse);
      if (directTranslation != keyToUse && directTranslation.isNotEmpty) {
        return directTranslation;
      }
    } catch (_) {}

    return genderKey
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
        .join(' ');
  }
}

/// Trailing ⋮ button on a chat row, opening the per-row action menu
/// (archive/unarchive, select). Rendered only when the host screen supplies
/// at least one of the menu callbacks and multi-select is not active — the
/// menu makes archive reachable without knowing the long-press gesture.
class _ChatRowMenuButton extends ConsumerWidget {
  final ChatModel chat;
  final VoidCallback? onArchive;
  final VoidCallback? onSelect;

  const _ChatRowMenuButton({
    required this.chat,
    required this.onArchive,
    required this.onSelect,
  });

  Future<void> _open(
    BuildContext buttonContext,
    LocalizationState l10n,
  ) async {
    // Anchor the popup at the button itself (just below its bottom edge)
    // so the menu opens next to the ⋮ regardless of screen position or RTL.
    final RenderBox button =
        buttonContext.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Navigator.of(buttonContext).overlay!.context.findRenderObject()
            as RenderBox;
    final anchorTop = button.localToGlobal(
      Offset(button.size.width - 4, button.size.height + 4),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(anchorTop, anchorTop + const Offset(4, 8)),
      Offset.zero & overlay.size,
    );

    final choice = await showMenu<String>(
      context: buttonContext,
      position: position,
      items: [
        if (onArchive != null)
          PopupMenuItem<String>(
            value: 'archive',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                chat.isArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                size: 20,
              ),
              title: Text(
                l10n.getString(
                  chat.isArchived ? 'chatsUnarchive' : 'chatsArchive',
                ),
              ),
            ),
          ),
        if (onSelect != null)
          PopupMenuItem<String>(
            value: 'select',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.checklist, size: 20),
              title: Text(l10n.getString('chatsSelect')),
            ),
          ),
      ],
    );
    if (!buttonContext.mounted || choice == null) return;
    switch (choice) {
      case 'archive':
        onArchive?.call();
      case 'select':
        onSelect?.call();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(
        Icons.more_vert,
        size: 20,
        color: colors.onSurfaceVariant,
      ),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      onPressed: () => _open(context, l10n),
    );
  }
}
