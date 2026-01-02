// lib/screens/chats/chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui; // alias to avoid conflict with TextDirection
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/providers/typing_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/screens/chats/report_dialog.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;

final supabase = Supabase.instance.client;

/// Detects if a string is primarily Right-to-Left (e.g., Hebrew, Arabic)
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

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _isSending = false;
  bool _showEmojiPicker = false;

  static const List<String> _webEmojis = [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😅',
    '😊',
    '😍',
    '😘',
    '😎',
    '🤩',
    '😇',
    '🙂',
    '🙃',
    '😉',
    '😭',
    '😢',
    '😤',
    '😡',
    '🤬',
    '😱',
    '😴',
    '🤔',
    '🤗',
    '🤝',
    '👍',
    '👎',
    '👏',
    '🙏',
    '🔥',
    '🌟',
    '💯',
    '✅',
    '❌',
    '❤️',
    '💔',
    '💖',
    '✨',
    '🎉',
    '🎶',
    '🌹',
    '☀️',
    '🌧️',
  ];

  @override
  void initState() {
    super.initState();

    // Removed: Clear local cached messages to ensure we start fresh and avoid showing deleted messages
    // The sync process now properly preserves translations, so we don't need to clear local cache

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _markAsRead();
        _scrollToBottom(animate: false);
      }
    });

    _focusNodeListener();

    // Set up typing presence if we have a logged-in user
    final selfUserId = supabase.auth.currentUser?.id;
    if (selfUserId != null && selfUserId.isNotEmpty) {
      _typingParams = TypingParams(
        matchId: widget.matchId,
        selfUserId: selfUserId,
        otherUserId: widget.otherUserId,
      );

      _messageController.addListener(() {
        final params = _typingParams;
        if (params == null) return;
        final svc = ref.read(typingServiceProvider(params));
        // signal typing on any change
        svc.startTyping();

        // reset idle timer to stop typing after inactivity
        _typingIdleTimer?.cancel();
        _typingIdleTimer = Timer(const Duration(seconds: 3), () {
          svc.stopTyping();
        });
      });
    }
  }

  void _focusNodeListener() {
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        setState(() {
          _showEmojiPicker = false;
        });
      }
    });
  }

  DateTime? _lastMarkAsReadAt;

  Future<void> _markAsRead() async {
    if (widget.matchId.isEmpty) return;
    final now = DateTime.now();
    // Throttle duplicate calls in quick succession (avoid double RPCs / logs)
    if (_lastMarkAsReadAt != null && now.difference(_lastMarkAsReadAt!) < const Duration(seconds: 2)) {
      debugPrint('_markAsRead suppressed for ${widget.matchId} (called too recently)');
      return;
    }
    _lastMarkAsReadAt = now;

    debugPrint('_markAsRead called for match ${widget.matchId}');
    try {
      await supabase.rpc(
        'mark_messages_as_read',
        params: {'p_match_id': widget.matchId},
      );

      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null) {
        // Refresh messages for this chat
        ref.invalidate(recentChatsProvider(currentUserId));
        await ref.read(chatSyncProvider(widget.matchId)).syncMessages(widget.matchId);

        // Optimistically clear local unread badge and trigger a background sync
        try {
          await ref.read(localDbProvider).clearUnreadForMatch(currentUserId, widget.matchId);
          await ref.read(globalSyncManagerProvider).syncChatsNow(currentUserId);
          ref.invalidate(recentChatsProvider(currentUserId));
        } catch (_) {
          // non-fatal
        }
      }

      debugPrint('_markAsRead completed for match ${widget.matchId}');
    } catch (e) {
      debugPrint('_markAsRead error: $e');
      // error suppressed to avoid noisy logs; higher-level UI feedback is provided elsewhere
    }
  }

  @override
  void dispose() {
    // typing presence cleanup
    try {
      _typingIdleTimer?.cancel();
      if (_typingParams != null) {
        final svc = ref.read(typingServiceProvider(_typingParams!));
        svc.stopTyping();
      }
    } catch (_) {}
    // end typing presence cleanup

    _messageController.dispose();
    _scrollControllerDispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollControllerDispose() {
    try {
      _scrollControllerJumpToBottom(); // safe no-op if not attached
      _scrollController.dispose();
    } catch (_) {}
  }

  void _sendMessage() async {
    final l10n = ref.read(localizationProvider);
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final currentUserId = supabase.auth.currentUser?.id;

    setState(() => _isSending = true);
    final String messageToSend = _messageController.text;
    _messageController.clear();

    try {
      await ref
          .read(chatServiceProvider)
          .sendMessage(matchId: widget.matchId, text: messageToSend);

      // stop typing presence after successful send
      if (_typingParams != null) {
        final svc = ref.read(typingServiceProvider(_typingParams!));
        svc.stopTyping();
      }

      if (currentUserId != null) {
        // Sync chats immediately to make the new chat appear
        await ref.read(globalSyncManagerProvider).syncChatsNow(currentUserId);
        ref.invalidate(recentChatsProvider(currentUserId));
      }
      _scrollToBottom(animate: true);

      // Ensure the input regains focus on web so the cursor returns to the typing line
      if (foundation.kIsWeb) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusNode.requestFocus();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('${l10n.getString('chatSendFailed')} $e'),
            backgroundColor: Colors.red,
          ),
        );
        _messageController.text = messageToSend;

        // Ensure the input regains focus on web after a failed send so the cursor is available
        if (foundation.kIsWeb) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _focusNode.requestFocus();
            }
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollControllerHasClients()) return;
      _jumpToBottomInternal(animate);
    });
  }

  void _jumpToBottomInternal(bool animate) {
    if (!_scrollControllerHasClients()) return;
    if (animate) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollControllerJumpToBottom();
    }
  }

  bool _scrollControllerHasClients() {
    return _scrollController.hasClients;
  }

  void _scrollControllerJumpToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0.0);
    }
  }

  Future<void> _showBlockDialog() async {
    final l10n = ref.read(localizationProvider);
    final didConfirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              '${l10n.getString('blockButton')} ${widget.otherUserName}?',
            ),
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
      final blockedUserName = widget.otherUserName;
      try {
        await supabase.rpc(
          'block_user',
          params: {'p_blocked_user_id': widget.otherUserId},
        );
        ref.invalidate(recentMatchesProvider(currentUserId));
        ref.invalidate(recentChatsProvider(currentUserId));
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                '$blockedUserName ${l10n.getString('blockSuccess')}',
              ),
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
    final String? reason = await showReportDialog(
      context,
      widget.otherUserName,
    );
    if (reason != null && reason.isNotEmpty && mounted) {
      final scaffoldMessenger = ScaffoldMessenger.of(context);
      try {
        await supabase.rpc(
          'report_user',
          params: {
            'p_reported_user_id': widget.otherUserId,
            'p_match_id': widget.matchId,
            'p_reason': reason,
          },
        );
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
              content: Text(
                '${l10n.getString('reportFailed')} ${e.toString()}',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _onEmojiIconPressed() {
    if (foundation.kIsWeb) {
      final willShow = !_showEmojiPicker;
      if (willShow) {
        _focusNode.unfocus();
      } else {
        _focusNode.requestFocus();
      }
      setState(() {
        _showEmojiPicker = willShow;
      });
    } else {
      _focusNode.requestFocus();
      setState(() {
        _showEmojiPicker = false;
      });
    }
  }

  void _navigateToProfile() async {
    // Find matchedIntent for this matchId and navigate to MatchProfileScreen.
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
        } else {
          // If recentMatchesProvider hasn't loaded, try triggering a sync (best-effort)
          ref.read(profileSyncProvider).syncProfile(currentUserId);
        }
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => MatchProfileScreen(
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
    } catch (_) {
      // suppressed
    }
  }

  void _addEmoji(String emoji) {
    final fullText = _messageController.text;
    final selection = _messageController.selection;
    final int start =
        (selection.start >= 0) ? selection.start : fullText.length;
    final int end = (selection.end >= 0) ? selection.end : fullText.length;
    final newText = fullText.replaceRange(start, end, emoji);
    _messageController.text = newText;
    final int newOffset = start + emoji.length;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: newOffset),
    );
  }

  static String _emojiToCodepoints(String emoji) {
    final codepoints =
        emoji.runes.map((r) => r.toRadixString(16).toLowerCase()).toList();
    final filtered = codepoints.where((cp) => cp != 'fe0f').toList();
    return filtered.join('-');
  }

  Widget _buildMessageContent(
    String text,
    TextStyle style,
    bool isOriginalRtl,
  ) {
    if (!foundation.kIsWeb) {
      return Text(
        text,
        style: style,
        textDirection:
            isOriginalRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      );
    }

    final List<String> emojisSorted =
        _webEmojis.toList()..sort((a, b) => b.length.compareTo(a.length));

    final List<InlineSpan> spans = [];
    final buffer = StringBuffer();
    int i = 0;
    while (i < text.length) {
      bool matched = false;
      for (final emoji in emojisSorted) {
        if (i + emoji.length <= text.length &&
            text.substring(i, i + emoji.length) == emoji) {
          if (buffer.isNotEmpty) {
            spans.add(TextSpan(text: buffer.toString(), style: style));
            buffer.clear();
          }
          final codepoints = _emojiToCodepoints(emoji);
          final url =
              'https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$codepoints.png';
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Image.network(
                url,
                width: style.fontSize != null ? style.fontSize! * 1.2 : 18,
                height: style.fontSize != null ? style.fontSize! * 1.2 : 18,
                errorBuilder: (context, error, stackTrace) {
                  return Text(emoji, style: style);
                },
              ),
            ),
          );
          i += emoji.length;
          matched = true;
          break;
        }
      }
      if (!matched) {
        buffer.write(text[i]);
        i++;
      }
    }
    if (buffer.isNotEmpty) {
      spans.add(TextSpan(text: buffer.toString(), style: style));
    }

    return RichText(
      textDirection:
          isOriginalRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      text: TextSpan(children: spans),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final messagesAsyncValue = ref.watch(chatMessagesProvider(widget.matchId));
    final currentUserId = supabase.auth.currentUser!.id;

    final targetLanguage = ref.watch(translationProvider)[widget.matchId];

    final isOnline = _connectivityProviderChecker(ref) ?? true;

    // Get the other user's profile for their image
    final otherUserProfileAsync = ref.watch(
      userProfileProvider(widget.otherUserId),
    );
    final otherUserProfile = otherUserProfileAsync.asData?.value;
    final otherUserImage =
        otherUserProfile?.photos.isNotEmpty == true
            ? otherUserProfile!.photos[0]
            : null;

    final otherUserLastReadAt = messagesAsyncValue.whenOrNull(
      data: (messages) {
        final otherMessages = messages.where(
          (m) => m.senderId == widget.otherUserId && m.readAt != null,
        );
        if (otherMessages.isEmpty) return null;
        return otherMessages
            .map((m) => m.createdAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
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

        bool isAtBottom = true;

        if (_scrollController.hasClients &&
            _scrollController.position.hasContentDimensions) {
          isAtBottom = _scrollController.offset < 100;
        }

        final isFirstLoad = previous == null || previous is AsyncLoading;

        if (isAtBottom || isFirstLoad) {
          _scrollToBottom(animate: !isFirstLoad);
        } else {
          // user is scrolled up — don't auto-scroll
        }
      } else if (next is AsyncData && nextList.length == prevList.length) {
        // Likely a read-receipt update; no scroll
      }
    });

    // Build the short display using localized template and First L.
    // The UI shows the small caption above the user name ("You are chatting with")
    final chattingCaption = l10n.getString('chatYouAreChattingWith');
    final displayName = widget.otherUserName;

    return Directionality(
      textDirection: l10n.textDirection,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _navigateToProfile,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  child:
                      otherUserImage != null
                          ? ClipOval(
                            child: SignedImage(
                              source: otherUserImage,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              placeholder: const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              errorWidget: Icon(
                                Icons.person,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          )
                          : Icon(
                            Icons.person,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chattingCaption,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        displayName,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 8.0,
                  vertical: 4.0,
                ),
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

            IconButton(
              icon: const Icon(Icons.person_outline),
              tooltip: l10n.getString('profileTitle'),
              onPressed: _navigateToProfile,
            ),

            IconButton(
              onPressed: () async {
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                try {
                  final currentOffset =
                      _scrollControllerHasClients()
                          ? _scrollController.offset
                          : 0.0;
                  final myLanguage =
                      ref.read(localizationProvider).currentLocale.languageCode;
                  final currentTarget =
                      ref.read(translationProvider)[widget.matchId];

                  if (currentTarget == null) {
                    await ref
                        .read(translationProvider.notifier)
                        .setTranslation(widget.matchId, myLanguage);
                    // Bump translation version to force re-evaluation of translation providers
                    ref.read(translationVersionProvider.notifier).increment();
                    scaffoldMessenger.showSnackBar(
                      SnackBar(
                        content: Text('${l10n.getString('chatTranslateOn')} (to $myLanguage)'),
                      ),
                    );
                  } else {
                    await ref
                        .read(translationProvider.notifier)
                        .setTranslation(widget.matchId, null);
                    // Bump translation version to force re-evaluation of translation providers
                    ref.read(translationVersionProvider.notifier).increment();
                    scaffoldMessenger.showSnackBar(
                      SnackBar(
                        content: Text(l10n.getString('chatTranslateOff')),
                      ),
                    );
                  }

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(currentOffset);
                    }
                  });
                } catch (_) {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                      content: Text(l10n.getString('errorGeneric')),
                    ),
                  );
                }
              },
              icon: Icon(
                targetLanguage == null
                    ? Icons.translate
                    : Icons.g_translate_rounded,
                color:
                    targetLanguage == null
                        ? Colors.black
                        : Colors.blue.shade200,
              ),
              tooltip: l10n.getString('chatTranslateToggle'),
            ),

            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'block') {
                  _showBlockDialog();
                } else if (value == 'report') {
                  _showReportDialog();
                }
              },
              itemBuilder:
                  (BuildContext context) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'report',
                      child: ListTile(
                        leading: Icon(Icons.report_gmailerrorred),
                        title: Text(l10n.getString('reportTitle')),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'block',
                      child: ListTile(
                        leading: Icon(Icons.block, color: Colors.red),
                        title: Text(
                          l10n.getString('blockButton'),
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ),
                  ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  _focusNode.unfocus();
                  setState(() {
                    _showEmojiPicker = false;
                  });
                },
                child: messagesAsyncValue.when(
                  data: (messages) {
                    if (messages.isEmpty) {
                      return Center(
                        child: Text(l10n.getString('chatSayHello')),
                      );
                    }

                    final reversedMessages = messages.reversed.toList();

                    return ListView.builder(
                      controller:
                          _scrollControllerHasClients()
                              ? _scrollController
                              : _scrollController,
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
                        );
                      },
                    );
                  },
                  loading:
                      () => const Center(child: CircularProgressIndicator()),
                  error:
                      (err, stack) => Center(
                        child: Text(
                          '${l10n.getString('chatLoadingMessages')} $err',
                        ),
                      ),
                ),
              ),
            ),
            _buildMessageInputArea(),
            if (_showEmojiPicker && foundation.kIsWeb)
              SizedBox(
                height: 250,
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: (MediaQuery.of(context).size.width ~/ 48)
                        .clamp(6, 12),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: _webEmojis.length,
                  itemBuilder: (context, index) {
                    final emoji = _webEmojis[index];
                    final codepoints = _emojiToCodepoints(emoji);
                    final url =
                        'https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$codepoints.png';
                    return InkWell(
                      onTap: () {
                        _addEmoji(emoji);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).cardColor,
                        ),
                        alignment: Alignment.center,
                        child: Image.network(
                          url,
                          width: 32,
                          height: 32,
                          errorBuilder: (context, error, stackTrace) {
                            return Text(
                              emoji,
                              style: const TextStyle(fontSize: 24),
                            );
                          },
                        ),
                      ),
                    );
                  },
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
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, -1),
            blurRadius: 2,
            color: Colors.black.withValues(alpha: 0.1),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_typingParams != null)
              Consumer(
                builder: (context, ref, _) {
                  final isTyping =
                      ref
                          .watch(isOtherTypingProvider(_typingParams!))
                          .asData
                          ?.value ==
                      true;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child:
                        isTyping
                            ? Padding(
                              key: const ValueKey('typing_on'),
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                              child: Builder(
                                builder: (context) {
                                  // Use the user profile name if available to ensure we display the proper name
                                  final otherProfile = ref.watch(userProfileProvider(widget.otherUserId)).asData?.value;
                                  final displayName = (otherProfile?.name != null && otherProfile!.name.isNotEmpty)
                                      ? otherProfile.name
                                      : (widget.otherUserName.isNotEmpty ? widget.otherUserName : '');
                                  return _TypingRow(name: displayName);
                                },
                              ),
                            )
                            : const SizedBox.shrink(
                              key: ValueKey('typing_off'),
                            ),
                  );
                },
              ),
            Row(
              children: [
                // Emoji icon: show only on web or non-mobile platforms (mobile keyboards provide emojis)
                if (foundation.kIsWeb || (foundation.defaultTargetPlatform != TargetPlatform.android && foundation.defaultTargetPlatform != TargetPlatform.iOS))
                  IconButton(
                    icon: Icon(
                      _showEmojiPicker
                          ? Icons.keyboard_alt_outlined
                          : Icons.emoji_emotions_outlined,
                      color: Colors.grey,
                    ),
                    onPressed: _onEmojiIconPressed,
                  ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    focusNode: _focusNodeGetter(),
                    textDirection: l10n.textDirection,
                    textCapitalization: TextCapitalization.sentences,
                    autocorrect: true,
                    enableSuggestions: true,
                    decoration: InputDecoration(
                      hintText: l10n.getString('chatTypeMessage'),
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20.0),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 10.0,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8.0),
                IconButton(
                  icon:
                      _isSending
                          ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.send),
                  onPressed: _isSending ? null : _sendMessage,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  FocusNode _focusNodeGetter() => _focusNode;
}

/// Message bubble widget. Accepts an optional messageContentBuilder so the parent can control
/// how message text is rendered (used to swap emoji glyphs for Twemoji images on web).
class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserLastReadAt,
    this.messageContentBuilder,
  });

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
    final color =
        isMe
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.secondaryContainer;
    final textColor =
        isMe
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : Theme.of(context).colorScheme.onSecondaryContainer;

    Icon? readReceiptIcon;
    if (isMe) {
      if (message.isPending) {
        readReceiptIcon = Icon(
          Icons.watch_later_outlined,
          size: 16,
          color: Colors.grey,
        );
      } else if (message.readAt != null) {
        readReceiptIcon = Icon(
          Icons.done_all,
          size: 16,
          color: Colors.blue.shade400,
        );
      } else {
        readReceiptIcon = Icon(Icons.done, size: 16, color: Colors.grey);
      }
    }

    final targetLanguage = ref.watch(translationProvider)[matchId];
    bool needsTranslation = targetLanguage != null && !isMe;



    final translationParams = jsonEncode({
      'text': message.contentOriginal,
      'matchId': matchId,
      'messageId': message.id,
      'otherUserId': otherUserId,
    });

    AsyncValue<String>? translationAsync;
    final String? translatedData;
    // Check if we have a valid cached translation for the current target language
    final hasValidCachedTranslation = message.translatedText != null &&
                                     message.translatedText!.isNotEmpty &&
                                     message.translatedLang == targetLanguage;

    if (needsTranslation && !hasValidCachedTranslation) {
      translationAsync = ref.watch(
        translationFamilyProvider(translationParams),
      );
      translatedData = translationAsync?.asData?.value;

    } else if (hasValidCachedTranslation) {
      translatedData = message.translatedText;

    } else {
      translatedData = null;

    }

    final bool isOriginalRtl = _isRtl(message.contentOriginal);

    final bool showTranslated =
        needsTranslation &&
        translatedData != null &&
        translatedData.trim().isNotEmpty &&
        translatedData.trim() != message.contentOriginal.trim();

    final messageTextStyle = TextStyle(color: textColor, fontSize: 16);

    final timeLabel = formatTimeOfDateTimeWithPrefs(context, ref, l10n, message.createdAt.toLocal());

    return GestureDetector(
      onLongPress: () async {
        // Open the reaction picker for this message
        await showReactionPicker(context, ref, initialMatchId: matchId, initialMessageId: message.id);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          crossAxisAlignment: alignment,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 8.0,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Original message content aligned based on detected direction
                    Align(
                      alignment: isOriginalRtl ? Alignment.centerRight : Alignment.centerLeft,
                      child: messageContentBuilder != null
                          ? messageContentBuilder!(
                            message.contentOriginal,
                            messageTextStyle,
                            isOriginalRtl,
                          )
                          : Text(
                            message.contentOriginal,
                            style: messageTextStyle,
                            textDirection:
                                isOriginalRtl
                                    ? ui.TextDirection.rtl
                                    : ui.TextDirection.ltr,
                          ),
                    ),

                    Visibility(
                      visible: showTranslated,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: const Divider(height: 12, thickness: 0.5),
                    ),

                    Visibility(
                      visible: showTranslated,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Builder(
                        builder: (context) {
                          // Show cached translation or async translation result
                          final displayText = translatedData;
                          if (displayText == null || displayText.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          final bool isTranslatedRtl = _isRtl(displayText);
                          final translatedStyle = TextStyle(
                            color: textColor.withValues(alpha: 0.8),
                            fontStyle: FontStyle.italic,
                            fontSize: 14,
                          );
                          return Align(
                            alignment: isTranslatedRtl ? Alignment.centerRight : Alignment.centerLeft,
                            child: messageContentBuilder != null
                                ? SizedBox(
                                  key: ValueKey('${message.id}_translated'),
                                  child: messageContentBuilder!(
                                    displayText,
                                    translatedStyle,
                                    isTranslatedRtl,
                                  ),
                                )
                                : Text(
                                  displayText,
                                  key: ValueKey('${message.id}_translated'),
                                  style: translatedStyle,
                                  textDirection:
                                      isTranslatedRtl
                                          ? ui.TextDirection.rtl
                                          : ui.TextDirection.ltr,
                                ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),

            // Reaction row
            if ((message.reactionSummary ?? {}).isNotEmpty || message.myReaction != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: ReactionRow(message: message, matchId: matchId),
              ),

            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment:
                    alignment == CrossAxisAlignment.end
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                children: [
                  Text(
                    timeLabel,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                  if (isMe && readReceiptIcon != null) ...[
                    const SizedBox(width: 4),
                    readReceiptIcon,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small reaction picker and row helpers
const List<String> _defaultReactions = ['❤️','👍','😂','😮','😢','😡','🔥','🎉'];

class ReactionRow extends ConsumerWidget {
  const ReactionRow({super.key, required this.message, required this.matchId});

  final ChatMessageModel message;
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final summary = message.reactionSummary ?? {};
    if (summary.isEmpty && message.myReaction == null) return const SizedBox.shrink();

    // Sort by count desc then emoji
    final entries = summary.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Ensure current user's reaction appears even if absent from summary
    if (message.myReaction != null && !summary.containsKey(message.myReaction)) {
      entries.insert(0, MapEntry(message.myReaction!, 1));
    }

    return Wrap(
      spacing: 8,
      children: entries.map((e) {
        final emoji = e.key;
        final count = e.value;
        final bool isMine = message.myReaction == emoji;
        return GestureDetector(
          onTap: () async {
            try {
              // Toggle: if already mine, clear; otherwise set
              final newReaction = isMine ? null : emoji;
              await ref.read(chatServiceProvider).setReaction(
                matchId: matchId,
                messageId: message.id,
                reaction: newReaction,
              );
            } catch (err) {
              // ignore: use_build_context_synchronously
            final scaffold = ScaffoldMessenger.maybeOf(context);
              if (scaffold != null) scaffold.showSnackBar(SnackBar(content: Text(l10n.getString('errorGeneric'))));
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isMine ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12) : Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Text(count.toString(), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

Future<void> showReactionPicker(BuildContext context, WidgetRef ref, {String? initialMatchId, String? initialMessageId}) async {
  final l10n = ref.read(localizationProvider);
  final matchId = initialMatchId ?? '';
  final messageId = initialMessageId ?? '';

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.getString('chatReact'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: _defaultReactions.map((emoji) {
                  return InkWell(
                    onTap: () async {
                      final navigator = Navigator.of(context);
                      final chatSvc = ref.read(chatServiceProvider);
                      navigator.pop();
                      try {
                        await chatSvc.setReaction(
                          matchId: matchId,
                          messageId: messageId,
                          reaction: emoji,
                        );
                      } catch (_) {
                        // Silently ignore - caller may show snackbar
                      }
                    },

                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Typing row widget updated to use localization (consumer) and keep the animated dots.
class _TypingRow extends ConsumerStatefulWidget {
  final String name;
  const _TypingRow({required this.name});

  @override
  ConsumerState<_TypingRow> createState() => _TypingRowState();
}

class _TypingRowState extends ConsumerState<_TypingRow> {
  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    // Template should be localized and contain a {name} placeholder.
    // Display as "user is typing..." format with static ellipses.
    final template = l10n.getString('chatIsTyping'); // e.g. "{name} is typing"
    // Force template if localization fails
    final actualTemplate = template == 'chatIsTyping...' ? '{name} is typing' : template;
    // Use a safe display name (trim, fallback to localized or English "Someone")
    final safeDefault = l10n.getString('chatSomeone') != 'chatSomeone' && l10n.getString('chatSomeone').isNotEmpty
        ? l10n.getString('chatSomeone')
        : 'Someone';
    final displayName = widget.name.trim().isNotEmpty ? widget.name.trim() : safeDefault;
    var label = actualTemplate.replaceAll('{name}', displayName);

    // Debug logging (improved)
    debugPrint('TypingRow debug: template="$template", actualTemplate="$actualTemplate", displayName="$displayName", label="$label", widget.name="${widget.name}", hasNamePlaceholder=${actualTemplate.contains('{name}')}');

    // If replacement didn't work (template missing placeholder), fallback to a simple localized phrase
    String finalLabel;
    if (actualTemplate.contains('{name}')) {
      finalLabel = label; // already replaced
    } else if (label.contains('{name}')) {
      finalLabel = '$displayName is typing';
    } else {
      // If template lacks {name}, prepend the display name so the user's name is shown:
      // e.g., "is typing…" -> "Eran A. is typing…"
      if (label.trim().isNotEmpty) {
        finalLabel = '$displayName ${label.trim()}';
      } else {
        finalLabel = '$displayName is typing';
      }
    }

    debugPrint('TypingRow final: finalLabel="$finalLabel"');

    // Avoid leading ellipses before the name; ensure at most one trailing ellipsis
    String displayTypingLabel = finalLabel;
    final normalized = finalLabel.trim();
    if (!(normalized.endsWith('…') || normalized.endsWith('...'))) {
      displayTypingLabel = '$normalized…';
    }

    return Row(
      children: [
        const SizedBox(width: 6),
        Text(
          displayTypingLabel,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
      ],
    );
  }
}

// Helper to safely read connectivity provider value (used in build)
bool? _connectivityProviderChecker(WidgetRef ref) {
  try {
    return ref.watch(connectivityProvider).value;
  } catch (_) {
    return true;
  }
}
