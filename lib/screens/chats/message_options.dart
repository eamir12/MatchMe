// lib/screens/chats/message_options.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/chats/reaction_picker.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

const List<String> _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Shows message action sheet and returns an action string (e.g., 'edit', 'copy')
Future<String?> showMessageOptions(
  BuildContext context,
  WidgetRef ref, {
  required String matchId,
  required String messageId,
  required ChatMessageModel message,
}) async {
  String? currentUserId;
  try {
    currentUserId = supabase.auth.currentUser?.id;
  } catch (_) {
    // In tests the Supabase instance may not be initialized - treat as unauthenticated
    currentUserId = null;
  }
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) {
      final l10n = ref.watch(localizationProvider);
      final editLabel = l10n.getString('chatOptionEdit');
      final deleteLabel = l10n.getString('chatOptionDelete');
      final copyLabel = l10n.getString('chatOptionCopy');
      final cancelLabel = l10n.getString('generalCancel');

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quick reaction emoji row (matches WhatsApp style)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 10.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      for (var e in _quickReactions)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6.0),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () async {
                              final scaffoldMessenger = ScaffoldMessenger.of(
                                sheetContext,
                              );
                              final l10n = ref.read(localizationProvider);
                              Navigator.pop(sheetContext);
                              try {
                                await ref
                                    .read(chatServiceProvider)
                                    .setReaction(
                                      matchId: matchId,
                                      messageId: messageId,
                                      reaction: e,
                                    );
                                try {
                                  ref.invalidate(chatMessagesProvider(matchId));
                                } catch (_) {}
                              } catch (err) {
                                print('Quick reaction failed: $err');
                                try {
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.getString('generalError'),
                                      ),
                                    ),
                                  );
                                } catch (_) {}
                              }
                            },
                            child: CircleAvatar(
                              radius: 18,
                              backgroundColor: Theme.of(sheetContext).cardColor,
                              child: Text(e),
                            ),
                          ),
                        ),
                    ],
                  ),
                  // Plus: fallback to full reaction picker (handled by parent as 'react')
                  InkWell(
                    onTap: () async {
                      final scaffoldMessenger = ScaffoldMessenger.of(
                        sheetContext,
                      );
                      final l10n = ref.read(localizationProvider);
                      Navigator.pop(sheetContext);
                      try {
                        // Open the full EmojiPicker directly so categories appear immediately
                        if (!context.mounted) return;
                        await showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          backgroundColor: Colors.transparent,
                          builder: (pickerContext) => Container(
                            height:
                                MediaQuery.of(pickerContext).size.height * 0.75,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                pickerContext,
                              ).colorScheme.surfaceContainerLow,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(20),
                              ),
                            ),
                            child: DefaultTextStyle(
                              style: withEmojiFallback(
                                Theme.of(pickerContext)
                                        .textTheme
                                        .bodyMedium ??
                                    const TextStyle(fontSize: 32),
                              ),
                              child: EmojiPicker(
                                onEmojiSelected: (category, emoji) async {
                                  final pickerScaffold =
                                      ScaffoldMessenger.of(pickerContext);
                                  final l10n2 = ref.read(localizationProvider);
                                  Navigator.pop(pickerContext);
                                  final qualified = ensureEmojiPresentation(
                                    emoji.emoji,
                                  );
                                  await recordEmojiUse(qualified);
                                  try {
                                    await ref
                                        .read(chatServiceProvider)
                                        .setReaction(
                                          matchId: matchId,
                                          messageId: messageId,
                                          reaction: qualified,
                                        );
                                  try {
                                    ref.invalidate(
                                      chatMessagesProvider(matchId),
                                    );
                                  } catch (_) {}
                                } catch (err) {
                                  print('Full picker reaction failed: $err');
                                  try {
                                    pickerScaffold.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n2.getString('generalError'),
                                        ),
                                      ),
                                    );
                                  } catch (_) {}
                                }
                              },
                              onBackspacePressed: () {},
                              config: Config(
                                checkPlatformCompatibility: false,
                                emojiViewConfig: EmojiViewConfig(
                                  columns: 8,
                                  emojiSizeMax: 32,
                                  backgroundColor: Theme.of(
                                    pickerContext,
                                  ).colorScheme.surfaceContainerLow,
                                ),
                                categoryViewConfig: CategoryViewConfig(
                                  backgroundColor: Theme.of(
                                    pickerContext,
                                  ).colorScheme.surfaceContainerLow,
                                  indicatorColor: Theme.of(
                                    pickerContext,
                                  ).colorScheme.primary,
                                  iconColorSelected: Theme.of(
                                    pickerContext,
                                  ).colorScheme.primary,
                                ),
                                searchViewConfig: SearchViewConfig(
                                  backgroundColor: Theme.of(
                                    pickerContext,
                                  ).colorScheme.surfaceContainerHighest,
                                ),
                              ),
                              ),
                            ),
                          ),
                        );
                      } catch (e) {
                        print(
                          'Failed to open full reaction picker from options: $e',
                        );
                        try {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text(l10n.getString('generalError')),
                            ),
                          );
                        } catch (_) {}
                      }
                    },
                    borderRadius: BorderRadius.circular(16),
                    child: const CircleAvatar(
                      radius: 18,
                      child: Icon(Icons.add),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l10n.getString('chatOptionReply')),
              onTap: () => Navigator.pop(sheetContext, 'reply'),
            ),
            if (message.senderId == currentUserId) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: Text(editLabel),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: Text(deleteLabel),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final confirmed = await showDialog<bool>(
                    context: sheetContext,
                    builder: (c) => AlertDialog(
                      title: Text(l10n.getString('chatDeleteConfirm')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: Text(cancelLabel),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: Text(deleteLabel),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    try {
                      await ref
                          .read(chatServiceProvider)
                          .deleteMessage(
                            matchId: matchId,
                            messageId: messageId,
                          );
                    } catch (e) {
                      print('Failed to delete message: $e');
                    }
                  }
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(copyLabel),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.contentOriginal));
                Navigator.pop(sheetContext, 'copy');
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(cancelLabel),
              onTap: () => Navigator.pop(sheetContext, null),
            ),
          ],
        ),
      );
    },
  );
}
