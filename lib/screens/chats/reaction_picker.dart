// lib/screens/chats/reaction_picker.dart
// This file contains UI helpers for picking reactions and showing reactors.
// Note: some helper functions are executed after async operations and therefore
// intentionally use BuildContext after awaits; lints are locally suppressed where necessary.

// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';
import 'package:matchme/widgets/emoji_widget.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

Future<void> recordEmojiUse(String emoji) async {
  try {
    final box = await HiveEncryptionService.instance.openEncryptedBox<int>(
      'emoji_usage',
    );
    final current = box.get(emoji) ?? 0;
    await box.put(emoji, current + 1);
  } catch (_) {}
}

// Backwards compatible private wrapper used elsewhere in this file
Future<void> _recordEmojiUse(String emoji) async => recordEmojiUse(emoji);

Future<void> showReactionPicker(
  BuildContext context,
  WidgetRef ref, {
  String? matchId,
  String? messageId,
  String? initialMatchId,
  String? initialMessageId,
  List<String>? allEmojis,
}) async {
  final effectiveMatchId = matchId ?? initialMatchId;
  final effectiveMessageId = messageId ?? initialMessageId;

  final chatSvc = ref.read(chatServiceProvider);
  final ScrollController scrollController = ScrollController();

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (scrollController.hasClients) {
          scrollController.animateTo(
            scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      });

      final reactionsToShow = allEmojis ?? ['👍', '❤️', '😂', '😮', '😢', '🙏'];

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 12.0),
          child: SingleChildScrollView(
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ...reactionsToShow.map((emoji) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: InkWell(
                      onTap: () async {
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        final l10n = ref.read(localizationProvider);
                        Navigator.pop(context);
                        await _recordEmojiUse(emoji);
                        try {
                          if (effectiveMatchId == null ||
                              effectiveMessageId == null) {
                            return;
                          }
                          await chatSvc.setReaction(
                            matchId: effectiveMatchId,
                            messageId: effectiveMessageId,
                            reaction: emoji,
                          );
                          try {
                            ref.invalidate(
                              chatMessagesProvider(effectiveMatchId),
                            );
                          } catch (_) {}
                        } catch (e) {
                          print('setReaction failed in picker: $e');
                          try {
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text(l10n.getString('generalError')),
                              ),
                            );
                          } catch (_) {}
                        }
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).cardColor,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: EmojiWidget(emoji: emoji, size: 28),
                      ),
                    ),
                  );
                }),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: InkWell(
                    onTap: () async {
                      Navigator.pop(context);
                      await showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => Container(
                          height: MediaQuery.of(context).size.height * 0.75,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          child: DefaultTextStyle(
                            style: withEmojiFallback(
                              Theme.of(context).textTheme.bodyMedium ??
                                  const TextStyle(fontSize: 28),
                            ),
                            child: EmojiPicker(
                              onEmojiSelected: (category, emoji) async {
                                final scaffoldMessenger =
                                    ScaffoldMessenger.of(context);
                                final l10n = ref.read(localizationProvider);
                                Navigator.pop(context);
                                await _recordEmojiUse(
                                  ensureEmojiPresentation(emoji.emoji),
                                );
                              try {
                                if (effectiveMatchId == null ||
                                    effectiveMessageId == null) {
                                  return;
                                }
                                await chatSvc.setReaction(
                                  matchId: effectiveMatchId,
                                  messageId: effectiveMessageId,
                                  reaction: ensureEmojiPresentation(
                                    emoji.emoji,
                                  ),
                                );
                                try {
                                  ref.invalidate(
                                    chatMessagesProvider(effectiveMatchId),
                                  );
                                } catch (_) {}
                              } catch (e) {
                                print(
                                  'setReaction failed in picker custom emoji: $e',
                                );
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
                            config: Config(
                              checkPlatformCompatibility: false,
                              emojiViewConfig: EmojiViewConfig(
                                columns: 8,
                                emojiSizeMax: 28,
                                backgroundColor: Theme.of(context).cardColor,
                              ),
                              categoryViewConfig: CategoryViewConfig(
                                indicatorColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                iconColorSelected: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                            ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).cardColor,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.add,
                        size: 28,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> showReactorsSheet(
  BuildContext context,
  WidgetRef ref,
  String matchId,
  String messageId,
  String emoji, {
  Future<List<Map<String, dynamic>>> Function(
    String messageId,
    String reaction,
  )?
  getReactorsFn,
  Map<String, int>? reactionSummary,
}) async {
  final chatSvc = ref.read(chatServiceProvider);
  final l10n = ref.read(localizationProvider);

  final fetch =
      getReactorsFn ??
      ((String mid, String r) =>
          chatSvc.getReactors(messageId: mid, reaction: r));

  final reactors = await fetch(messageId, emoji);
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Text(
                  l10n.getString(
                    'chatReactorsHeader',
                    params: {
                      'emoji': emoji,
                      'count': reactors.length.toString(),
                    },
                  ),
                ),
                const SizedBox(height: 8),
                for (var r in reactors)
                  ListTile(
                    leading: _ReactionAvatar(
                      avatarUrl: r['avatar_url']?.toString(),
                    ),
                    title: Text(r['full_name'] ?? r['user_id'] ?? ''),
                    subtitle: Text(r['pronouns'] ?? ''),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ReactionAvatar extends StatelessWidget {
  final String? avatarUrl;

  const _ReactionAvatar({this.avatarUrl});

  @override
  Widget build(BuildContext context) {
    final source = avatarUrl?.trim() ?? '';
    if (source.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.person_outline));
    }

    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: SignedImage(
          source: source,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          placeholder: const SizedBox.shrink(),
          errorWidget: const Icon(Icons.person_outline),
        ),
      ),
    );
  }
}
