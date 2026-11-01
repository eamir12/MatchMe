// lib/widgets/chat_list_item.dart
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/typing_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:matchme/widgets/multi_select.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/widgets/word_clipped_text.dart';
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
    // The name lays out in its own script (a Hebrew name keeps its trailing
    // period left of the initial) while staying flush with the UI direction.
    final nameLayout = formattedName.displayTextLayout(textDir);

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

    // Determine what message to display based on translation status.
    // [isTranslationPending] is true while an incoming message needs a
    // translation that has not landed yet: the preview stays blank on purpose
    // (never the untranslated original), and every unread affordance is held
    // back with it so the badge, the bold name and the translated text all
    // reveal in one frame — matching the push/inbox, which the server also
    // only publishes once the translation exists.
    String displayMessage = '';
    bool isTranslationPending = false;

    if (isIncomingMessage && chat.translationEnabled) {
      final uiLang = normalizeLanguageCode(
        ref.watch(localizationProvider).currentLocale.languageCode,
      );
      final translated = chat.lastMessageTranslated;
      final target = chat.lastMessageTranslatedTargetLanguage;
      final translationMatchesContent =
          chat.lastMessageEditedAt == null ||
          chat.lastMessageEditedAt!.isEmpty ||
          translationEditMarkersMatch(
            chat.lastMessageTranslatedEditedAt,
            chat.lastMessageEditedAt,
          );
      final source = chat.lastMessageSourceLanguage;
      final sourceMatchesUi =
          isValidLanguageCode(source) &&
          normalizeLanguageCode(source!) == uiLang;
      if (sourceMatchesUi) {
        // Same language as the UI: the original is already readable and does
        // not need a translation payload (historical rows can legitimately
        // have source == target with no translated content).
        displayMessage = chat.lastMessage;
      } else if (translated != null &&
          translated.isNotEmpty &&
          translated != 'null' &&
          target != null &&
          normalizeLanguageCode(target) == uiLang &&
          translationMatchesContent) {
        displayMessage = translated;
      } else {
        // Translation-enabled incoming content stays hidden until a usable
        // result for this target language and message revision is available.
        // A permanent failure is stored server-side as the original payload
        // with translation_status='failed', so it arrives through the
        // `translated` branch above rather than leaking the original here.
        isTranslationPending = true;
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
        !isTranslationPending &&
        activeSearchQuery.isNotEmpty &&
        activeSearchSnippet.isNotEmpty;
    final listPreviewText = showingSearchSnippet
        ? activeSearchSnippet
        : previewMessage;
    // Unread affordances (badge, bold name, border) stay hidden while the
    // preview is blank only because its translation is still in flight, so
    // they appear together with the text instead of the badge arriving first.
    final bool showUnreadIndicators =
        chat.unreadCount > 0 &&
        !(isTranslationPending && listPreviewText.isEmpty);
    final ui.TextDirection messageDir =
        RegExp(r'[a-zA-Z]').hasMatch(listPreviewText)
        ? ui.TextDirection.ltr
        : (listPreviewText.isRtl()
              ? ui.TextDirection.rtl
              : ui.TextDirection.ltr);
    // The typing line mixes the name with the localized "is typing" verb, so
    // its paragraph direction follows the first strong character it carries —
    // the same rule the preview line uses.
    final ui.TextDirection typingDir =
        RegExp(r'[a-zA-Z]').hasMatch(typingMessage)
        ? ui.TextDirection.ltr
        : (typingMessage.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
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
                : showUnreadBorder && showUnreadIndicators
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

                  // Opening the conversation counts as seeing the tool
                  // alert: the heads-up overlay and its inbox row clear.
                  await ref
                      .read(meetupAlertsProvider.notifier)
                      .clearMatch(chat.matchId);

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
                        matchType: chat.matchType,
                        eventName: chat.eventName,
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
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
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
                      // The name owns the whole width of the content column.
                      // It used to share its line with the timestamp, whose
                      // full "21 באוקטובר 2026 · 3:27 אחר הצהריים" stamp took
                      // ~200px and left the name ~35px: every name that was
                      // not one short word spilled onto a second line, and a
                      // longer one painted over the line below it. The name
                      // is the row's primary identifier, so it wraps only
                      // when it truly does not fit - never because something
                      // else took the space.
                      SafeText(
                        formattedName,
                        style: TextStyle(
                          fontWeight: showUnreadIndicators
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        textAlign: nameLayout.textAlign,
                        textDirection: nameLayout.textDirection,
                      ),
                      const SizedBox(height: 2),
                      // Metadata band: age/gender on the leading side, the
                      // timestamp pinned to the trailing edge so it lines up
                      // across rows instead of ragging with the name length.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (ageGender.isNotEmpty)
                            Expanded(
                              child: SafeText(
                                ageGender,
                                textAlign: textDir == ui.TextDirection.rtl
                                    ? TextAlign.right
                                    : TextAlign.left,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.7),
                                    ),
                              ),
                            )
                          else
                            const Spacer(),
                          // Unread count rides on the age/gender line
                          // (trailing edge) instead of owning a row under
                          // the timestamp — the common chat-app pattern of
                          // pairing the badge with the row's secondary text.
                          if (showUnreadIndicators) ...[
                            const SizedBox(width: 8),
                            Semantics(
                              container: true,
                              label: l10n.getString(
                                'chatsUnreadMessages',
                                params: {'count': chat.unreadCount.toString()},
                              ),
                              excludeSemantics: true,
                              child: Container(
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          Text(
                            formatCompactListTimestamp(
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
                        ],
                      ),
                      const SizedBox(height: 4),
                      // While the other side is typing, the indicator takes
                      // the preview's place (the usual chat-list convention).
                      // The band above already carries the age/gender and the
                      // timestamp, so it has no room left for a third
                      // string, and the preview would only compete with the
                      // indicator for the same line.
                      if (isOtherTyping)
                        SafeText(
                          typingMessage,
                          textAlign: TextAlign.start,
                          textDirection: typingDir,
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w500,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      else if (listPreviewText.isNotEmpty)
                        Builder(
                          builder: (context) {
                            // Unread preview stays w500 for text, but emoji
                            // runs force normal weight (bold CBDT goes
                            // transparent on Android).
                            // `inherit: false` drops the DefaultTextStyle, so
                            // the app font family has to be stated explicitly:
                            // without it the emoji fallback list becomes the
                            // preferred font and iOS resolves the space glyph
                            // from Apple Color Emoji (very wide word gaps).
                            final base = withEmojiFallback(
                              TextStyle(
                                inherit: false,
                                fontFamily: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.fontFamily,
                                fontSize: 14,
                                color: showUnreadIndicators
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
                              final isDark =
                                  Theme.of(context).brightness ==
                                  Brightness.dark;
                              final highlightBg = isDark
                                  ? Colors.amber.withValues(alpha: 0.35)
                                  : Colors.yellow.withValues(alpha: 0.65);
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
                            return WordClippedText(
                              spans: previewSpans,
                              style: base,
                              maxLines: 2,
                              textAlign: TextAlign.start,
                              textDirection: messageDir,
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
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.person,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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

  Future<void> _open(BuildContext buttonContext, LocalizationState l10n) async {
    // Anchor the popup at the button itself (just below its bottom edge)
    // so the menu opens next to the ⋮ regardless of screen position or RTL.
    final RenderBox button = buttonContext.findRenderObject() as RenderBox;
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
      icon: Icon(Icons.more_vert, size: 20, color: colors.onSurfaceVariant),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      onPressed: () => _open(context, l10n),
    );
  }
}
