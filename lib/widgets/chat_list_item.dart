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
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

final supabase = Supabase.instance.client;

/// Unified chat list item used by Home recent chats and the Chats screen.
class ChatListItem extends ConsumerWidget {
  final ChatModel chat;
  final bool showUnreadBorder;

  const ChatListItem({
    super.key,
    required this.chat,
    this.showUnreadBorder = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final textDir = ref.watch(localizationProvider).textDirection;
    final otherProfileAsync = ref.watch(userProfileProvider(chat.otherUserId));

    final String formattedName = otherProfileAsync.when(
      data: (profile) =>
          profile?.name.formatAsFirstNameLastInitial() ??
          l10n.getString('generalUnknown'),
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
      // - If translation exists, show translation (not original)
      if (chat.lastMessageTranslated != null &&
          chat.lastMessageTranslated!.isNotEmpty &&
          chat.lastMessageTranslated != 'null') {
        displayMessage = chat.lastMessageTranslated!;
      } else if (chat.lastMessageSourceLanguage != null) {
        // Check if source language is different from UI language
        final sourceLang = normalizeLanguageCode(
          chat.lastMessageSourceLanguage!,
        );
        if (sourceLang != uiLang) {
          // Source is different from UI - show nothing until translation exists
          displayMessage = '';
        } else {
          // Source is same as UI - show original message
          displayMessage = chat.lastMessage;
        }
      } else {
        displayMessage = '';
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

    final String previewMessage = displayMessage;
    final ui.TextDirection messageDir =
        RegExp(r'[a-zA-Z]').hasMatch(previewMessage)
        ? ui.TextDirection.ltr
        : (previewMessage.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: showUnreadBorder && chat.unreadCount > 0
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
              : Colors.transparent,
          width: 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          final otherProfile = otherProfileAsync.value;
          if (otherProfile == null) return;

          final resolvedName = otherProfile.name.formatAsFirstNameLastInitial();

          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                matchId: chat.matchId,
                otherUserName: resolvedName,
                otherUserId: chat.otherUserId,
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
              _buildAvatar(context, otherProfileAsync),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    if (ageGender.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        ageGender,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    if (isOtherTyping)
                      Text(
                        typingMessage,
                        textAlign: textDir == ui.TextDirection.rtl
                            ? TextAlign.right
                            : TextAlign.left,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    if (previewMessage.isNotEmpty)
                      Text(
                        previewMessage,
                        textDirection: messageDir,
                        textAlign: textDir == ui.TextDirection.rtl
                            ? TextAlign.right
                            : TextAlign.left,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: chat.unreadCount > 0
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                          fontWeight: chat.unreadCount > 0
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
