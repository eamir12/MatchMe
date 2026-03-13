// lib/screens/chats/chat_screen.dart
// Uses emoji_picker_flutter ^4.4.0 for WhatsApp-like categorized emoji picker

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/screens/chats/message_options.dart';
import 'package:matchme/screens/chats/reaction_picker.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/providers/typing_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/screens/chats/report_dialog.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/widgets/emoji_widget.dart';
import 'package:matchme/widgets/chat_background.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;



SupabaseClient get supabase => Supabase.instance.client;

bool _isRtl(String text) {
  if (text.isEmpty) return false;
  final rtlRegex = RegExp(r'[\u0590-\u05FF\u0600-\u06FF]');
  for (int i = 0; i < text.length; i++) {
    final char = text[i];
    if (RegExp(r'[a-zA-Z]').hasMatch(char)) {
      return false;
    }
    if (rtlRegex.hasMatch(char)) {
      return true;
    }
  }
  return false;
}


class ChatScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserName;
  final String otherUserId;

  const ChatScreen({
    super.key,
    required this.matchId,
    required this.otherUserName,
    required this.otherUserId,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  Timer? _typingIdleTimer;
  TypingParams? _typingParams;
  // Keep a direct reference to the typing service so we don't call `ref` during dispose
  // (calling `ref` while the widget is unmounted is unsafe).
  TypingService? _typingService;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _isSending = false;
  bool _showEmojiPicker = false;
  // Tracks the inferred text direction of the composer based on typed text
  TextDirection _composerTextDirection = TextDirection.ltr;
  String? _editingMessageId;
  String? _replyingToMessageId;
  String? _replyingToSnippet;

  @override
  void initState() {
    super.initState();

    // Notify background services that we're viewing this chat
    BackgroundService.setViewingChat(widget.matchId);
    MobileLocalNotificationService.setViewingChat(widget.matchId);
    WebNotificationService.setViewingChat(widget.matchId);
    unawaited(_clearChatNotificationsOnEnter());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _markAsRead();
        _scrollToBottom(animate: false);
      }
    });

    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _showEmojiPicker) {
        setState(() {
          _showEmojiPicker = false;
        });
      }
    });

    final selfUserId = supabase.auth.currentUser?.id;
    if (selfUserId != null && selfUserId.isNotEmpty) {
      _typingParams = TypingParams(
        matchId: widget.matchId,
        selfUserId: selfUserId,
        otherUserId: widget.otherUserId,
      );

      // Capture the service instance now so we can call it safely during dispose
      _typingService = ref.read(typingServiceProvider(_typingParams!));

      _messageController.addListener(() {
        // Update composer direction as user types
        _updateComposerDirectionFromText();

        final params = _typingParams;
        if (params == null) return;
        final TypingService svc = _typingService ?? ref.read(typingServiceProvider(params));
        svc.startTyping();

        _typingIdleTimer?.cancel();
        _typingIdleTimer = Timer(const Duration(seconds: 3), () {
          svc.stopTyping();
        });
      });
    }
  }

  DateTime? _lastMarkAsReadAt;

  Future<void> _clearChatNotificationsOnEnter() async {
    BackgroundService.resetChatNotification(widget.matchId);
    MobileLocalNotificationService.resetChatNotification(widget.matchId);
    WebNotificationService.resetChatNotification(widget.matchId);
    BackgroundService.dismissChatNotification(widget.matchId);
    await MobileLocalNotificationService.dismissChatNotification(widget.matchId);
  }

  Future<void> _markAsRead() async {
    debugPrint('ChatScreen: _markAsRead called for matchId: ${widget.matchId}');
    if (widget.matchId.isEmpty) return;
    final now = DateTime.now();
    if (_lastMarkAsReadAt != null &&
        now.difference(_lastMarkAsReadAt!) < const Duration(seconds: 2)) {
      debugPrint('ChatScreen: Skipping _markAsRead due to rate limit');
      return;
    }
    _lastMarkAsReadAt = now;
    debugPrint('ChatScreen: Proceeding with _markAsRead');

    try {
      // Reset and dismiss notifications first to prevent race conditions
      debugPrint('ChatScreen: Resetting notification state for chat: ${widget.matchId}');
      await _clearChatNotificationsOnEnter();

      final result = await supabase.rpc(
        'mark_messages_as_read',
        params: {'p_match_id': widget.matchId},
      );
      debugPrint('ChatScreen: mark_messages_as_read result: $result');

      // Additional logging for web badge debugging
      if (kIsWeb) {
        debugPrint('🔍 [WEB] ChatScreen: Called mark_messages_as_read for match: ${widget.matchId}');
        debugPrint('🔍 [WEB] ChatScreen: Result: $result');
      }

      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null) {
        ref.invalidate(recentChatsProvider(currentUserId));
        await ref
            .read(chatSyncProvider(widget.matchId))
            .syncMessages(widget.matchId);

        await ref
            .read(localDbProvider)
            .clearUnreadForMatch(currentUserId, widget.matchId);
        await ref.read(globalSyncManagerProvider).syncChatsNow(currentUserId);
        ref.invalidate(recentChatsProvider(currentUserId));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    // Notify background services that we're no longer viewing this chat
    BackgroundService.clearViewingChat();
    MobileLocalNotificationService.clearViewingChat();
    WebNotificationService.clearViewingChat();

    _typingIdleTimer?.cancel();
    // Stop typing via the cached service reference to avoid calling `ref` while disposing
    try {
      _typingService?.stopTyping();
    } catch (_) {}
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }



  void _startEditingMessage(String messageId, String initialText) {
    setState(() {
      _editingMessageId = messageId;
      _replyingToMessageId = null; // cancel reply mode if editing
      _replyingToSnippet = null;
      _messageController.text = initialText;
      _updateComposerDirectionFromText(initialText);
      _focusNode.requestFocus();
    });
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _messageController.clear();
      _updateComposerDirectionFromText();
    });
  }

  void _startReplyingMessage(String messageId, String snippet) {
    setState(() {
      _replyingToMessageId = messageId;
      _replyingToSnippet = snippet;
      _editingMessageId = null; // cancel edit mode if replying
      _messageController.clear();
      _updateComposerDirectionFromText();
      _focusNode.requestFocus();
    });
  }

  void _cancelReply() {
    setState(() {
      _replyingToMessageId = null;
      _replyingToSnippet = null;
    });
  }

  Future<void> _submitComposer() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final chatSvc = ref.read(chatServiceProvider);
    setState(() => _isSending = true);
    try {
      if (_editingMessageId != null) {
        await chatSvc.editMessage(matchId: widget.matchId, messageId: _editingMessageId!, newText: text);
        _cancelEditing();
      } else {
        await chatSvc.sendMessage(matchId: widget.matchId, text: text, replyToMessageId: _replyingToMessageId);
        _messageController.clear();
        _cancelReply();
        _focusNode.requestFocus();
      }
      ref.invalidate(chatMessagesProvider(widget.matchId));

      // Also update local unread counts and invalidate providers
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null) {
        // Since we just sent a message, our unread count for this chat should be 0
        ref.read(localDbProvider).clearUnreadForMatch(currentUserId, widget.matchId);
        ref.invalidate(recentChatsProvider(currentUserId));
      }
    } catch (e) {
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('Failed to send/edit message')));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(0.0);
      }
    });
  }

  Future<void> _showBlockDialog() async {
    final l10n = ref.read(localizationProvider);
    final didConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${l10n.getString('blockButton')} ${widget.otherUserName}?'),
        content: Text(l10n.getString('blockConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.getString('blockButton')),
          ),
        ],
      ),
    );
    if (didConfirm == true && mounted) {
      final navigator = Navigator.of(context);
      final scaffoldMessenger = ScaffoldMessenger.of(context);
      final currentUserId = supabase.auth.currentUser!.id;
      try {
        await supabase.rpc('block_user', params: {'p_blocked_user_id': widget.otherUserId});
        ref.invalidate(recentMatchesProvider(currentUserId));
        ref.invalidate(recentChatsProvider(currentUserId));
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('${widget.otherUserName} ${l10n.getString('blockSuccess')}'),
              backgroundColor: Colors.green,
            ),
          );
          navigator.popUntil((route) => route.isFirst);
        }
      } catch (e) {
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('${l10n.getString('blockFailed')} ${e.toString()}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _showReportDialog() async {
    final l10n = ref.read(localizationProvider);
    final String? reason = await showReportDialog(context, widget.otherUserName);
    if (reason != null && reason.isNotEmpty && mounted) {
      final scaffoldMessenger = ScaffoldMessenger.of(context);
      try {
        await supabase.rpc('report_user', params: {
          'p_reported_user_id': widget.otherUserId,
          'p_match_id': widget.matchId,
          'p_reason': reason,
        });
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(l10n.getString('reportSuccess')),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('${l10n.getString('reportFailed')} ${e.toString()}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _navigateToProfile() async {
    try {
      final currentUserId = supabase.auth.currentUser?.id;
      String matchedIntent = '';
      String matchType = 'proximity';
      String? eventId;
      String? eventName;
      String? eventLink;
      MatchModel? found;

      if (currentUserId != null) {
        final matchesAsync = ref.read(recentMatchesProvider(currentUserId));
        final matches = matchesAsync.value;
        if (matches != null) {
          for (final m in matches) {
            if (m.id == widget.matchId) {
              found = m;
              break;
            }
          }
          if (found != null) {
            matchedIntent = found.matchedIntent;
            matchType = found.matchType;
            eventId = found.eventId;
            eventName = found.eventName;
            eventLink = found.eventLink;
          }
        }
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MatchProfileScreen(
            matchId: widget.matchId,
            otherUserId: widget.otherUserId,
            otherUserName: widget.otherUserName,
            matchedIntent: matchedIntent,
            matchType: matchType,
            eventId: eventId,
            eventName: eventName,
            eventLink: eventLink,
            createdAt: found?.createdAt ?? DateTime.now(),
          ),
        ),
      );
    } catch (_) {}
  }

  void _addEmoji(String emoji) {
    final fullText = _messageController.text;
    final selection = _messageController.selection;
    final int start = (selection.start >= 0) ? selection.start : fullText.length;
    final int end = (selection.end >= 0) ? selection.end : fullText.length;
    final newText = fullText.replaceRange(start, end, emoji);
    _messageController.text = newText;
    final int newOffset = start + emoji.length;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: newOffset),
    );

    // Emoji insertion can change inferred direction (e.g., inserting RTL emoji sequences)
    _updateComposerDirectionFromText();
  }

  void _updateComposerDirectionFromText([String? text]) {
    final t = (text ?? _messageController.text).trimLeft();
    final bool isRtlText = _isRtl(t);
    final newDir = isRtlText ? TextDirection.rtl : TextDirection.ltr;
    if (newDir != _composerTextDirection) {
      setState(() {
        _composerTextDirection = newDir;
      });
    }
  }

  void _onEmojiPressed() {
    setState(() {
      _showEmojiPicker = !_showEmojiPicker;
    });
    if (_showEmojiPicker) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  Widget _buildMessageContent(String text, TextStyle style, bool isOriginalRtl) {
    return Text(
      text,
      style: style,
      textDirection: isOriginalRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final messagesAsyncValue = ref.watch(chatMessagesProvider(widget.matchId));
    final currentUserId = supabase.auth.currentUser!.id;
    final targetLanguage = ref.watch(translationProvider)[widget.matchId];
    final isOnline = ref.watch(connectivityProvider).value ?? true;

    final otherUserProfileAsync = ref.watch(otherUserProfileProvider(widget.otherUserId));
    final otherUserProfile = otherUserProfileAsync.asData?.value;
    final otherUserImage = otherUserProfile?.photos.isNotEmpty == true ? otherUserProfile!.photos[0] : null;

    final otherUserLastReadAt = messagesAsyncValue.whenOrNull(
      data: (messages) {
        final otherMessages = messages.where((m) => m.senderId == widget.otherUserId && m.readAt != null);
        if (otherMessages.isEmpty) return null;
        return otherMessages.map((m) => m.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
      },
    );

    ref.listen(chatMessagesProvider(widget.matchId), (previous, next) {
      final prevList = previous?.value ?? [];
      final nextList = next.value ?? [];

      if (next is AsyncData && nextList.length > prevList.length) {
        final lastMessage = nextList.last;
        if (lastMessage.senderId == widget.otherUserId) {
          _markAsRead();
        }

        final bool isAtBottom = _scrollController.hasClients && _scrollController.offset < 100;
        final bool isFirstLoad = previous == null || previous is AsyncLoading;

        if (isAtBottom || isFirstLoad) {
          _scrollToBottom(animate: !isFirstLoad);
        }
      }
    });

    // Listen for translation notifications for THIS match and show a SnackBar
    ref.listen<TranslationNotification?>(translationNotificationProvider, (prev, next) {
      final notif = next;
      if (notif != null && notif.matchId == widget.matchId && mounted) {
        final scaffold = ScaffoldMessenger.of(context);
        scaffold.showSnackBar(SnackBar(content: Text(notif.text)));
        // If we got the transient notification while the chat is open, clear the persisted pending flag
        final currentUser = supabase.auth.currentUser?.id;
        if (currentUser != null && currentUser.isNotEmpty) {
          // Fire-and-forget
          ref.read(localDbProvider).clearTranslationNotificationPending(widget.matchId, userId: currentUser);
        }
        // Clear immediately to avoid duplicate popups (provider also clears after delay)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(translationNotificationProvider.notifier).clear();
          }
        });
      }
    });

    // Check if we have a pending translation-disabled notification for this chat (set when the UI language changed while chat was not open)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final currentUser = supabase.auth.currentUser?.id;
      final scaffold = ScaffoldMessenger.of(context);
      try {
        final pending = await ref.read(localDbProvider).isTranslationNotificationPending(widget.matchId, userId: currentUser);
        if (pending && mounted) {
          // Fetch localized notification text and show it
          String notificationText = '';
          try {
            final newLang = ref.read(localizationProvider).currentLocale.languageCode;
            final row = await Supabase.instance.client
                .from('translations')
                .select('value')
                .eq('key', 'chatTranslateAutoDisabled')
                .eq('locale', newLang)
                .maybeSingle();
            if (row != null && row['value'] != null) notificationText = row['value'] as String;
          } catch (_) {}

          if (notificationText.isEmpty) {
            final l10n = ref.read(localizationProvider);
            final candidate = l10n.getString('chatTranslateAutoDisabled');
            notificationText = candidate.isNotEmpty ? candidate : 'Translations turned off (UI matches translation language)';
          }

          scaffold.showSnackBar(SnackBar(content: Text(notificationText)));

          // Clear the pending flag so we don't show it again
          try {
            await ref.read(localDbProvider).clearTranslationNotificationPending(widget.matchId, userId: currentUser);
          } catch (_) {}
        }
      } catch (_) {}
    });

    final chattingCaption = l10n.getString('chatYouAreChattingWith');
    final displayName = widget.otherUserName;

    return Directionality(
      textDirection: l10n.textDirection,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 76,
          title: GestureDetector(
            onTap: _navigateToProfile,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  child: otherUserImage != null
                      ? ClipOval(
                          child: SignedImage(
                            source: otherUserImage,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            errorWidget: Icon(Icons.person, size: 20, color: Theme.of(context).colorScheme.primary),
                          ),
                        )
                      : Icon(Icons.person, size: 20, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chattingCaption,
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.visible,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (!isOnline)
              Container(
                margin: const EdgeInsets.only(right: 8.0),
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Row(
                  children: [
                    Icon(Icons.wifi_off, size: 14, color: Theme.of(context).colorScheme.onPrimaryContainer),
                    const SizedBox(width: 4),
                    Text(
                      l10n.getString('generalOffline'),
                      style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 12),
                    ),
                  ],
                ),
              ),
            IconButton(icon: const Icon(Icons.person_outline), tooltip: l10n.getString('profileTitle'), onPressed: _navigateToProfile),
            IconButton(
              onPressed: () async {
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                try {
                  final myLanguage = ref.read(localizationProvider).currentLocale.languageCode;
                  final currentTarget = ref.read(translationProvider)[widget.matchId];

                  if (currentTarget == null) {
                    await ref.read(translationProvider.notifier).setTranslation(widget.matchId, myLanguage);
                    ref.read(translationVersionProvider.notifier).increment();
                    scaffoldMessenger.showSnackBar(SnackBar(content: Text('${l10n.getString('chatTranslateOn')} (to $myLanguage)')));
                  } else {
                    await ref.read(translationProvider.notifier).setTranslation(widget.matchId, null);
                    ref.read(translationVersionProvider.notifier).increment();
                    scaffoldMessenger.showSnackBar(SnackBar(content: Text(l10n.getString('chatTranslateOff'))));
                  }
                } catch (_) {
                  scaffoldMessenger.showSnackBar(SnackBar(content: Text(l10n.getString('errorGeneric'))));
                }
              },
              icon: Icon(
                targetLanguage == null ? Icons.translate : Icons.g_translate_rounded,
                color: targetLanguage == null ? Colors.black : Colors.blue.shade200,
              ),
              tooltip: l10n.getString('chatTranslateToggle'),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'block') _showBlockDialog();
                if (value == 'report') _showReportDialog();
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'report', child: ListTile(leading: const Icon(Icons.report_gmailerrorred), title: Text(l10n.getString('reportTitle')))),
                PopupMenuItem(
                  value: 'block',
                  child: ListTile(
                    leading: const Icon(Icons.block, color: Colors.red),
                    title: Text(l10n.getString('blockButton'), style: const TextStyle(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ChatBackground(
                child: GestureDetector(
                  onTap: () {
                    _focusNode.unfocus();
                    if (_showEmojiPicker) {
                      setState(() => _showEmojiPicker = false);
                    }
                  },
                  child: messagesAsyncValue.when(
                    data: (messages) {
                      if (messages.isEmpty) {
                        return Center(child: Text(l10n.getString('chatSayHello')));
                      }
                      final reversedMessages = messages.reversed.toList();
                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8.0),
                        reverse: true,
                        itemCount: reversedMessages.length,
                        itemBuilder: (context, index) {
                          final message = reversedMessages[index];
                          final isMe = message.senderId == currentUserId;
                          return _MessageBubble(
                            key: ValueKey(message.id),
                            message: message,
                            isMe: isMe,
                            matchId: widget.matchId,
                            otherUserId: widget.otherUserId,
                            otherUserLastReadAt: otherUserLastReadAt,
                            messageContentBuilder: _buildMessageContent,
                            onRequestEdit: (id, text) => _startEditingMessage(id, text),
                            onRequestReply: (id, text) => _startReplyingMessage(id, text),
                          );
                        },
                      );
                    },
                    loading: () => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 8),
                          Text(l10n.getString('chatLoadingMessages')),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              try {
                                ref.read(chatSyncProvider(widget.matchId)).syncMessages(widget.matchId);
                              } catch (_) {}
                            },
                            child: Text(l10n.getString('generalRetry')),
                          ),
                        ],
                      ),
                    ),
                    error: (err, stack) => Center(child: Text('${l10n.getString('chatLoadingMessages')} $err')),
                  ),
                ),
              ),
            ),
            _buildMessageInputArea(),
            if (_showEmojiPicker)
              SizedBox(
                height: 300,
                child: EmojiPicker(
                  onEmojiSelected: (category, emoji) {
                    _addEmoji(emoji.emoji);
                  },
                  onBackspacePressed: () {
                    final controller = _messageController;
                    final text = controller.text;
                    final selection = controller.selection;
                    if (selection.baseOffset > 0) {
                      final newText = text.substring(0, selection.baseOffset - 1) + text.substring(selection.end);
                      controller.text = newText;
                      controller.selection = TextSelection.fromPosition(
                        TextPosition(offset: selection.baseOffset - 1),
                      );
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
                      indicatorColor: Theme.of(context).colorScheme.primary,
                      iconColorSelected: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageInputArea() {
    final l10n = ref.read(localizationProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [BoxShadow(offset: const Offset(0, -1), blurRadius: 2, color: Colors.black.withValues(alpha: 0.1))],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingToMessageId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.getString('replyingToLabel'), style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 4),
                            Text(_replyingToSnippet ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: _cancelReply,
                      ),
                    ],
                  ),
                ),
              ),
            if (_editingMessageId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.getString('chatEditingMessage'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13, fontStyle: FontStyle.italic),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelEditing,
                      child: Text(l10n.getString('generalCancel')),
                    ),
                  ],
                ),
              ),
            if (_typingParams != null)
              Consumer(
                builder: (context, ref, _) {
                  final isTyping = ref.watch(isOtherTypingProvider(_typingParams!)).asData?.value == true;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: isTyping
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: _TypingRow(name: widget.otherUserName),
                          )
                        : const SizedBox.shrink(),
                  );
                },
              ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions_outlined,
                    color: Colors.grey,
                  ),
                  onPressed: _onEmojiPressed,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    focusNode: _focusNode,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 16, fontFamily: 'Noto Sans'),
                    // When empty, align hint according to the current UI direction (Hebrew => RTL).
                    // Once the user types, keep the per-message inferred direction for mixed-language chats.
                    textDirection: _messageController.text.trim().isEmpty
                        ? Directionality.of(context)
                        : _composerTextDirection,
                    textAlign: TextAlign.start,
                    textCapitalization: TextCapitalization.sentences,
                    autocorrect: true,
                    enableSuggestions: true,
                    decoration: InputDecoration(
                      hintText: l10n.getString('chatTypeMessage'),
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20.0), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                    ),
                    onSubmitted: (_) => _submitComposer(),
                  ),
                ),
                const SizedBox(width: 8.0),
                if (_editingMessageId != null) ...[
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _cancelEditing,
                  ),
                  IconButton(
                    icon: _isSending ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check),
                    onPressed: _isSending ? null : _submitComposer,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ] else ...[
                  IconButton(
                    icon: _isSending ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                    onPressed: _isSending ? null : _submitComposer,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserLastReadAt,
    this.messageContentBuilder,
    this.onRequestEdit,
    this.onRequestReply,
  });

  final void Function(String messageId, String initialText)? onRequestEdit;
  final void Function(String messageId, String initialText)? onRequestReply;

  final ChatMessageModel message;
  final bool isMe;
  final String matchId;
  final String otherUserId;
  final DateTime? otherUserLastReadAt;
  final Widget Function(String, TextStyle, bool)? messageContentBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final alignment = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // Use WhatsApp-like bubble colors with dark-mode fallbacks.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Classic WhatsApp outgoing light green and an approximation for dark mode
    const outgoingLight = Color(0xFFDCF8C6);
    const outgoingDark = Color(0xFF054640);
    // Incoming bubbles: white/light in light mode, dark gray in dark mode
    final incomingLight = Theme.of(context).scaffoldBackgroundColor;
    const incomingDark = Color(0xFF262626);

    final color = isMe ? (isDark ? outgoingDark : outgoingLight) : (isDark ? incomingDark : incomingLight);

    final textColor = isMe
        ? (isDark ? Colors.white : Colors.black87)
        : (Theme.of(context).textTheme.bodyMedium?.color ?? Theme.of(context).colorScheme.onSurface);

    Icon? readReceiptIcon;
    if (isMe) {
      if (message.isPending) {
        readReceiptIcon = Icon(Icons.watch_later_outlined, size: 16, color: Colors.grey);
      } else if (message.readAt != null) {
        readReceiptIcon = Icon(Icons.done_all, size: 16, color: Colors.blue.shade400);
      } else if (message.deliveredAt != null) {
        readReceiptIcon = Icon(Icons.done_all, size: 16, color: Colors.grey);
      } else {
        readReceiptIcon = Icon(Icons.done, size: 16, color: Colors.grey);
      }
    }

    final targetLanguage = ref.watch(translationProvider)[matchId];
    
    // Translation logic:
    // 1. If we already have translation for the target language -> show it (no waiting)
    // 2. If we have translation for a DIFFERENT language -> need to re-translate
    // 3. If we have NO translation at all -> message might be in target language already, show original
    final hasTranslationForTarget = !isMe && 
        message.contentTranslated != null &&
        message.contentTranslated!.isNotEmpty &&
        message.translatedLang == targetLanguage;
    
    final shouldEvaluateTranslation = targetLanguage != null && !isMe;

    AsyncValue<String>? translationAsync;
    String? translatedData;
    if (hasTranslationForTarget) {
      // Already have translation for target language
      translatedData = message.contentTranslated;
    } else if (shouldEvaluateTranslation) {
      translationAsync = ref.watch(translationFamilyProvider(jsonEncode({
        'text': message.contentOriginal,
        'matchId': matchId,
        'messageId': message.id,
        'otherUserId': otherUserId,
      })));
      translatedData = translationAsync?.asData?.value;
    }

    final bool isOriginalRtl = _isRtl(message.contentOriginal);
    // Show translated text if we have translation data and it's different from original
    final bool showTranslated = translatedData != null &&
        translatedData.trim().isNotEmpty &&
        translatedData.trim() != message.contentOriginal.trim();

    final messageTextStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(color: textColor, fontSize: 16) ?? TextStyle(color: textColor, fontSize: 16);
    String timeLabel;
    try {
      timeLabel = formatTimeOfDateTimeWithPrefs(context, ref, l10n, message.createdAt.toLocal());
    } catch (_) {
      // In test environments some providers (prefs/localization) may not be initialized; fall back to simple HH:MM
      final dt = message.createdAt.toLocal();
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      timeLabel = '$hh:$mm';
    }

    final bool hasReactions = (message.reactionSummary ?? {}).isNotEmpty || message.myReaction != null;

    // Hide message until translation is ready ONLY when:
    // - Translation is enabled for this chat
    // - Message is from other user (incoming)
    // - UI language matches the target translation language 
    // - We don't have translation data ready yet
    // This provides cleaner UX for the standard translation case
    final bool shouldWaitForTranslation = shouldEvaluateTranslation &&
        !hasTranslationForTarget &&
        (translationAsync?.isLoading ?? false);
    
    if (shouldWaitForTranslation) {
      // Hide completely until translation is ready - no loading indicator
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onLongPress: () async {
        final scaffoldMessenger = ScaffoldMessenger.of(context);
        final l10n = ref.read(localizationProvider);
        final action = await showMessageOptions(
          context,
          ref,
          matchId: matchId,
          messageId: message.id,
          message: message,
        );
        if (action == 'edit' && message.senderId == supabase.auth.currentUser?.id) {
          onRequestEdit?.call(message.id, message.contentOriginal);
        } else if (action == 'reply') {
          onRequestReply?.call(message.id, message.contentOriginal);
        } else if (action == 'react') {
          try {
            // ignore: use_build_context_synchronously
            await showReactionPicker(context, ref, matchId: matchId, messageId: message.id);
          } catch (e) {
            debugPrint('Failed to open reaction picker for message ${message.id}: $e');
            try { scaffoldMessenger.showSnackBar(SnackBar(content: Text(l10n.getString('generalError')))); } catch (_) {}
          }
        }
      },
      onDoubleTap: () async {
        final newReaction = (message.myReaction == '❤️') ? null : '❤️';
        try {
          await ref.read(chatServiceProvider).setReaction(
            matchId: matchId,
            messageId: message.id,
            reaction: newReaction,
          );
        } catch (_) {}
      },
      child: Padding(
        // Add horizontal gutter so bubbles don't sit at the very screen edge
        padding: EdgeInsets.only(left: isMe ? 56.0 : 8.0, right: isMe ? 8.0 : 56.0, top: 4.0, bottom: 4.0),
        child: Column(
          crossAxisAlignment: alignment,
          children: [
            Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: IntrinsicWidth(
                stepWidth: 1.0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                  child: Container(
                    key: Key('message_bubble_${message.id}'),
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: isMe
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                              bottomLeft: Radius.circular(12),
                              bottomRight: Radius.circular(4),
                            )
                          : const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                              bottomLeft: Radius.circular(4),
                              bottomRight: Radius.circular(12),
                            ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.replyToContent != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                              decoration: BoxDecoration(
                                color: Theme.of(context).dividerColor.withValues(alpha: 0.02),
                                borderRadius: BorderRadius.circular(6.0),
                              ),
                              child: Text(message.replyToContent ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                            ),
                          ),
                        Align(
                          alignment: isOriginalRtl ? Alignment.centerRight : Alignment.centerLeft,
                          child: messageContentBuilder != null
                              ? messageContentBuilder!(message.contentOriginal, messageTextStyle, isOriginalRtl)
                              : Text(
                                  message.contentOriginal,
                                  style: messageTextStyle,
                                  textDirection: isOriginalRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                                ),
                        ),
                        if (showTranslated) const Divider(height: 12, thickness: 0.5),
                        if (showTranslated)
                          Builder(
                            builder: (context) {
                              final td = translatedData!;
                              final bool isTranslatedRtl = _isRtl(td);
                              final translatedStyle = TextStyle(color: textColor.withValues(alpha: 0.8), fontStyle: FontStyle.italic, fontSize: 14);
                              return Align(
                                alignment: isTranslatedRtl ? Alignment.centerRight : Alignment.centerLeft,
                                child: messageContentBuilder != null
                                    ? messageContentBuilder!(td, translatedStyle, isTranslatedRtl)
                                    : Text(
                                        td,
                                        style: translatedStyle,
                                        textDirection: isTranslatedRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                                      ),
                              );
                            },
                          ),
                        // Timestamp and optional read receipt placed inside the bubble at the bottom-right
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Debug wrapper shows font family & features in debug builds
                              Text(
                                timeLabel,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: textColor.withValues(alpha: 0.85), fontSize: 12),
                              ),
                              if (message.editedAt != null) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: (() {
                                    try {
                                      return formatTimeOfDateTimeWithPrefs(context, ref, l10n, message.editedAt!.toLocal());
                                    } catch (_) {
                                      final dt = message.editedAt!.toLocal();
                                      final hh = dt.hour.toString().padLeft(2, '0');
                                      final mm = dt.minute.toString().padLeft(2, '0');
                                      return '$hh:$mm';
                                    }
                                  })(),
                                  child: Text(
                                    'Edited',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: textColor.withValues(alpha: 0.65), fontSize: 10, fontStyle: FontStyle.italic),
                                  ),
                                ),
                              ],
                              if (isMe && readReceiptIcon != null) ...[const SizedBox(width: 6), readReceiptIcon],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ),
            const SizedBox(height: 2),
            // Align reactions closely to the bubble (reduced spacing)
            hasReactions
                ? Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 2.0),
                      child: Transform.translate(
                        offset: const Offset(0, -2),
                        child: ReactionRow(message: message, matchId: matchId),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
            // Composer / Edit UI is below the message list
          ],
        ),
      ),
    );
  }
}

class ReactionRow extends ConsumerWidget {
  const ReactionRow({
    super.key,
    required this.message,
    required this.matchId,
  });

  final ChatMessageModel message;
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = message.reactionSummary ?? {};
    if (summary.isEmpty && message.myReaction == null) return const SizedBox.shrink();

    final entries = summary.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Wrap(
      spacing: 6,
      children: entries.map((e) {
        final emoji = e.key;
        final count = e.value;
        final isMine = message.myReaction == emoji;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              await showReactorsSheet(context, ref, matchId, message.id, emoji);
            },

            onLongPress: () async {
              final newReaction = isMine ? null : emoji;
              final l10n = ref.read(localizationProvider);
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              try {
                await ref.read(chatServiceProvider).setReaction(
                  matchId: matchId,
                  messageId: message.id,
                  reaction: newReaction,
                );
                try {
                  ref.invalidate(chatMessagesProvider(matchId));
                } catch (_) {}
              } catch (e) {
                debugPrint('setReaction failed for message ${message.id}: $e');
                try { scaffoldMessenger.showSnackBar(SnackBar(content: Text(l10n.getString('generalError')))); } catch (_) {}
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isMine
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.08)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmojiWidget(emoji: emoji, size: 14),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Text('$count', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  ],
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

@foundation.visibleForTesting
class MessageBubbleTestWrapper extends ConsumerWidget {
  const MessageBubbleTestWrapper({super.key, required this.message, required this.isMe});

  final ChatMessageModel message;
  final bool isMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MessageBubble(
      message: message,
      isMe: isMe,
      matchId: message.matchId,
      otherUserId: 'other',
      otherUserLastReadAt: null,
    );
  }
}

Future<void> showReactorsSheet(
  BuildContext context,
  WidgetRef ref,
  String matchId,
  String messageId,
  String emoji, {
  Future<List<Map<String, dynamic>>> Function(String messageId, String reaction)? getReactorsFn,
  Map<String, int>? reactionSummary,
}) async {
  final l10n = ref.read(localizationProvider);
  final chatSvc = ref.read(chatServiceProvider);
  final localDb = ref.read(localDbProvider);
  final currentUserId = supabase.auth.currentUser?.id;

  final fetch = getReactorsFn ?? ((String mid, String r) => chatSvc.getReactors(messageId: mid, reaction: r));

  // Build set of reaction keys (from cache or provided summary)
  final Set<String> reactionKeys = {};
  try {
    final msg = await localDb.getMessageById(matchId, messageId);
    if (msg != null) {
      final reactorsContainer = msg['reactors'];
      if (reactorsContainer is Map) reactionKeys.addAll(reactorsContainer.keys.map((k) => k.toString()));
      final rs = msg['reaction_summary'];
      if (rs is Map) reactionKeys.addAll(rs.keys.map((k) => k.toString()));
    }
  } catch (_) {}
  if (reactionSummary != null) reactionKeys.addAll(reactionSummary.keys);
  if (reactionKeys.isEmpty) reactionKeys.add(emoji);

  // Aggregate reactors by user and record their reaction. We collect all occurrences
  // first (to detect conflicts where a user appears in multiple reaction buckets),
  // then resolve conflicts by consulting the server for authoritative membership.
  final Map<String, List<Map<String, dynamic>>> occurrences = {};
  final List<String> rKeys = reactionKeys.toList();

  for (final rKey in rKeys) {
    List<Map<String, dynamic>> reactors = [];
    try {
      reactors = await localDb.getCachedReactors(matchId, messageId, rKey);
    } catch (_) {
      reactors = [];
    }

    if (reactors.isEmpty) {
      try {
        final server = await fetch(messageId, rKey);
        // Save even empty server responses to ensure the local cache matches server state
        try { await localDb.saveCachedReactors(matchId, messageId, rKey, server); } catch (_) {}
        reactors = server;
      } catch (_) {
        reactors = [];
      }
    }

    final seen = <String>{};
    for (final entry in reactors.where((e) => e['user_id'] != null && seen.add(e['user_id'] as String))) {
      final uid = entry['user_id'] as String;
      final map = Map<String, dynamic>.from(entry);
      map['reaction'] = rKey;
      occurrences.putIfAbsent(uid, () => []).add(map);
    }
  }

  // Resolve conflicts where a user appears in multiple reactions by querying the server
  final Map<String, Map<String, dynamic>> byUser = {};
  for (final uid in occurrences.keys) {
    final lists = occurrences[uid]!;
    if (lists.length == 1) {
      byUser[uid] = lists.first;
      continue;
    }

    // Conflict: user found in multiple reaction buckets. Ask server which bucket the user belongs to.
    Map<String, dynamic>? resolved;
    try {
      for (final rk in rKeys) {
        try {
          final server = await fetch(messageId, rk);
          if (server.any((e) => e['user_id'] == uid)) {
            // Use server's entry for accuracy and persist it locally
            try { await localDb.saveCachedReactors(matchId, messageId, rk, server); } catch (_) {}
            final entry = server.firstWhere((e) => e['user_id'] == uid);
            final map = Map<String, dynamic>.from(entry);
            map['reaction'] = rk;
            resolved = map;
            break;
          }
        } catch (e) {
          // ignore individual fetch errors; continue trying other keys
        }
      }
    } catch (_) {}

    // Fallback: pick the first seen entry if server couldn't resolve
    byUser[uid] = resolved ?? lists.first;
  }

  // hydrate from local profiles
  for (final uid in byUser.keys.toList()) {
    final m = byUser[uid]!;
    final needsName = m['display_name'] == null || (m['display_name'] as String).isEmpty;
    final photoStr = m['photo'] as String?;
    final needsPhoto = photoStr?.isEmpty ?? true;
    if (needsName || needsPhoto) {
      try {
        final profile = await localDb.getLocalProfile(uid);
        if (profile != null) {
          if (needsName) {
            final name = profile['name'] as String?;
            if (name != null && name.isNotEmpty) m['display_name'] = name;
          }
          if (needsPhoto) {
            final photos = profile['photos'] as List?;
            if (photos != null && photos.isNotEmpty) m['photo'] = photos[0];
          }
        }
      } catch (_) {}
    }
  }

  final reactorsList = byUser.values.toList();


  if (!context.mounted) return;

  await showModalBottomSheet(
    context: context,
    builder: (context) {
      if (reactorsList.isEmpty) {
        return Padding(
          padding: const EdgeInsets.all(32),
          child: Center(child: Text(l10n.getString('chatNoReactors'))),
        );
      }

      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: reactorsList.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final r = reactorsList[index];
          final uid = r['user_id'] as String?;
          final displayName = r['display_name'] as String?;
          final photo = r['photo'] as String?;
          final reaction = (r['reaction'] is String && (r['reaction'] as String).isNotEmpty) ? (r['reaction'] as String) : emoji;

          final name = displayName?.isNotEmpty == true
              ? (() {
                  final parts = displayName!.trim().split(RegExp(r'\s+'));
                  if (parts.length > 1) {
                    return '${parts.first} ${parts.last[0]}.';
                  }
                  return displayName;
                })()
              : l10n.getString('generalUnknown');

          final isMe = uid != null && uid == currentUserId;

          return ListTile(
            leading: photo != null && photo.isNotEmpty
                ? SignedImage(source: photo, width: 40, height: 40, fit: BoxFit.cover)
                : const Icon(Icons.person),
            title: Text(name),
            subtitle: isMe ? Text(l10n.getString('chatReactorsTapToRemove')) : null,
            trailing: EmojiWidget(emoji: reaction, size: 24),
            onTap: isMe
                ? () async {
                    final navigator = Navigator.of(context);
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final l10n = ref.read(localizationProvider);
                    try {
                      await chatSvc.setReaction(
                        matchId: matchId,
                        messageId: messageId,
                        reaction: null,
                      );
                      try { ref.invalidate(chatMessagesProvider(matchId)); } catch (_) {}
                      navigator.pop();
                    } catch (e) {
                      debugPrint('Failed to clear reaction for message $messageId: $e');
                      try { scaffoldMessenger.showSnackBar(SnackBar(content: Text(l10n.getString('generalError')))); } catch (_) {}
                    }
                  }
                : null,
          );
        },

      );
    },
  );
}

// Reaction picker implementation moved to lib/screens/chats/reaction_picker.dart


class _TypingRow extends StatelessWidget {
  final String name;
  const _TypingRow({required this.name});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            name.isNotEmpty ? '$name is typing...' : 'Typing...',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ),
      ],
    );
  }
}
