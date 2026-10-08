// lib/screens/chats/chat_screen.dart
// Uses emoji_picker_flutter ^4.4.0 for WhatsApp-like categorized emoji picker

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/screens/chats/message_options.dart';
import 'package:matchme/screens/chats/reaction_picker.dart';
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
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/widgets/chat_background.dart';
import 'package:matchme/widgets/offline_indicator.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:matchme/utils/chat_composer_utils.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';
import 'package:intl/intl.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/translation_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/screens/location_share/location_share_map_screen.dart';
import 'package:matchme/screens/location_share/location_share_duration_dialog.dart';
import 'package:matchme/widgets/location_share_banner.dart';
import 'package:matchme/services/location_service.dart';

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

/// Whether [message] matches an in-chat search for [needle].
///
/// [needle] must already be trimmed + lowercased. Every human-readable field
/// of the message is searched: the original body, the cached machine
/// translation (both column aliases the local DB uses), and the quoted-reply
/// previews. Searching the translation matters: a Hebrew speaker typing an
/// English word (or the reverse) finds the message only via its translation.
///
/// This mirrors `LocalDbService.searchCachedMessages` field coverage, but runs
/// over the decrypted in-memory models so it works on the exact text the
/// bubbles render — including edits that have not been flushed to Hive yet.
bool chatSearchMessageMatches(ChatMessageModel message, String needle) {
  if (needle.isEmpty) return false;
  final candidates = <String?>[
    message.contentOriginal,
    message.contentTranslated,
    message.translatedText,
    message.replyToContent,
    message.replyToContentTranslated,
  ];
  for (final c in candidates) {
    if (c != null && c.isNotEmpty && c.toLowerCase().contains(needle)) {
      return true;
    }
  }
  return false;
}

/// Which side of a message matched [needle]: 'translated' when only the
/// translation (or reply translation) contains it, else 'original'.
///
/// Used for the "Matched in translation" badge so users understand why a
/// message they can't read in the original matched their query.
String chatSearchMatchedField(ChatMessageModel message, String needle) {
  if (needle.isEmpty) return 'original';
  final q = needle.toLowerCase();
  final originals = <String?>[
    message.contentOriginal,
    message.replyToContent,
  ];
  for (final c in originals) {
    if (c != null && c.isNotEmpty && c.toLowerCase().contains(q)) {
      return 'original';
    }
  }
  return 'translated';
}

/// Splits [text] into runs around every case-insensitive occurrence of
/// [query]: `(segment, isMatch)` pairs for highlight rendering.
List<(String, bool)> chatSearchSplitMatches(String text, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) return [(text, false)];
  final lower = text.toLowerCase();
  final parts = <(String, bool)>[];
  var start = 0;
  while (true) {
    final idx = lower.indexOf(needle, start);
    if (idx < 0) {
      parts.add((text.substring(start), false));
      break;
    }
    if (idx > start) parts.add((text.substring(start, idx), false));
    parts.add((text.substring(idx, idx + needle.length), true));
    start = idx + needle.length;
    if (start >= text.length) break;
  }
  return parts;
}

class ChatScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserName;
  final String otherUserId;

  /// When opened from the chats-list search, pre-loads in-chat search with
  /// this query so the conversation auto-scrolls to the found text.
  final String? initialSearchQuery;

  /// Newest message id matching [initialSearchQuery] (from the chats-list
  /// full-text pass). When it still matches after load, the chat lands on
  /// it; otherwise it falls back to the newest in-chat match.
  final String? initialHighlightMessageId;

  const ChatScreen({
    super.key,
    required this.matchId,
    required this.otherUserName,
    required this.otherUserId,
    this.initialSearchQuery,
    this.initialHighlightMessageId,
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
  RealtimeChannel? _chatSignalChannel;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _isSending = false;
  bool _showEmojiPicker = false;
  // Tracks the inferred text direction of the composer based on typed text
  ui.TextDirection _composerTextDirection = ui.TextDirection.ltr;
  // Tracks whether the composer is empty so the TextField can rebuild when
  // transitioning between empty (hint follows UI direction) and non-empty
  // (direction follows typed text). Without this, typing LTR text in an RTL
  // UI would keep the stale RTL direction from the empty state because the
  // direction itself didn't change (LTR == initial) and no rebuild happened.
  bool _composerIsEmpty = true;
  String? _editingMessageId;
  String? _replyingToMessageId;
  String? _replyingToSnippet;
  String? _replyingToSenderId;
  String? _lastTranslationRefreshLocaleCode;

  // ── In-chat search (find in conversation, original + translation) ──
  // Searches the messages already loaded for this match (decrypted originals
  // plus cached translations). Translations are end-to-end encrypted and only
  // this device can read them, so the search runs over the in-memory
  // ChatMessageModel list — the same source the bubbles render from.
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  // Message ids matching the current query, ordered oldest → newest (same
  // order as `chatMessagesProvider` emits). Navigation starts on the newest
  // match (last entry), like WhatsApp: up goes older, down goes newer.
  List<String> _searchMatchIds = const [];
  int _searchCurrentIndex = -1;
  final Map<String, GlobalKey> _searchMessageKeys = {};
  // Handoff from the chats-list search: the newest matching message id.
  // Consumed once the first match list is computed (see initState +
  // _updateChatSearchMatches); falls back to the newest in-chat match when
  // the id is absent (e.g. history re-synced with different ids).
  String? _pendingInitialMessageId;

  // ── Jump-to-latest ────────────────────────────────────────────────
  // Standard chat affordance (WhatsApp/Telegram): once the user scrolls up —
  // or a search auto-scrolls to an older match — a small down-button appears
  // that jumps back to the newest message (offset 0: the list is reversed).
  bool _showJumpToLatest = false;

  void _onChatScrollChanged() {
    if (!mounted || !_scrollController.hasClients) return;
    final shouldShow = _scrollController.offset > 350;
    if (shouldShow != _showJumpToLatest) {
      setState(() => _showJumpToLatest = shouldShow);
    }
  }

  void _jumpToLatest() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void initState() {
    super.initState();

    // Chats-list search handoff: open with in-chat search already active on
    // the query so the conversation auto-scrolls to the found text. The
    // ref.listen on chatMessagesProvider below recomputes matches (and
    // scrolls) once messages load; _pendingInitialMessageId steers that
    // first landing onto the newest list-found message.
    final seededQuery = (widget.initialSearchQuery ?? '').trim();
    if (seededQuery.isNotEmpty) {
      _isSearching = true;
      _searchQuery = seededQuery;
      _searchController.text = seededQuery;
      final seededMessageId = (widget.initialHighlightMessageId ?? '').trim();
      _pendingInitialMessageId = seededMessageId.isNotEmpty
          ? seededMessageId
          : null;
    }

    _scrollController.addListener(_onChatScrollChanged);

    // Notify background services that we're viewing this chat.
    // These calls are fire-and-forget so the keyboard can appear instantly
    // when the user taps the text field — waiting on background/notification
    // IPC before yielding to the UI was the source of a noticeable delay.
    unawaited(_fireBackgroundServiceNotifications());

    // Kick off the mark-as-read and scroll-to-bottom work in a microtask so
    // the first frame paints immediately.  Both operations are fire-and-
    // forget; nothing in the UI depends on them completing first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToBottom(animate: false);
      }
      // Don't await — _markAsRead performs heavy network/DB work and must
      // not block the UI thread (it was previously responsible for the
      // multi-second delay before the virtual keyboard showed up).
      _markAsRead();
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
    }

    // Always track composer direction, even if typing signals are unavailable
    // (e.g. logged-out edge case). The typing part below no-ops when params
    // are null.
    _messageController.addListener(() {
      // Live-qualify text-default emoji typed via the system keyboard
      // (e.g. Gboard inserts bare ⛱ U+26F1 which renders B&W). Preserve
      // the cursor so typing doesn't jump.
      final rawComposer = _messageController.text;
      final fixedComposer = ensureEmojiPresentation(rawComposer);
      if (fixedComposer != rawComposer) {
        final sel = _messageController.selection;
        final diff = fixedComposer.length - rawComposer.length;
        _messageController.value = TextEditingValue(
          text: fixedComposer,
          selection: sel.isValid
              ? TextSelection(
                  baseOffset: (sel.baseOffset + diff).clamp(
                    0,
                    fixedComposer.length,
                  ),
                  extentOffset: (sel.extentOffset + diff).clamp(
                    0,
                    fixedComposer.length,
                  ),
                )
              : const TextSelection.collapsed(offset: -1),
          composing: TextRange.empty,
        );
      }
      // Update composer direction as user types
      _updateComposerDirectionFromText();

      final params = _typingParams;
      if (params == null) return;
      final TypingService svc =
          _typingService ?? ref.read(typingServiceProvider(params));
      // WhatsApp-like: clearing the composer hides the peer indicator
      // immediately instead of waiting out the idle timeout.
      if (_messageController.text.trim().isEmpty) {
        _typingIdleTimer?.cancel();
        svc.stopTyping();
        return;
      }
      svc.startTyping();

      _typingIdleTimer?.cancel();
      _typingIdleTimer = Timer(const Duration(seconds: 3), () {
        svc.stopTyping();
      });
    });

    // Check for any "translation auto-disabled" notification that was set
    // while the chat was *not* on screen (e.g. the user changed the UI
    // language from the settings page).  This used to live in build() which
    // caused it to re-run on every rebuild of the chat screen — many
    // rebuilds happen as messages stream in, so the check (an async DB
    // read + possibly a Supabase query for the localized string) piled up
    // and slowed the UI.  Run it once here, after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkPendingTranslationNotification());
    });

    // Listen for live location share signals from the other user while this
    // chat is open. This handles signals that arrive while the user is in chat.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _subscribeToChatLocationSignals();
        unawaited(_checkExistingLocationShareSignal());
        unawaited(_refreshTranslationsForCurrentLocale());
      }
    });
  }

  bool _messageHasStaleCachedTranslationForLocale(
    Map<String, dynamic> message,
    String currentUserId,
    String uiLanguage,
  ) {
    final senderId = message['sender_id']?.toString();
    if (senderId == null || senderId == currentUserId) {
      return false;
    }

    final messageId = message['id']?.toString();
    if (messageId == null || messageId.isEmpty) {
      return false;
    }

    final originalText = message['content_original']?.toString();
    if (originalText == null ||
        originalText.trim().isEmpty ||
        originalText == 'null') {
      return false;
    }

    final cachedTranslation =
        (message['content_translated'] ?? message['translated_text'])
            ?.toString();
    final hasCachedTranslation =
        cachedTranslation != null &&
        cachedTranslation.trim().isNotEmpty &&
        cachedTranslation != 'null';
    if (!hasCachedTranslation) {
      return false;
    }

    final cachedTargetRaw =
        (message['translated_target_language'] ?? message['translated_lang'])
            ?.toString();

    // A translation stored before the message was last edited describes text
    // the peer has since replaced. The id is unchanged by an edit, so the
    // version marker recorded at translation time is the only way to tell —
    // and it is the same check the chat-list preview and translate-proxy make.
    if (!translationEditMarkersMatch(
      normalizeEditMarker(message['translated_source_edited_at']),
      normalizeEditMarker(message['edited_at']),
    )) {
      return true;
    }

    if (cachedTargetRaw == null || cachedTargetRaw.trim().isEmpty) {
      return true;
    }

    return normalizeLanguageCode(cachedTargetRaw) != uiLanguage;
  }

  Future<void> _refreshTranslationsForCurrentLocale({
    bool force = false,
  }) async {
    if (!mounted) return;

    final uiLanguage = normalizeLanguageCode(
      ref.read(localizationProvider).currentLocale.languageCode,
    );
    if (!force && _lastTranslationRefreshLocaleCode == uiLanguage) {
      return;
    }

    final translationEnabled =
        ref.read(translationProvider)[widget.matchId] != null;
    if (!translationEnabled) {
      return;
    }

    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }

    final localDb = ref.read(localDbProvider);
    final messages = await localDb.getMessages(widget.matchId);
    if (!mounted) return;

    final staleIncomingMessageIds = messages
        .where(
          (message) => _messageHasStaleCachedTranslationForLocale(
            message,
            currentUserId,
            uiLanguage,
          ),
        )
        .map((message) => message['id']?.toString())
        .whereType<String>()
        .toList();

    if (staleIncomingMessageIds.isNotEmpty) {
      await localDb.clearCachedTranslationsForMessages(
        widget.matchId,
        staleIncomingMessageIds,
      );
      if (!mounted) return;
      ref.invalidate(chatMessagesProvider(widget.matchId));
      // Only force re-evaluation when something was actually cleared (e.g.
      // the UI language changed while the chat was closed). Bumping
      // unconditionally makes every chat entry flash: all bubbles drop
      // their cached translations and re-run (Hive re-read + re-decrypt +
      // possible network fetch) even though the cached values are still
      // valid for the current locale.
      ref.read(translationVersionProvider.notifier).increment();
    }

    _lastTranslationRefreshLocaleCode = uiLanguage;
  }

  void _subscribeToChatLocationSignals() {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    // Clean up any previous subscription
    _chatSignalChannel?.unsubscribe();

    _chatSignalChannel = supabase
        .channel('chat_ls:${widget.matchId}:$currentUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'location_share_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: widget.matchId,
          ),
          callback: (payload) => _onLocationShareSignalReceived(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'location_share_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: widget.matchId,
          ),
          callback: (payload) => _onLocationShareSignalDeleted(payload),
        )
        .subscribe();
  }

  void _onLocationShareSignalReceived(PostgresChangePayload payload) {
    if (!mounted) return;
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final newRecord = payload.newRecord;
    final sharerId = newRecord['sharer_id'] as String?;
    final expiresAtStr = newRecord['expires_at'] as String?;

    // Ignore own signals
    if (sharerId == null || sharerId == currentUserId) return;

    // Ignore expired signals
    if (expiresAtStr != null) {
      final expiresAt = DateTime.parse(expiresAtStr).toUtc();
      if (DateTime.now().toUtc().isAfter(expiresAt)) return;
    }

    // Check if we already have a session for this match
    final currentSession = ref.read(locationShareProvider);
    if (currentSession != null) {
      // Session exists — the sharer updated their duration (re-inserted signal).
      // Broadcast channel should have already sent duration_updated, but use
      // the DB signal as a reliable fallback so the receiver always stays in sync.
      final DateTime? expiresAt = expiresAtStr != null
          ? DateTime.parse(expiresAtStr)
          : null;
      ref.read(locationShareProvider.notifier).updateOtherExpiresAt(expiresAt);
      return;
    }

    // Auto-create a view-only session so the banner appears
    final otherProfileAsync = ref.read(
      otherUserProfileProvider(widget.otherUserId),
    );
    final otherPhoto =
        otherProfileAsync.asData?.value?.photos.isNotEmpty == true
        ? otherProfileAsync.asData!.value!.photos[0]
        : null;
    final DateTime? expiresAt = expiresAtStr != null
        ? DateTime.parse(expiresAtStr)
        : null;
    ref
        .read(locationShareProvider.notifier)
        .viewExistingShare(
          matchId: widget.matchId,
          otherUserId: widget.otherUserId,
          otherUserName: widget.otherUserName,
          otherUserPhoto: otherPhoto,
          expiresAt: expiresAt,
        );
  }

  void _onLocationShareSignalDeleted(PostgresChangePayload payload) {
    // Signal deleted means the other user stopped sharing.
    // Note: oldRecord only contains the primary key (id) because
    // location_share_signals uses REPLICA IDENTITY DEFAULT.
    // The subscription is already filtered by match_id, so we just
    // check if the session exists.
    if (!mounted) return;
    final currentSession = ref.read(locationShareProvider);
    if (currentSession == null) return;
    if (currentSession.matchId != widget.matchId) return;

    ref.read(locationShareProvider.notifier).markOtherStopped();
  }

  /// One-shot check for an existing signal when the chat opens.
  Future<void> _checkExistingLocationShareSignal() async {
    if (!mounted) return;
    final currentSession = ref.read(locationShareProvider);
    if (currentSession != null) return;

    try {
      final hasSignal = await ref
          .read(locationShareProvider.notifier)
          .hasActiveShareSignal(widget.matchId);
      if (!hasSignal || !mounted) return;

      final otherProfileAsync = ref.read(
        otherUserProfileProvider(widget.otherUserId),
      );
      final otherPhoto =
          otherProfileAsync.asData?.value?.photos.isNotEmpty == true
          ? otherProfileAsync.asData!.value!.photos[0]
          : null;
      ref
          .read(locationShareProvider.notifier)
          .viewExistingShare(
            matchId: widget.matchId,
            otherUserId: widget.otherUserId,
            otherUserName: widget.otherUserName,
            otherUserPhoto: otherPhoto,
          );
    } catch (_) {}
  }

  /// One-shot check for the "translations auto-disabled" notification flag.
  /// Runs at most once per chat-screen lifetime.
  Future<void> _checkPendingTranslationNotification() async {
    if (!mounted) return;
    final currentUser = supabase.auth.currentUser?.id;
    final scaffold = ScaffoldMessenger.of(context);
    try {
      final pending = await ref
          .read(localDbProvider)
          .isTranslationNotificationPending(
            widget.matchId,
            userId: currentUser,
          );
      if (!pending || !mounted) return;

      // Fetch localized notification text and show it
      String notificationText = '';
      try {
        final newLang = ref
            .read(localizationProvider)
            .currentLocale
            .languageCode;
        final row = await Supabase.instance.client
            .from('translations')
            .select('value')
            .eq('key', 'chatTranslateAutoDisabled')
            .eq('locale', newLang)
            .maybeSingle();
        if (row != null && row['value'] != null) {
          notificationText = row['value'] as String;
        }
      } catch (_) {}

      if (!mounted) return;
      if (notificationText.isEmpty) {
        final l10n = ref.read(localizationProvider);
        notificationText = l10n.getString('chatTranslateAutoDisabled');
      }

      scaffold.showSnackBar(SnackBar(content: Text(notificationText)));

      // Clear the pending flag so we don't show it again
      try {
        await ref
            .read(localDbProvider)
            .clearTranslationNotificationPending(
              widget.matchId,
              userId: currentUser,
            );
      } catch (_) {}
    } catch (_) {}
  }

  /// Non-blocking variant of the "clear chat notifications" sequence.
  /// Each platform-specific call is fired-and-forgotten so that the chat
  /// screen never waits on notification IPC before yielding a frame.
  Future<void> _fireBackgroundServiceNotifications() async {
    try {
      unawaited(BackgroundService.setViewingChat(widget.matchId));
      // The mobile/web notification setters are synchronous (void) on most
      // platforms, so we just invoke them directly.
      MobileLocalNotificationService.setViewingChat(widget.matchId);
      WebNotificationService.setViewingChat(widget.matchId);
      unawaited(_clearChatNotificationsOnEnter());
    } catch (_) {}
  }

  DateTime? _lastMarkAsReadAt;

  /// Clears notifications for this chat.  Each call is fired-and-forgotten
  /// internally so the caller (e.g. `_markAsRead`) doesn't have to await the
  /// notification system before continuing with the read-receipt RPC.
  Future<void> _clearChatNotificationsOnEnter() async {
    try {
      unawaited(BackgroundService.resetChatNotification(widget.matchId));
      MobileLocalNotificationService.resetChatNotification(widget.matchId);
      WebNotificationService.resetChatNotification(widget.matchId);
      unawaited(BackgroundService.dismissChatNotification(widget.matchId));
      unawaited(
        MobileLocalNotificationService.dismissChatNotification(widget.matchId),
      );
    } catch (_) {}
  }

  /// Marks all unread messages from the other user as read and clears the
  /// local unread counter.
  ///
  /// IMPORTANT: this method must remain non-blocking from the caller's
  /// perspective.  Everything inside runs in background microtasks/futures
  /// so the chat screen paints the first frame and shows the virtual
  /// keyboard immediately.  The only synchronous work is the rate-limit
  /// guard at the top.
  void _markAsRead() {
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

    // Fire-and-forget the actual work; the caller never awaits this method.
    unawaited(_runMarkAsRead());
  }

  Future<void> _runMarkAsRead() async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      // Reset and dismiss notifications first to prevent race conditions.
      // _clearChatNotificationsOnEnter is itself non-blocking, so this is
      // effectively just a hint to the notification subsystem.
      unawaited(_clearChatNotificationsOnEnter());

      final result = await supabase.rpc(
        'mark_messages_as_read',
        params: {'p_match_id': widget.matchId},
      );
      debugPrint('ChatScreen: mark_messages_as_read result: $result');

      if (kIsWeb) {
        debugPrint(
          '🔍 [WEB] ChatScreen: Called mark_messages_as_read for match: ${widget.matchId}',
        );
        debugPrint('🔍 [WEB] ChatScreen: Result: $result');
      }

      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId == null) return;

      // The local chat list reads from the cached `chats` box; the badge
      // disappears the moment we clear the unread count for this match.
      // None of the work below gates any UI frame, so we run it in a
      // separate microtask and let it complete in the background.
      Future<void>(() async {
        try {
          await ref
              .read(localDbProvider)
              .clearUnreadForMatch(currentUserId, widget.matchId);
        } catch (_) {}
        try {
          await ref.read(globalSyncManagerProvider).syncChatsNow(currentUserId);
        } catch (_) {}
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    // Notify background services that we're no longer viewing this chat
    BackgroundService.clearViewingChat();
    MobileLocalNotificationService.clearViewingChat();
    WebNotificationService.clearViewingChat();

    _chatSignalChannel?.unsubscribe();
    _chatSignalChannel = null;

    _typingIdleTimer?.cancel();
    // Stop typing via the cached service reference to avoid calling `ref` while disposing
    try {
      _typingService?.stopTyping();
    } catch (_) {}
    _messageController.dispose();
    _scrollController.removeListener(_onChatScrollChanged);
    _scrollController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _startEditingMessage(String messageId, String initialText) {
    setState(() {
      _editingMessageId = messageId;
      _replyingToMessageId = null; // cancel reply mode if editing
      _replyingToSnippet = null;
      _replyingToSenderId = null;
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

  void _startReplyingMessage(
    String messageId,
    String snippet,
    String senderId,
  ) {
    setState(() {
      _replyingToMessageId = messageId;
      _replyingToSnippet = snippet;
      _replyingToSenderId = senderId;
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
      _replyingToSenderId = null;
    });
  }

  bool get _canSubmitComposer =>
      canSubmitChatComposer(_messageController.text, isSending: _isSending);

  Future<void> _submitComposer() async {
    // Qualify text-default emoji (⛱ -> ⛱️) before storing so every device
    // renders the color variant in bubbles, not the B&W text variant.
    final text = ensureEmojiPresentation(_messageController.text.trim());
    if (text.isEmpty) return;

    // Message sent → we are no longer typing. Hide the peer indicator
    // immediately (the composer clear below would also trigger it via the
    // empty-text listener, but this is explicit and race-free).
    _typingIdleTimer?.cancel();
    try {
      _typingService?.stopTyping();
    } catch (_) {}

    // Offline sending is allowed: the message is added optimistically to
    // the local DB (visible immediately to the sender) and the full
    // payload is queued in the chat outbox. The OutboxSyncService picks
    // it up automatically when connectivity is restored and syncs it to
    // Supabase, so messages survive app restarts, device reboots, etc.
    //
    // If we know the device is offline right now, show a small toast so
    // the user understands the message will be sent later instead of
    // looking like it failed.
    final wasOffline = shouldSkipSupabaseCalls();

    if (!mounted) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final chatSvc = ref.read(chatServiceProvider);
    final currentUserId = supabase.auth.currentUser?.id;

    if (wasOffline) {
      final l10n = ref.read(localizationProvider);
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.getString('offlineMessageQueuedToast')),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
    }

    // ── Optimistic UI ─────────────────────────────────────────────────
    // For new messages the service writes the message to the local DB
    // *before* the network round-trip (`localDb.addMessages` in
    // `ChatService.sendMessage`), so the local messages watch stream emits
    // it within a frame.  Clearing the composer and dropping the reply
    // context up front lets the user start typing the next message
    // immediately, matching the WhatsApp feel.
    //
    // We deliberately do NOT show a long-blocking spinner for new messages:
    // the optimistic bubble with the watch-later icon is the visible
    // "sending" state, and it flips to a single-check on Supabase
    // confirmation.  Only edits (which don't have an optimistic local row
    // and need the server response before they can update the bubble) show
    // a brief spinner.
    final isEdit = _editingMessageId != null;

    // Capture the reply target BEFORE clearing the composer below: the
    // optimistic-UI path calls _cancelReply() synchronously, which nulls
    // _replyingToMessageId. Reading the field later (in _runSendOrEdit)
    // would always see null and the reply link would never be sent.
    final replyToMessageId = _replyingToMessageId;

    if (!isEdit) {
      // Clear the composer synchronously so the keyboard stays focused and
      // the text is gone before the encryption/network work even starts.
      _messageController.clear();
      _cancelReply();
      // Re-focus the text field so the user can keep typing without an
      // extra tap.  requestFocus is cheap and runs on the next frame.
      _focusNode.requestFocus();
      _scrollToBottom(animate: true);
    }

    if (isEdit) {
      setState(() => _isSending = true);
    }

    // Fire the actual send/edit and all its post-processing into a
    // background future.  We still surface failures via a SnackBar, but
    // the composer + UI are already in their post-send state by the time
    // the user sees the bubble appear in the list.
    unawaited(
      _runSendOrEdit(
        isEdit: isEdit,
        text: text,
        chatSvc: chatSvc,
        scaffoldMessenger: scaffoldMessenger,
        currentUserId: currentUserId,
        replyToMessageId: replyToMessageId,
      ),
    );
  }

  Future<void> _runSendOrEdit({
    required bool isEdit,
    required String text,
    required ChatService chatSvc,
    required ScaffoldMessengerState scaffoldMessenger,
    required String? currentUserId,
    String? replyToMessageId,
  }) async {
    String? editingId;
    if (isEdit) {
      editingId = _editingMessageId;
      if (editingId == null) {
        if (mounted) setState(() => _isSending = false);
        return;
      }
    }
    try {
      if (isEdit) {
        await chatSvc.editMessage(
          matchId: widget.matchId,
          messageId: editingId!,
          newText: text,
        );
        if (mounted) _cancelEditing();
      } else {
        await chatSvc.sendMessage(
          matchId: widget.matchId,
          text: text,
          replyToMessageId: replyToMessageId,
        );
        // Note: we already cleared the controller / reply in the caller
        // for the optimistic-UI path.  This call is a defensive no-op
        // for the cold-path where the caller didn't run (e.g. offline
        // dialog returned without cancelling the request).
      }

      // Post-send bookkeeping — none of this is on the critical UI path,
      // so fire-and-forget.  The optimistic message is already in the
      // local DB and emitted by the watch stream; we intentionally do
      // NOT invalidate `chatMessagesProvider` here because doing so
      // discards the current provider state and forces a full rebuild +
      // re-subscribe on every send.
      if (currentUserId != null) {
        unawaited(
          Future(() async {
            try {
              await ref
                  .read(localDbProvider)
                  .clearUnreadForMatch(currentUserId, widget.matchId);
            } catch (_) {}
            try {
              ref.invalidate(recentChatsProvider(currentUserId));
            } catch (_) {}
          }),
        );
      }
    } catch (e) {
      try {
        final l10n = ref.read(localizationProvider);
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.getString(errorKey))),
        );
      } catch (_) {}
    } finally {
      if (isEdit && mounted) setState(() => _isSending = false);
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

  // ── In-chat search ────────────────────────────────────────────────

  void _toggleChatSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _searchQuery = '';
        _searchMatchIds = const [];
        _searchCurrentIndex = -1;
        _pendingInitialMessageId = null;
        _focusNode.requestFocus();
      }
    });
    if (_isSearching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  void _closeChatSearch() {
    if (!_isSearching) return;
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchQuery = '';
      _searchMatchIds = const [];
      _searchCurrentIndex = -1;
      _pendingInitialMessageId = null;
    });
  }

  /// Recomputes [_searchMatchIds] from the currently loaded messages.
  ///
  /// Called on every keystroke (cheap: a linear scan over in-memory models)
  /// and whenever the message list changes while a query is active, so newly
  /// arriving messages — and newly cached translations — join the results.
  ///
  /// Auto-scrolls only when there is something new to show: the first match
  /// appearing for a fresh query, or the previously viewed match no longer
  /// matching (then the newest match is shown). Typing another character
  /// while the current match still matches only updates the highlight/count
  /// without yanking the list.
  void _updateChatSearchMatches(List<ChatMessageModel> messages) {
    final needle = _searchQuery.trim().toLowerCase();
    if (needle.isEmpty) {
      if (_searchMatchIds.isNotEmpty || _searchCurrentIndex != -1) {
        setState(() {
          _searchMatchIds = const [];
          _searchCurrentIndex = -1;
        });
      }
      return;
    }
    final matches = <String>[];
    for (final m in messages) {
      if (chatSearchMessageMatches(m, needle)) matches.add(m.id);
    }
    // Preserve the current match when the list refreshes (e.g. a new message
    // arrives): keep pointing at the same message id when it still matches.
    final currentId =
        (_searchCurrentIndex >= 0 &&
            _searchCurrentIndex < _searchMatchIds.length)
        ? _searchMatchIds[_searchCurrentIndex]
        : null;
    int newIndex = -1;
    if (currentId != null) {
      newIndex = matches.indexOf(currentId);
    }
    // Chats-list handoff: land on the list-found (newest) message when it
    // still matches after load. Consumed once so later refreshes behave
    // like a normal in-chat search.
    final pendingId = _pendingInitialMessageId;
    if (pendingId != null && pendingId.isNotEmpty) {
      _pendingInitialMessageId = null;
      final pendingIndex = matches.indexOf(pendingId);
      if (pendingIndex >= 0) {
        if (!_listEquals(_searchMatchIds, matches) ||
            _searchCurrentIndex != pendingIndex) {
          setState(() {
            _searchMatchIds = matches;
            _searchCurrentIndex = pendingIndex;
          });
          _scrollToSearchMatch();
        }
        return;
      }
    }
    // Fresh query (or previous match gone): land on the newest match.
    final hadCurrent = currentId != null && newIndex >= 0;
    newIndex = newIndex >= 0 ? newIndex : (matches.isEmpty ? -1 : matches.length - 1);
    final needsScroll = newIndex >= 0 && !hadCurrent;
    if (!_listEquals(_searchMatchIds, matches) ||
        _searchCurrentIndex != newIndex) {
      setState(() {
        _searchMatchIds = matches;
        _searchCurrentIndex = newIndex;
      });
      if (needsScroll) {
        _scrollToSearchMatch();
      }
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onSearchQueryChanged(String value, List<ChatMessageModel> messages) {
    if (_searchQuery == value) return;
    _searchQuery = value;
    // _updateChatSearchMatches rebuilds when the match list or index changes.
    // When typing keeps the same matches (e.g. narrowing "gym" -> "gym?"),
    // the highlight still needs a rebuild for the new needle.
    final beforeIds = _searchMatchIds;
    final beforeIndex = _searchCurrentIndex;
    _updateChatSearchMatches(messages);
    if (identical(_searchMatchIds, beforeIds) &&
        _searchCurrentIndex == beforeIndex &&
        mounted) {
      setState(() {});
    }
  }

  void _stepSearchMatch(int delta) {
    if (_searchMatchIds.isEmpty) return;
    var next = _searchCurrentIndex + delta;
    if (next < 0) next = _searchMatchIds.length - 1;
    if (next >= _searchMatchIds.length) next = 0;
    setState(() => _searchCurrentIndex = next);
    _scrollToSearchMatch();
  }

  /// Scrolls the current match into view.
  ///
  /// The list is virtualized (`ListView.builder`), so an off-screen match has
  /// no `BuildContext` yet. We first jump to the target's proportional place
  /// in the *full* message list (offset 0 = newest at the bottom, max extent =
  /// oldest at the top — the list is `reverse: true`), which materializes the
  /// target, then `ensureVisible` fine-tunes. Positioning by the message's
  /// rank in the conversation (not its rank among matches) is what puts the
  /// newest match on screen when only a few of many messages match.
  void _scrollToSearchMatch({bool animate = true}) {
    if (_searchCurrentIndex < 0 ||
        _searchCurrentIndex >= _searchMatchIds.length) {
      return;
    }
    final targetId = _searchMatchIds[_searchCurrentIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      try {
        final ctx = _searchMessageKeys[targetId]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: animate
                ? const Duration(milliseconds: 300)
                : const Duration(milliseconds: 1),
            curve: Curves.easeOut,
            alignment: 0.5,
          );
          return;
        }
        // Target not built yet: jump to its neighbourhood to materialize it,
        // then retry the precise scroll on the next frames.
        final messages =
            ref.read(chatMessagesProvider(widget.matchId)).asData?.value;
        final position = _scrollController.position;
        final max = position.maxScrollExtent;
        if (max <= 0) return;
        double fraction = 0.0;
        if (messages != null && messages.length > 1) {
          final msgIndex = messages.indexWhere((m) => m.id == targetId);
          if (msgIndex >= 0) {
            fraction = 1.0 - (msgIndex / (messages.length - 1));
          }
        }
        final offset = (max * fraction).clamp(0.0, max);
        Future<void> ensureAfterFrames() async {
          for (var attempt = 0; attempt < 3; attempt++) {
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted || !_scrollController.hasClients) return;
            final retryCtx = _searchMessageKeys[targetId]?.currentContext;
            if (retryCtx != null) {
              await Scrollable.ensureVisible(
                retryCtx,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: 0.5,
              );
              return;
            }
          }
        }

        if (animate) {
          _scrollController
              .animateTo(
                offset,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              )
              .then((_) {
                if (mounted) unawaited(ensureAfterFrames());
              });
        } else {
          _scrollController.jumpTo(offset);
          unawaited(ensureAfterFrames());
        }
      } catch (_) {}
    });
  }

  /// WhatsApp-style find-in-conversation bar: query field, `N of M` counter,
  /// previous/next chevrons and a close button.
  Widget _buildChatSearchBar(
    LocalizationState l10n,
    List<ChatMessageModel> messages,
  ) {
    final hasQuery = _searchQuery.trim().isNotEmpty;
    // Same auto-direction as the message composer: empty follows the UI
    // direction, typed text follows its first strong character so Hebrew
    // aligns right and English/Spanish aligns left.
    final searchIsRtl = hasQuery && _isRtl(_searchQuery.trimLeft());
    final total = _searchMatchIds.length;
    final current = total == 0 || _searchCurrentIndex < 0
        ? 0
        : _searchCurrentIndex + 1;
    final countLabel = !hasQuery
        ? ''
        : total == 0
        ? l10n.getString('chatSearchNoResults')
        : l10n.getString(
            'chatSearchResultCount',
            params: {'current': '$current', 'total': '$total'},
          );

    return Material(
      elevation: 2,
      color: Theme.of(context).cardColor,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  // A chat opened from a list search arrives with its query
                  // pre-seeded and the keyboard already dismissed: do not
                  // steal focus (and pop the keyboard) in that case. Manual
                  // in-chat search still autofocuses as before.
                  autofocus:
                      (widget.initialSearchQuery ?? '').trim().isEmpty,
                  textInputAction: TextInputAction.search,
                  textDirection: !hasQuery
                      ? Directionality.of(context)
                      : (searchIsRtl
                            ? ui.TextDirection.rtl
                            : ui.TextDirection.ltr),
                  textAlign: !hasQuery
                      ? TextAlign.start
                      : (searchIsRtl ? TextAlign.right : TextAlign.left),
                  onChanged: (v) => _onSearchQueryChanged(v, messages),
                  onSubmitted: (_) {
                    if (_searchMatchIds.isNotEmpty) _stepSearchMatch(1);
                  },
                  decoration: InputDecoration(
                    hintText: l10n.getString('chatSearchHint'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.getString('generalClear'),
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchQueryChanged('', messages);
                              _searchFocusNode.requestFocus();
                            },
                          ),
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              if (hasQuery) ...[
                const SizedBox(width: 4),
                Semantics(
                  liveRegion: true,
                  label: countLabel,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 48),
                    child: Text(
                      countLabel,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
              // Prev/next only make sense with 2+ matches; a single match is
              // already on screen via the auto-scroll.
              if (total > 1) ...[
                IconButton(
                  tooltip: l10n.getString('chatSearchPrevious'),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: () => _stepSearchMatch(-1),
                ),
                IconButton(
                  tooltip: l10n.getString('chatSearchNext'),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => _stepSearchMatch(1),
                ),
              ],
              IconButton(
                tooltip: l10n.getString('chatSearchClose'),
                icon: const Icon(Icons.close),
                onPressed: _closeChatSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBlockDialog() async {
    final l10n = ref.read(localizationProvider);
    final didConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${l10n.getString('blockTitleWithName', params: {'name': widget.otherUserName})}?',
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
      if (shouldSkipSupabaseCalls()) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('blockNeedsOnline')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      final navigator = Navigator.of(context);
      final scaffoldMessenger = ScaffoldMessenger.of(context);
      final currentUserId = supabase.auth.currentUser!.id;
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
                '${widget.otherUserName} ${l10n.getString('blockSuccess')}',
              ),
              backgroundColor: Colors.green,
            ),
          );
          navigator.popUntil((route) => route.isFirst);
        }
      } catch (e) {
        if (mounted) {
          final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                '${l10n.getString('blockFailed')}: ${l10n.getString(errorKey)}',
              ),
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
      if (shouldSkipSupabaseCalls()) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('reportNeedsOnline')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
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
          final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                '${l10n.getString('reportFailed')}: ${l10n.getString(errorKey)}',
              ),
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
            // Pass cached location/rematch fields so the profile (incl. the
            // minimap) renders offline without a fresh DB fetch.
            matchOccurrence: found?.matchOccurrence ?? 1,
            user1Latitude: found?.user1Latitude,
            user1Longitude: found?.user1Longitude,
            user2Latitude: found?.user2Latitude,
            user2Longitude: found?.user2Longitude,
            mapCenterLat: found?.mapCenterLat,
            mapCenterLng: found?.mapCenterLng,
            mapZoom: found?.mapZoom,
            previousLocations: found?.previousLocations ?? const [],
            allMatchLocationsOverride: found?.allMatchLocations ?? const [],
            isRetroactive: found?.isRetroactive ?? false,
          ),
        ),
      );
    } catch (_) {}
  }

  bool _isSharingInThisChat() {
    final session = ref.watch(locationShareProvider);
    if (session == null || session.matchId != widget.matchId) return false;
    return session.myStatus == ShareStatus.sharing ||
        session.otherStatus == ShareStatus.sharing ||
        session.otherStatus == ShareStatus.unknown;
  }

  void _handleLocationShare() async {
    final l10n = ref.read(localizationProvider);
    final currentSession = ref.read(locationShareProvider);

    if (currentSession != null && currentSession.matchId == widget.matchId) {
      final iAmSharer = currentSession.myStatus == ShareStatus.sharing;
      final otherIsSharing = currentSession.otherStatus == ShareStatus.sharing;

      if (iAmSharer && !otherIsSharing) {
        _showShareOptionsSheet(currentSession);
        return;
      }
      if (otherIsSharing) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const LocationShareMapScreen(),
          ),
        );
        return;
      }
      // Stale session (nobody sharing) — fall through to re-check
    }

    final isOffline = shouldSkipSupabaseCalls();
    if (isOffline) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('locationShareOffline'))),
      );
      return;
    }

    // Check location permissions before starting location share
    final locationService = ref.read(locationServiceProvider);
    final hasPermission = await locationService.handleLocationPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('locationPermissionDenied')),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Check if other user is already sharing with us
    final hasExistingSignal = await ref
        .read(locationShareProvider.notifier)
        .hasActiveShareSignal(widget.matchId);

    if (hasExistingSignal) {
      // Receiver joining: view the map view-only (do not share location back immediately)
      final otherProfileAsync = ref.read(
        otherUserProfileProvider(widget.otherUserId),
      );
      final otherPhoto =
          otherProfileAsync.asData?.value?.photos.isNotEmpty == true
          ? otherProfileAsync.asData!.value!.photos[0]
          : null;
      ref
          .read(locationShareProvider.notifier)
          .viewExistingShare(
            matchId: widget.matchId,
            otherUserId: widget.otherUserId,
            otherUserName: widget.otherUserName,
            otherUserPhoto: otherPhoto,
          );

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const LocationShareMapScreen(),
          ),
        );
      }
      return;
    }

    // No existing session: start sharing and stay in chat
    final duration = await showDialog<Duration>(
      context: context,
      builder: (context) =>
          LocationShareDurationDialog(otherUserName: widget.otherUserName),
    );

    if (duration == null || !mounted) return;
    final Duration? effectiveDuration = duration == Duration.zero
        ? null
        : duration;

    final otherProfileAsync = ref.read(
      otherUserProfileProvider(widget.otherUserId),
    );
    final otherPhoto =
        otherProfileAsync.asData?.value?.photos.isNotEmpty == true
        ? otherProfileAsync.asData!.value!.photos[0]
        : null;
    ref
        .read(locationShareProvider.notifier)
        .startSharing(
          matchId: widget.matchId,
          otherUserId: widget.otherUserId,
          otherUserName: widget.otherUserName,
          otherUserPhoto: otherPhoto,
          duration: effectiveDuration,
        );

    // Stay in chat — the banner will update to show sharing status.
    // We do NOT navigate to the map: seeing only your own dot is meaningless.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('locationShareStarted')),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Shows a bottom sheet with sharing options for the initiator (User A).
  void _showShareOptionsSheet(dynamic session) async {
    final l10n = ref.read(localizationProvider);
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.share_location,
                        color: Colors.blue.shade700,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('locationShareBannerYouAreSharing'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            l10n
                                .getString('locationShareBannerSharingWith')
                                .replaceAll('{name}', widget.otherUserName),
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Change duration option
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.blue.shade50,
                  leading: Icon(
                    Icons.timer_outlined,
                    color: Colors.blue.shade700,
                  ),
                  title: Text(
                    l10n.getString('locationShareChangeDuration'),
                    style: TextStyle(color: Colors.blue.shade800),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _handleChangeDuration();
                  },
                ),
                const SizedBox(height: 10),
                // Stop sharing option
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.red.shade50,
                  leading: const Icon(
                    Icons.stop_circle_outlined,
                    color: Colors.red,
                  ),
                  title: Text(
                    l10n.getString('locationShareStop'),
                    style: const TextStyle(color: Colors.red),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await ref
                        .read(locationShareProvider.notifier)
                        .stopSharing();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Allows the sharer to extend/change the duration of an active session.
  Future<void> _handleChangeDuration() async {
    final l10n = ref.read(localizationProvider);
    final newDuration = await showDialog<Duration>(
      context: context,
      builder: (context) => LocationShareDurationDialog(
        otherUserName: widget.otherUserName,
        isChangingDuration: true,
      ),
    );
    if (newDuration == null || !mounted) return;
    final Duration? effectiveDuration = newDuration == Duration.zero
        ? null
        : newDuration;

    // Update duration without tearing down the session
    await ref
        .read(locationShareProvider.notifier)
        .updateDuration(effectiveDuration);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('locationShareDurationUpdated')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _addEmoji(String emoji) {
    final fullText = _messageController.text;
    final selection = _messageController.selection;
    final int start = (selection.start >= 0)
        ? selection.start
        : fullText.length;
    final int end = (selection.end >= 0) ? selection.end : fullText.length;
    // System pickers can insert text-default emoji (e.g. ⛱ U+26F1) without
    // VS16, which renders B&W. Qualify it so composer + bubbles stay color.
    final qualified = ensureEmojiPresentation(emoji);
    final newText = fullText.replaceRange(start, end, qualified);
    _messageController.text = newText;
    final int newOffset = start + qualified.length;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: newOffset),
    );

    // Emoji insertion can change inferred direction (e.g., inserting RTL emoji sequences)
    _updateComposerDirectionFromText();
  }

  void _updateComposerDirectionFromText([String? text]) {
    final raw = text ?? _messageController.text;
    final t = raw.trimLeft();
    final bool isEmpty = raw.trim().isEmpty;
    final bool isRtlText = _isRtl(t);
    final newDir = isRtlText ? ui.TextDirection.rtl : ui.TextDirection.ltr;
    if (newDir == _composerTextDirection && isEmpty == _composerIsEmpty) return;
    if (!mounted) {
      _composerTextDirection = newDir;
      _composerIsEmpty = isEmpty;
      return;
    }
    setState(() {
      _composerTextDirection = newDir;
      _composerIsEmpty = isEmpty;
    });
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

  bool get _hardwareEnterSendsMessage {
    // On desktop and web, plain Enter sends the message (WhatsApp Web style)
    // and Shift/Ctrl/Alt/Meta+Enter inserts a new line. On touch devices the
    // IME's Enter key inserts a new line and the send button submits.
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (!_hardwareEnterSendsMessage) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (_isSending) return KeyEventResult.handled;
    _submitComposer();
    return KeyEventResult.handled;
  }

  Widget _buildMessageContent(
    String text,
    TextStyle style,
    bool isOriginalRtl,
  ) {
    // Render historic messages (stored before VS16 fix) in color too.
    // RichText with native-first emoji runs: 2026 system designs win per
    // platform (Apple/Noto/Segoe), Twemoji bundled only as fallback.
    final qualified = ensureEmojiPresentation(text);
    final base = withEmojiFallback(style);
    return RichText(
      text: TextSpan(children: emojiAwareSpans(qualified, base)),
      textDirection: isOriginalRtl
          ? ui.TextDirection.rtl
          : ui.TextDirection.ltr,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final messagesAsyncValue = ref.watch(chatMessagesProvider(widget.matchId));
    final currentUserId = supabase.auth.currentUser!.id;
    final targetLanguage = ref.watch(translationProvider)[widget.matchId];

    ref.listen<String>(
      localizationProvider.select(
        (state) => normalizeLanguageCode(state.currentLocale.languageCode),
      ),
      (previous, next) {
        if (previous != next) {
          unawaited(_refreshTranslationsForCurrentLocale(force: true));
        }
      },
    );

    ref.listen<Map<String, String>>(translationProvider, (previous, next) {
      final previousTarget = previous?[widget.matchId];
      final nextTarget = next[widget.matchId];
      if (previousTarget != nextTarget && nextTarget != null) {
        unawaited(_refreshTranslationsForCurrentLocale(force: true));
      }
    });

    final otherUserProfileAsync = ref.watch(
      otherUserProfileProvider(widget.otherUserId),
    );
    final otherUserProfile = otherUserProfileAsync.asData?.value;
    final otherUserImage = otherUserProfile?.photos.isNotEmpty == true
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

        final bool isAtBottom =
            _scrollController.hasClients && _scrollController.offset < 100;
        final bool isFirstLoad = previous == null || previous is AsyncLoading;

        if (isAtBottom || isFirstLoad) {
          _scrollToBottom(animate: !isFirstLoad);
        }
      }

      // Keep in-chat search results live: newly arriving messages — and newly
      // cached translations flushing through the provider — join the matches.
      if (_isSearching &&
          _searchQuery.trim().isNotEmpty &&
          next is AsyncData) {
        _updateChatSearchMatches(nextList);
      }
    });

    // Listen for translation notifications for THIS match and show a SnackBar
    ref.listen<TranslationNotification?>(translationNotificationProvider, (
      prev,
      next,
    ) {
      final notif = next;
      if (notif != null && notif.matchId == widget.matchId && mounted) {
        final scaffold = ScaffoldMessenger.of(context);
        scaffold.showSnackBar(SnackBar(content: Text(notif.text)));
        // If we got the transient notification while the chat is open, clear the persisted pending flag
        final currentUser = supabase.auth.currentUser?.id;
        if (currentUser != null && currentUser.isNotEmpty) {
          // Fire-and-forget
          ref
              .read(localDbProvider)
              .clearTranslationNotificationPending(
                widget.matchId,
                userId: currentUser,
              );
        }
        // Clear immediately to avoid duplicate popups (provider also clears after delay)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(translationNotificationProvider.notifier).clear();
          }
        });
      }
    });

    // NOTE: the "pending translation-disabled notification" check used to
    // run inside `build()` via a `WidgetsBinding.addPostFrameCallback`,
    // which meant it was scheduled on *every* rebuild — and the chat
    // screen rebuilds many times while messages stream in, so the queue
    // of pending postFrameCallbacks grew without bound and each callback
    // did an async DB read, slowing the UI isolate.  We now perform this
    // check exactly once, from `initState()`, via [_checkPendingTranslationNotification].

    final chattingCaption = l10n.getString('chatYouAreChattingWith');
    final displayName = widget.otherUserName;

    return Directionality(
      textDirection: l10n.textDirection,
      // Back closes an open in-chat search first (WhatsApp behavior) instead
      // of leaving the conversation.
      child: PopScope(
        canPop: !_isSearching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _isSearching) _closeChatSearch();
        },
        child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 76,
          // Five action buttons squeeze the title column; without spacing
          // help the two-line title paints over the avatar (both Texts used
          // overflow: visible). Ellipsis keeps every line inside its box.
          titleSpacing: 4,
          title: GestureDetector(
            onTap: _navigateToProfile,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  child: otherUserImage != null
                      ? ClipOval(
                          child: SignedImage(
                            source: otherUserImage,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
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
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Four action buttons squeeze the title column; scale
                      // the caption down to fit rather than ellipsizing it
                      // mid-phrase ("You are chatting w…").
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          chattingCaption,
                          maxLines: 1,
                          softWrap: false,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
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
            IconButton(
              icon: Icon(
                Icons.search,
                color: _isSearching
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: l10n.getString('chatSearchTooltip'),
              onPressed: _toggleChatSearch,
            ),
            // No separate profile button: tapping the title (avatar + name)
            // already opens the profile, and a fifth action button leaves no
            // room for the title. The popup menu keeps a View-profile entry.
            IconButton(
              icon: Icon(
                _isSharingInThisChat()
                    ? Icons.location_on
                    : Icons.share_location,
                color: _isSharingInThisChat() ? Colors.green : null,
              ),
              tooltip: l10n.getString(
                _isSharingInThisChat()
                    ? 'locationShareView'
                    : 'locationShareStart',
              ),
              onPressed: _handleLocationShare,
            ),
            IconButton(
              onPressed: () async {
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                try {
                  final myLanguage = ref
                      .read(localizationProvider)
                      .currentLocale
                      .languageCode;
                  final currentTarget = ref.read(
                    translationProvider,
                  )[widget.matchId];
                  final isOffline = shouldSkipSupabaseCalls();

                  if (currentTarget == null) {
                    // User wants to ENABLE translations

                    // If offline, check if translations are available locally
                    if (isOffline) {
                      try {
                        final localDb = ref.read(localDbProvider);
                        final messages = await localDb.getMessages(
                          widget.matchId,
                        );

                        // Normalize the target language code
                        final normalizedLang = normalizeLanguageCode(
                          myLanguage,
                        );

                        // Check if translations for this language exist in local cache
                        final hasTranslations =
                            await TranslationCacheManager.hasTranslationsForLanguageInMatch(
                              normalizedLang,
                              messages,
                            );

                        if (!hasTranslations) {
                          // No translations available offline - show error dialog
                          final l10n = ref.read(localizationProvider);
                          if (!context.mounted) return;

                          await showDialog<void>(
                            context: context,
                            builder: (BuildContext context) => AlertDialog(
                              icon: const Icon(
                                Icons.cloud_off_rounded,
                                size: 32,
                              ),
                              title: Text(
                                l10n.getString(
                                  'offlineLanguageUnavailableTitle',
                                ),
                              ),
                              content: Text(
                                l10n.getString(
                                  'offlineLanguageUnavailableMessage',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(
                                    l10n.getString('offlineOkButton'),
                                  ),
                                ),
                              ],
                            ),
                          );
                          return;
                        }
                      } catch (e) {
                        debugPrint('Error checking offline translations: $e');
                        // On error, show generic offline message
                        final l10n = ref.read(localizationProvider);
                        if (!context.mounted) return;

                        await showDialog<void>(
                          context: context,
                          builder: (BuildContext context) => AlertDialog(
                            icon: const Icon(Icons.cloud_off_rounded, size: 32),
                            title: Text(
                              l10n.getString('offlineLanguageUnavailableTitle'),
                            ),
                            content: Text(
                              l10n.getString(
                                'offlineLanguageUnavailableMessage',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(l10n.getString('offlineOkButton')),
                              ),
                            ],
                          ),
                        );
                        return;
                      }
                    }

                    // Either online or offline with translations available
                    await ref
                        .read(translationProvider.notifier)
                        .setTranslation(widget.matchId, myLanguage);
                  } else {
                    // User wants to DISABLE translations - always allowed
                    await ref
                        .read(translationProvider.notifier)
                        .setTranslation(widget.matchId, null);
                  }
                } catch (_) {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text(l10n.getString('errorGeneric'))),
                  );
                }
              },
              icon: Icon(
                targetLanguage == null
                    ? Icons.translate
                    : Icons.g_translate_rounded,
                color: targetLanguage == null
                    ? Colors.black
                    : Colors.blue.shade200,
              ),
              tooltip: l10n.getString('chatTranslateToggle'),
            ),
            PopupMenuButton<String>(
              tooltip: l10n.getString('chatSafetyActions'),
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'profile') _navigateToProfile();
                if (value == 'block') _showBlockDialog();
                if (value == 'report') _showReportDialog();
              },
              itemBuilder: (context) => [
                // A ListTile inside a PopupMenuItem fights the popup's
                // intrinsic-height sizing and can overflow. A Row gives the
                // same visual with no layout conflict.
                PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      const Icon(Icons.person_outline, size: 22),
                      const SizedBox(width: 12),
                      Text(l10n.getString('profileTitle')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      const Icon(Icons.report_gmailerrorred, size: 22),
                      const SizedBox(width: 12),
                      Text(l10n.getString('reportTitle')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'block',
                  child: Row(
                    children: [
                      const Icon(Icons.block, color: Colors.red, size: 22),
                      const SizedBox(width: 12),
                      Text(
                        l10n.getString('blockButton'),
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            const OfflineIndicator(),
            if (_isSearching)
              _buildChatSearchBar(
                l10n,
                messagesAsyncValue.asData?.value ??
                    const <ChatMessageModel>[],
              ),
            LocationShareBanner(
              otherUserId: widget.otherUserId,
              otherUserName: widget.otherUserName,
              onViewMap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const LocationShareMapScreen(),
                  ),
                );
              },
              onStopSharing: () async {
                await ref.read(locationShareProvider.notifier).stopSharing();
              },
              onChangeDuration: _handleChangeDuration,
              onShareBack: () {
                // Receiver taps "Share back" — navigate to map where they can start sharing
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const LocationShareMapScreen(),
                  ),
                );
              },
            ),
            Expanded(
              child: Stack(
                children: [
                  ChatBackground(
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
                        return Center(
                          child: Text(l10n.getString('chatSayHello')),
                        );
                      }
                      // Build flat item list with date separators inserted
                      final items = <dynamic>[];
                      DateTime? lastDate;
                      for (final message in messages) {
                        final d = message.createdAt;
                        final messageDate = DateTime(d.year, d.month, d.day);
                        if (lastDate == null || messageDate != lastDate) {
                          items.add(messageDate);
                        }
                        items.add(message);
                        lastDate = messageDate;
                      }
                      // Reverse for ListView with reverse: true (index 0 = bottom)
                      final reversedItems = items.reversed.toList();

                      // In-chat search: highlight matches live from the rendered
                      // models so the highlight never lags the list by a frame.
                      final searchNeedle = _isSearching
                          ? _searchQuery.trim()
                          : '';
                      final searchNeedleLower = searchNeedle.toLowerCase();
                      final currentSearchId =
                          (_isSearching &&
                              _searchCurrentIndex >= 0 &&
                              _searchCurrentIndex < _searchMatchIds.length)
                          ? _searchMatchIds[_searchCurrentIndex]
                          : null;

                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8.0),
                        reverse: true,
                        itemCount: reversedItems.length,
                        itemBuilder: (context, index) {
                          final item = reversedItems[index];
                          if (item is DateTime) {
                            return _buildDateSeparator(context, l10n, item);
                          }
                          final message = item as ChatMessageModel;
                          final isMe = message.senderId == currentUserId;
                          final isSearchMatch =
                              searchNeedle.isNotEmpty &&
                              chatSearchMessageMatches(
                                message,
                                searchNeedleLower,
                              );
                          // A stable GlobalKey per message gives
                          // _scrollToSearchMatch something to ensureVisible.
                          // It lives on a lightweight wrapper so the bubble
                          // keeps its ValueKey for list diffing.
                          final anchorKey = _searchMessageKeys.putIfAbsent(
                            message.id,
                            () => GlobalKey(),
                          );
                          return Container(
                            key: anchorKey,
                            child: _MessageBubble(
                              key: ValueKey(message.id),
                              message: message,
                              isMe: isMe,
                              matchId: widget.matchId,
                              otherUserId: widget.otherUserId,
                              otherUserName: widget.otherUserName,
                              otherUserLastReadAt: otherUserLastReadAt,
                              messageContentBuilder: _buildMessageContent,
                              onRequestEdit: (id, text) =>
                                  _startEditingMessage(id, text),
                              onRequestReply: (id, text, senderId) =>
                                  _startReplyingMessage(id, text, senderId),
                              searchQuery: searchNeedle,
                              isSearchMatch: isSearchMatch,
                              isCurrentSearchMatch:
                                  currentSearchId == message.id,
                            ),
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
                                ref
                                    .read(chatSyncProvider(widget.matchId))
                                    .syncMessages(widget.matchId);
                              } catch (_) {}
                            },
                            child: Text(l10n.getString('generalRetry')),
                          ),
                        ],
                      ),
                    ),
                    error: (err, stack) => _buildMessageLoadError(l10n),
                      ),
                    ),
                  ),
                  // Jump-to-latest: appears once scrolled up or search lands
                  // on an older match. Standard in WhatsApp/Telegram.
                  if (_showJumpToLatest)
                    PositionedDirectional(
                      end: 16,
                      bottom: 16,
                      child: Semantics(
                        button: true,
                        label: l10n.getString('chatJumpToLatest'),
                        child: FloatingActionButton.small(
                          heroTag:
                              'chat_jump_latest_${widget.matchId}',
                          tooltip: l10n.getString('chatJumpToLatest'),
                          onPressed: _jumpToLatest,
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _buildMessageInputArea(),
            if (_showEmojiPicker)
              SizedBox(
                height: 300,
                // Force picker glyphs through bundled Twemoji so WYSIWYG
                // matches bubbles on every OS.
                child: DefaultTextStyle(
                  style: withEmojiFallback(
                    Theme.of(context).textTheme.bodyMedium ??
                        const TextStyle(fontSize: 28),
                  ),
                  child: EmojiPicker(
                    onEmojiSelected: (category, emoji) {
                      _addEmoji(emoji.emoji);
                    },
                  onBackspacePressed: () {
                    final controller = _messageController;
                    final text = controller.text;
                    final selection = controller.selection;
                    if (selection.baseOffset > 0) {
                      final newText =
                          text.substring(0, selection.baseOffset - 1) +
                          text.substring(selection.end);
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
              ),
          ],
        ),
        ),
      ),
    );
  }

  /// Error state for the message list.
  ///
  /// Never render the raw exception: it leaks schema/table/column names and
  /// network detail to the user, and it is not translatable. Everything the
  /// user needs is "we couldn't load this, here's a retry".
  Widget _buildMessageLoadError(LocalizationState l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.getString('chatMessagesLoadFailed'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () {
                try {
                  ref
                      .read(chatSyncProvider(widget.matchId))
                      .syncMessages(widget.matchId);
                } catch (_) {
                  // A failed retry is a no-op; the next open will try again.
                }
              },
              child: Text(l10n.getString('generalRetry')),
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
          children: [
            if (_replyingToMessageId != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 6.0,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 6.0,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 4.0,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              () {
                                final currentUserId =
                                    supabase.auth.currentUser?.id;
                                final isOwn =
                                    _replyingToSenderId != null &&
                                    _replyingToSenderId == currentUserId;
                                String youLabel() {
                                  try {
                                    final v = l10n.getString('chatReplyYou');
                                    if (v.trim().isNotEmpty &&
                                        !v.startsWith('chatReplyYou')) {
                                      return v;
                                    }
                                  } catch (_) {}
                                  return l10n.getString('chatReplyYou');
                                }

                                final target = isOwn
                                    ? youLabel()
                                    : (widget.otherUserName.trim().isNotEmpty
                                          ? widget.otherUserName
                                          : youLabel());
                                return '${l10n.getString('replyingToLabel')} $target';
                              }(),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.visible,
                            ),
                            const SizedBox(height: 4),
                            Builder(
                              builder: (context) {
                                final base = withEmojiFallback(
                                  Theme.of(context).textTheme.bodyMedium ??
                                      const TextStyle(),
                                );
                                return Text.rich(
                                  TextSpan(
                                    children: emojiAwareSpans(
                                      ensureEmojiPresentation(
                                        _replyingToSnippet ?? '',
                                      ),
                                      base,
                                    ),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        tooltip: l10n.getString('chatCancelReply'),
                        onPressed: _cancelReply,
                      ),
                    ],
                  ),
                ),
              ),
            if (_editingMessageId != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 6.0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.getString('chatEditingMessage'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
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
                  final isTyping =
                      ref
                          .watch(isOtherTypingProvider(_typingParams!))
                          .asData
                          ?.value ==
                      true;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: isTyping
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: _TypingRow(
                              name: widget.otherUserName,
                              otherUserId: widget.otherUserId,
                            ),
                          )
                        : const SizedBox.shrink(),
                  );
                },
              ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _showEmojiPicker
                        ? Icons.keyboard
                        : Icons.emoji_emotions_outlined,
                    color: Colors.grey,
                  ),
                  tooltip: l10n.getString('chatEmojiPicker'),
                  onPressed: _onEmojiPressed,
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: _handleComposerKeyEvent,
                    child: TextField(
                      controller: _messageController,
                      focusNode: _focusNode,
                      // Single-style field can't split emoji/text runs: on
                      // Android use system Roboto primary so 2026 system
                      // Noto/Samsung emoji wins (bundled Noto blocks system
                      // fallback). Elsewhere keep Noto Sans for digits.
                      style: withEmojiFallback(
                        (Theme.of(context).textTheme.bodyMedium ??
                                const TextStyle())
                            .copyWith(
                          fontSize: 16,
                          fontFamily:
                              foundation.defaultTargetPlatform ==
                                  TargetPlatform.android
                              ? 'Roboto'
                              : 'Noto Sans',
                        ),
                      ),
                      // When empty, align hint according to the current UI direction (Hebrew => RTL).
                      // Once the user types, follow the inferred direction of the typed text so
                      // LTR text (e.g. English) is shown LTR / left-aligned even when the UI is RTL,
                      // and RTL text is shown RTL / right-aligned. Uses _composerIsEmpty (state)
                      // instead of reading the controller directly so the widget rebuilds on the
                      // empty <-> non-empty transition.
                      textDirection: _composerIsEmpty
                          ? Directionality.of(context)
                          : _composerTextDirection,
                      textAlign: _composerIsEmpty
                          ? TextAlign.start
                          : (_composerTextDirection == ui.TextDirection.rtl
                                ? TextAlign.right
                                : TextAlign.left),
                      textCapitalization: TextCapitalization.sentences,
                      autocorrect: true,
                      enableSuggestions: true,
                      // Multi-line support: grows up to 6 lines, then scrolls internally.
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
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
                      onSubmitted: (_) => _submitComposer(),
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                if (_editingMessageId != null) ...[
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _cancelEditing,
                    tooltip: l10n.getString('generalCancel'),
                  ),
                  IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    onPressed: _canSubmitComposer ? _submitComposer : null,
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: l10n.getString('chatEditMessage'),
                  ),
                ] else ...[
                  IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: _canSubmitComposer ? _submitComposer : null,
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: l10n.getString('chatSendMessage'),
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

String _formatDateSeparator(LocalizationState l10n, DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final dateOnly = DateTime(date.year, date.month, date.day);

  if (dateOnly == today) {
    return l10n.getString('chatDayToday');
  } else if (dateOnly == yesterday) {
    return l10n.getString('chatDayYesterday');
  } else {
    return DateFormat.yMMMMd(l10n.currentLocale.toLanguageTag()).format(date);
  }
}

Widget _buildDateSeparator(
  BuildContext context,
  LocalizationState l10n,
  DateTime date,
) {
  final label = _formatDateSeparator(l10n, date);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8.0),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.matchId,
    required this.otherUserId,
    this.otherUserName = '',
    required this.otherUserLastReadAt,
    this.messageContentBuilder,
    this.onRequestEdit,
    this.onRequestReply,
    this.searchQuery = '',
    this.isSearchMatch = false,
    this.isCurrentSearchMatch = false,
  });

  final void Function(String messageId, String initialText)? onRequestEdit;
  final void Function(String messageId, String snippet, String senderId)?
  onRequestReply;

  final ChatMessageModel message;
  final bool isMe;
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final DateTime? otherUserLastReadAt;
  final Widget Function(String, TextStyle, bool)? messageContentBuilder;

  /// Raw (untrimmed) in-chat search query. When non-empty, every occurrence
  /// in the rendered original + translated text is highlighted.
  final String searchQuery;

  /// Whether this message matches the current in-chat search.
  final bool isSearchMatch;

  /// Whether this is the match the prev/next chevrons currently point at.
  /// Rendered with a stronger outline so it reads as "you are here".
  final bool isCurrentSearchMatch;

  Future<void> _openMessageOptions(
    BuildContext context,
    WidgetRef ref,
    String primaryText,
  ) async {
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
      onRequestReply?.call(message.id, primaryText, message.senderId);
    } else if (action == 'react') {
      try {
        await showReactionPicker(
          context,
          ref,
          matchId: matchId,
          messageId: message.id,
        );
      } catch (e) {
        debugPrint(
          'Failed to open reaction picker for message ${message.id}: $e',
        );
        try {
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text(l10n.getString('generalError'))),
          );
        } catch (_) {}
      }
    }
  }

  /// WhatsApp-style quoted reply block: colored side bar, sender label, and
  /// the original message preview. When chat translation is on and a
  /// translation of the quoted message is available, the translated text is
  /// shown prominently with the original below it; otherwise the original.
  /// When the original message can't be resolved (e.g. deleted), a subtle
  /// placeholder is shown instead of hiding the reply entirely.
  Widget _buildReplyQuote(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    bool isDark,
    bool translationEnabled,
  ) {
    final currentUserId = supabase.auth.currentUser?.id;
    final quotedOriginal = (message.replyToContent ?? '').trim();
    final storedTranslated = (message.replyToContentTranslated ?? '').trim();
    final hasOriginal = quotedOriginal.isNotEmpty;
    final hasStoredTranslation =
        storedTranslated.isNotEmpty && storedTranslated != quotedOriginal;
    final isQuoteFromMe =
        message.replyToSenderId != null &&
        message.replyToSenderId!.isNotEmpty &&
        message.replyToSenderId == currentUserId;

    // Live translation of the quoted message for the current UI language.
    // Reuses the same pipeline as main bubbles so quotes stay translated
    // even after a language switch (stored preview may be stale).
    String? liveTranslated;
    if (translationEnabled &&
        !isQuoteFromMe &&
        hasOriginal &&
        message.replyToMessageId != null &&
        message.replyToMessageId!.isNotEmpty) {
      try {
        final asyncVal = ref.watch(
          translationFamilyProvider(
            jsonEncode({
              'text': quotedOriginal,
              'matchId': matchId,
              'messageId': message.replyToMessageId!,
              'otherUserId': otherUserId,
            }),
          ),
        );
        final v = asyncVal.asData?.value;
        if (v != null && v.trim().isNotEmpty && v.trim() != quotedOriginal) {
          liveTranslated = v.trim();
        }
      } catch (_) {}
    }
    final quotedTranslated =
        liveTranslated ?? (hasStoredTranslation ? storedTranslated : null);
    final showTranslated =
        translationEnabled &&
        !isQuoteFromMe &&
        quotedTranslated != null &&
        quotedTranslated.isNotEmpty;

    String youLabel() {
      try {
        final v = l10n.getString('chatReplyYou');
        if (v.trim().isNotEmpty && !v.startsWith('chatReplyYou')) return v;
      } catch (_) {}
      return l10n.getString('chatReplyYou');
    }

    String unavailableLabel() {
      try {
        final v = l10n.getString('chatReplyOriginalUnavailable');
        if (v.trim().isNotEmpty &&
            !v.startsWith('chatReplyOriginalUnavailable')) {
          return v;
        }
      } catch (_) {}
      return l10n.getString('chatReplyOriginalUnavailable');
    }

    final senderLabel = isQuoteFromMe
        ? youLabel()
        : (otherUserName.trim().isNotEmpty ? otherUserName : youLabel());
    final accent = isMe
        ? (isDark ? Colors.green.shade300 : Colors.green.shade700)
        : Theme.of(context).colorScheme.primary;
    final quoteBg =
        (isMe
                ? (isDark ? Colors.black : Colors.black87)
                : Theme.of(context).colorScheme.onSurface)
            .withValues(alpha: 0.06);
    // Primary quote line: translated when available, else original, else placeholder.
    final qt = quotedTranslated;
    final rawPrimary = (showTranslated && qt != null && qt.isNotEmpty)
        ? qt
        : (hasOriginal ? quotedOriginal : unavailableLabel());
    // Qualify stored quotes so pre-fix rows (bare ⛱) show color.
    final primaryText = ensureEmojiPresentation(rawPrimary);
    final primaryRtl = _isRtl(primaryText);
    final isPlaceholder = !hasOriginal;
    // Secondary line: the original under the translation (mirrors main bubbles).
    final secondaryText = (showTranslated && hasOriginal)
        ? ensureEmojiPresentation(quotedOriginal)
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 6.0),
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: quoteBg,
        borderRadius: BorderRadius.circular(6.0),
        border: Border(left: BorderSide(color: accent, width: 4.0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            senderLabel,
            maxLines: 2,
            overflow: TextOverflow.visible,
            style: TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Builder(
            builder: (context) {
              final base = withEmojiFallback(
                Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: isPlaceholder
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.color
                          ?.withValues(alpha: isPlaceholder ? 0.6 : 1.0),
                    ) ??
                    TextStyle(
                      fontStyle: isPlaceholder
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
              );
              return Text.rich(
                TextSpan(children: emojiAwareSpans(primaryText, base)),
                maxLines: 2,
                overflow: TextOverflow.visible,
                textDirection: primaryRtl
                    ? ui.TextDirection.rtl
                    : ui.TextDirection.ltr,
              );
            },
          ),
          if (secondaryText != null) ...[
            const SizedBox(height: 2),
            Builder(
              builder: (context) {
                final base = withEmojiFallback(
                  Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.color
                            ?.withValues(alpha: 0.65),
                      ) ??
                      const TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                );
                return Text.rich(
                  TextSpan(children: emojiAwareSpans(secondaryText, base)),
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  textDirection: _isRtl(secondaryText)
                      ? ui.TextDirection.rtl
                      : ui.TextDirection.ltr,
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Renders [text] with every case-insensitive occurrence of [searchQuery]
  /// highlighted. Only highlights when this bubble is a search match, so the
  /// highlight and the result count can never disagree.
  Widget _buildSearchableMessageText(
    String text,
    TextStyle style,
    bool isRtl,
  ) {
    // Qualify for display so old rows without VS16 still show color.
    // Emoji runs use native-first system fonts (2026 designs); text runs
    // keep Noto. Highlight bg is preserved on emoji runs, weight stays
    // normal for emoji (bold makes Android CBDT transparent).
    text = ensureEmojiPresentation(text);
    final effectiveStyle = withEmojiFallback(style);
    final query = searchQuery.trim();
    if (query.isEmpty ||
        !isSearchMatch ||
        !text.toLowerCase().contains(query.toLowerCase())) {
      if (messageContentBuilder != null) {
        return messageContentBuilder!(text, effectiveStyle, isRtl);
      }
      return RichText(
        text: TextSpan(children: emojiAwareSpans(text, effectiveStyle)),
        textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      );
    }
    final highlightBg = isCurrentSearchMatch
        ? Colors.deepOrange.withValues(alpha: 0.45)
        : Colors.yellow.withValues(alpha: 0.65);
    final spans = chatSearchSplitMatches(text, query);
    return RichText(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      text: TextSpan(
        children: [
          for (final (segment, isMatch) in spans)
            if (!isMatch)
              ...emojiAwareSpans(segment, effectiveStyle)
            else
              ...emojiAwareSpans(
                segment,
                effectiveStyle.copyWith(
                  backgroundColor: highlightBg,
                  fontWeight: FontWeight.bold,
                ),
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final alignment = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // Modern bubble palette (WhatsApp/Telegram-style, lighter):
    // light outgoing mint, incoming pure white for contrast on the cream
    // canvas; dark uses WhatsApp blue-black tones.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const outgoingLight = Color(0xFFD9FDD3);
    const outgoingDark = Color(0xFF005C4B);
    const incomingLight = Color(0xFFFFFFFF);
    const incomingDark = Color(0xFF1F2C34);

    final color = isMe
        ? (isDark ? outgoingDark : outgoingLight)
        : (isDark ? incomingDark : incomingLight);

    final textColor = isMe
        ? (isDark ? Colors.white : Colors.black87)
        : (Theme.of(context).textTheme.bodyMedium?.color ??
              Theme.of(context).colorScheme.onSurface);

    Icon? readReceiptIcon;
    String? readReceiptLabel;
    if (isMe) {
      if (message.isPending) {
        readReceiptIcon = Icon(
          Icons.watch_later_outlined,
          size: 16,
          color: Colors.grey,
        );
        readReceiptLabel = l10n.getString('chatMessageStatusQueued');
      } else if (message.readAt != null) {
        readReceiptIcon = Icon(
          Icons.done_all,
          size: 16,
          color: Colors.blue.shade400,
        );
        readReceiptLabel = l10n.getString('chatMessageStatusRead');
      } else if (message.deliveredAt != null) {
        readReceiptIcon = Icon(Icons.done_all, size: 16, color: Colors.grey);
        readReceiptLabel = l10n.getString('chatMessageStatusDelivered');
      } else {
        readReceiptIcon = Icon(Icons.done, size: 16, color: Colors.grey);
        readReceiptLabel = l10n.getString('chatMessageStatusSent');
      }
    }

    // Target language = current UI locale (not the stale per-match toggle state)
    final translationPrefs = ref.watch(translationProvider);
    final translationEnabled = translationPrefs[matchId] != null;
    final targetLanguage = translationEnabled
        ? normalizeLanguageCode(
            ref.watch(localizationProvider).currentLocale.languageCode,
          )
        : null;

    // Translation logic:
    // 1. If we already have translation for the target language -> show it (no waiting)
    // 2. If we have translation for a DIFFERENT language -> need to re-translate
    // 3. If we have NO translation at all -> message might be in target language already, show original
    // Cached translations are local-device data. Trust them immediately only
    // when their saved target language matches the current UI language; otherwise
    // let translationFamilyProvider fetch/decrypt the correct target.
    // A v1 message that has not been decrypted yet (or whose cached plaintext
    // column was never populated) must not surface as the raw
    // content_original_encrypted blob — the user cannot read it. Fall back to
    // the loading state until Phase 2 / translationFamilyProvider decrypt it.
    final displayOriginal = message.contentOriginal.isNotEmpty
        ? message.contentOriginal
        : (message.isEncrypted ? l10n.getString('generalLoading') : '');
    final safeDisplayOriginal = looksLikeEncryptedBlob(displayOriginal)
        ? l10n.getString('generalLoading')
        : displayOriginal;

    // NOTE: The old fast-path (`hasTranslationForTarget`) checked whether
    // `translatedLang` matched the current UI language and, if so, used
    // `contentTranslated` directly.  This broke when the user switched
    // languages because `translated_target_language` in the DB could be
    // updated to the new language while the local `contentTranslated`
    // plaintext still held the stale translation from the previous language.
    // Since all messages are v1-encrypted now, always go through
    // `translationFamilyProvider` which decrypts the authoritative
    // `content_translated_encrypted` column for the current UI language.
    final shouldEvaluateTranslation =
        targetLanguage != null && !isMe && message.contentOriginal.isNotEmpty;

    AsyncValue<String>? translationAsync;
    String? translatedData;
    if (shouldEvaluateTranslation) {
      translationAsync = ref.watch(
        translationFamilyProvider(
          jsonEncode({
            'text': message.contentOriginal,
            'matchId': matchId,
            'messageId': message.id,
            'otherUserId': otherUserId,
          }),
        ),
      );
      translatedData = translationAsync?.asData?.value;
    }

    // The bubble shows the decrypted original IMMEDIATELY. The translation
    // appears below the divider when it arrives (via translationFamilyProvider
    // or Phase 2). Previously this branch replaced the original text with
    // l10n.getString('generalLoading') for fresh incoming messages, which
    // meant even after Phase 2 decrypted the original plaintext, the bubble
    // stayed on "Loading..." until the translation (an out-of-process Edge
    // Function + DeepL round-trip) came back. That turned a sub-second
    // decrypt into a multi-second wait, with no visual feedback that the
    // original was already readable. The translated sub-line below the
    // divider still appears as soon as translatedData is non-null, so the
    // user gets the original first and the translation just below it.
    // Qualify stored text for display so pre-fix rows (bare ⛱) show color.
    final primaryText = ensureEmojiPresentation(safeDisplayOriginal);

    final bool isOriginalRtl = _isRtl(primaryText);
    // Show translated text if we have translation data and it's different from original
    final bool showTranslated =
        translatedData != null &&
        translatedData.trim().isNotEmpty &&
        !looksLikeEncryptedBlob(translatedData) &&
        translatedData.trim() != message.contentOriginal.trim();

    // Jumbo: emoji-only (1-3, display-time so history updates too) renders
    // tiered larger + normal weight so color COLR glyphs stay opaque (bold
    // can make Android emoji transparent). Bubble chrome is dropped below.
    final isJumbo = !showTranslated && isJumboEmoji(primaryText);
    final double jumboSize = isJumbo ? jumboFontSize(primaryText) : 16.0;
    final baseMessageStyle =
        Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(
              color: textColor,
              fontSize: jumboSize,
              fontWeight: isJumbo ? FontWeight.normal : null,
            ) ??
        TextStyle(
          color: textColor,
          fontSize: jumboSize,
          fontWeight: isJumbo ? FontWeight.normal : null,
        );
    final messageTextStyle = withEmojiFallback(baseMessageStyle);
    // WhatsApp/Messenger-style: emoji-only with no reply context, no
    // translation and no search highlight gets no bubble background.
    // Display-only, so previously sent emoji-only rows become bubbleless too.
    final isBubbleless =
        isJumbo &&
        message.replyToMessageId == null &&
        !isSearchMatch &&
        !isCurrentSearchMatch;
    String timeLabel;
    try {
      timeLabel = formatTimeOfDateTimeWithPrefs(
        context,
        ref,
        l10n,
        message.createdAt.toLocal(),
      );
    } catch (_) {
      // In test environments some providers (prefs/localization) may not be initialized; fall back to simple HH:MM
      final dt = message.createdAt.toLocal();
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      timeLabel = '$hh:$mm';
    }

    final bool hasReactions =
        (message.reactionSummary ?? {}).isNotEmpty ||
        message.myReaction != null;

    // Show original text immediately while translation loads,
    // then update in-place when translation completes.
    // Previously used SizedBox.shrink() which caused layout shifts
    // (messages "bouncing") when hidden bubbles suddenly appeared.

    final actionsHint = l10n.getString('chatMessageActionsHint');
    void openMessageActions() {
      unawaited(_openMessageOptions(context, ref, primaryText));
    }

    Future<void> toggleReaction() async {
      final newReaction = (message.myReaction == '❤️') ? null : '❤️';
      try {
        await ref
            .read(chatServiceProvider)
            .setReaction(
              matchId: matchId,
              messageId: message.id,
              reaction: newReaction,
            );
      } catch (_) {}
    }

    return Semantics(
      container: true,
      button: true,
      label: primaryText,
      hint: actionsHint,
      onTap: openMessageActions,
      onLongPress: openMessageActions,
      child: InkWell(
        onTap: openMessageActions,
        onLongPress: openMessageActions,
        onDoubleTap: toggleReaction,
        child: Padding(
          // Tighter stacking for consecutive bubbleless jumbo (WhatsApp grouping).
          padding: EdgeInsets.only(
            left: isMe ? 56.0 : 8.0,
            right: isMe ? 8.0 : 56.0,
            top: isBubbleless ? 2.0 : 4.0,
            bottom: isBubbleless ? 2.0 : 4.0,
          ),
          child: Column(
            crossAxisAlignment: alignment,
            children: [
              Align(
                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: IntrinsicWidth(
                  stepWidth: 1.0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    child: Container(
                      key: Key('message_bubble_${message.id}'),
                      padding: EdgeInsets.symmetric(
                        horizontal: isBubbleless ? 4.0 : 12.0,
                        vertical: isBubbleless ? 2.0 : 8.0,
                      ),
                      decoration: isBubbleless
                          ? null
                          : BoxDecoration(
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
                              border: isCurrentSearchMatch
                                  ? Border.all(
                                      color: Colors.deepOrange,
                                      width: 2,
                                    )
                                  : isSearchMatch
                                  ? Border.all(
                                      color: Colors.deepOrange.withValues(
                                        alpha: 0.35,
                                      ),
                                      width: 1,
                                    )
                                  : null,
                              // Subtle lift so white/green read on cream;
                              // search-match glow takes precedence when active.
                              boxShadow: isCurrentSearchMatch
                                  ? [
                                      BoxShadow(
                                        color: Colors.deepOrange.withValues(
                                          alpha: 0.35,
                                        ),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : [
                                      const BoxShadow(
                                        color: Color(0x14000000),
                                        blurRadius: 1,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
                            ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (message.replyToMessageId != null)
                            _buildReplyQuote(
                              context,
                              ref,
                              l10n,
                              isDark,
                              translationEnabled,
                            ),
                          // Translation hierarchy: translated is hero (16px
                          // normal, full color), original is context (13px
                          // italic muted). Display-only, so history updates.
                          Builder(
                            builder: (context) {
                              final originalSecondary =
                                  withEmojiFallback(
                                    TextStyle(
                                      color: textColor.withValues(alpha: 0.65),
                                      fontStyle: FontStyle.italic,
                                      fontSize: showTranslated ? 13 : null,
                                    ),
                                  );
                              return Align(
                                alignment: isOriginalRtl
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: _buildSearchableMessageText(
                                  primaryText,
                                  showTranslated
                                      ? originalSecondary
                                      : messageTextStyle,
                                  isOriginalRtl,
                                ),
                              );
                            },
                          ),
                          if (showTranslated)
                            const Divider(height: 12, thickness: 0.5),
                          if (showTranslated)
                            Builder(
                              builder: (context) {
                                final td = ensureEmojiPresentation(
                                  translatedData!,
                                );
                                final bool isTranslatedRtl = _isRtl(td);
                                // Hero style: full-size normal, full color.
                                final translatedStyle = withEmojiFallback(
                                  TextStyle(
                                    color: textColor,
                                    fontStyle: FontStyle.normal,
                                    fontSize: 16,
                                  ),
                                );
                                return Align(
                                  alignment: isTranslatedRtl
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: _buildSearchableMessageText(
                                    td,
                                    translatedStyle,
                                    isTranslatedRtl,
                                  ),
                                );
                              },
                            ),
                          // When the query matched only via the translation,
                          // say so — otherwise the highlight sits on text the
                          // user may not be able to read in the original.
                          if (isSearchMatch &&
                              searchQuery.trim().isNotEmpty &&
                              chatSearchMatchedField(
                                    message,
                                    searchQuery.trim().toLowerCase(),
                                  ) ==
                                  'translated')
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.translate,
                                    size: 12,
                                    color: textColor.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      l10n.getString(
                                        'chatSearchMatchedInTranslation',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 11,
                                            fontStyle: FontStyle.italic,
                                            color: textColor.withValues(
                                              alpha: 0.6,
                                            ),
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          // Timestamp and optional read receipt placed inside the bubble at the bottom-right.
                          // Bubbleless jumbo sits on its own side (WhatsApp-style) so the time doesn't float to the far edge.
                          SizedBox(height: isBubbleless ? 2 : 6),
                          Align(
                            alignment: isBubbleless
                                ? (isMe
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft)
                                : Alignment.bottomRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Debug wrapper shows font family & features in debug builds
                                Text(
                                  timeLabel,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: isBubbleless
                                            ? Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.color
                                                  ?.withValues(alpha: 0.6)
                                            : textColor.withValues(
                                                alpha: 0.85,
                                              ),
                                        fontSize: isBubbleless ? 11 : 12,
                                      ),
                                ),
                                if (message.editedAt != null) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: (() {
                                      try {
                                        return formatTimeOfDateTimeWithPrefs(
                                          context,
                                          ref,
                                          l10n,
                                          message.editedAt!.toLocal(),
                                        );
                                      } catch (_) {
                                        final dt = message.editedAt!.toLocal();
                                        final hh = dt.hour.toString().padLeft(
                                          2,
                                          '0',
                                        );
                                        final mm = dt.minute.toString().padLeft(
                                          2,
                                          '0',
                                        );
                                        return '$hh:$mm';
                                      }
                                    })(),
                                    child: Text(
                                      l10n.getString('chatEdited'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: isBubbleless
                                                ? Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color
                                                      ?.withValues(alpha: 0.6)
                                                : textColor.withValues(
                                                    alpha: 0.65,
                                                  ),
                                            fontSize: 10,
                                            fontStyle: FontStyle.italic,
                                          ),
                                    ),
                                  ),
                                ],
                                if (isMe && readReceiptIcon != null) ...[
                                  const SizedBox(width: 6),
                                  Semantics(
                                    label: readReceiptLabel,
                                    child: readReceiptIcon,
                                  ),
                                ],
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
                      alignment: isMe
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2.0,
                          vertical: 2.0,
                        ),
                        child: Transform.translate(
                          offset: const Offset(0, -2),
                          child: ReactionRow(
                            message: message,
                            matchId: matchId,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
              // Composer / Edit UI is below the message list
            ],
          ),
        ),
      ),
    );
  }
}

class ReactionRow extends ConsumerWidget {
  const ReactionRow({super.key, required this.message, required this.matchId});

  final ChatMessageModel message;
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = message.reactionSummary ?? {};
    if (summary.isEmpty && message.myReaction == null) {
      return const SizedBox.shrink();
    }

    final entries = summary.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

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
                await ref
                    .read(chatServiceProvider)
                    .setReaction(
                      matchId: matchId,
                      messageId: message.id,
                      reaction: newReaction,
                    );
                try {
                  ref.invalidate(chatMessagesProvider(matchId));
                } catch (_) {}
              } catch (e) {
                debugPrint('setReaction failed for message ${message.id}: $e');
                try {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text(l10n.getString('generalError'))),
                  );
                } catch (_) {}
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isMine
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmojiWidget(emoji: emoji, size: 14),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
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
  const MessageBubbleTestWrapper({
    super.key,
    required this.message,
    required this.isMe,
  });

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
  Future<List<Map<String, dynamic>>> Function(
    String messageId,
    String reaction,
  )?
  getReactorsFn,
  Map<String, int>? reactionSummary,
}) async {
  final l10n = ref.read(localizationProvider);
  final chatSvc = ref.read(chatServiceProvider);
  final localDb = ref.read(localDbProvider);
  final currentUserId = supabase.auth.currentUser?.id;

  final fetch =
      getReactorsFn ??
      ((String mid, String r) =>
          chatSvc.getReactors(messageId: mid, reaction: r));

  // Build set of reaction keys (from cache or provided summary)
  final Set<String> reactionKeys = {};
  try {
    final msg = await localDb.getMessageById(matchId, messageId);
    if (msg != null) {
      final reactorsContainer = msg['reactors'];
      if (reactorsContainer is Map) {
        reactionKeys.addAll(reactorsContainer.keys.map((k) => k.toString()));
      }
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
        try {
          await localDb.saveCachedReactors(matchId, messageId, rKey, server);
        } catch (_) {}
        reactors = server;
      } catch (_) {
        reactors = [];
      }
    }

    final seen = <String>{};
    for (final entry in reactors.where(
      (e) => e['user_id'] != null && seen.add(e['user_id'] as String),
    )) {
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
            try {
              await localDb.saveCachedReactors(matchId, messageId, rk, server);
            } catch (_) {}
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
    final needsName =
        m['display_name'] == null || (m['display_name'] as String).isEmpty;
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
          final reaction =
              (r['reaction'] is String && (r['reaction'] as String).isNotEmpty)
              ? (r['reaction'] as String)
              : emoji;

          final name = displayName?.isNotEmpty == true
              ? (() {
                  final parts = displayName!.trim().split(RegExp(r'\s+'));
                  if (parts.length > 1) {
                    return '\u200E${parts.first} ${parts.last[0]}.\u200E';
                  }
                  return '\u200E$displayName\u200E';
                })()
              : l10n.getString('generalUnknown');

          final isMe = uid != null && uid == currentUserId;

          return ListTile(
            leading: photo != null && photo.isNotEmpty
                ? SignedImage(
                    source: photo,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  )
                : const Icon(Icons.person),
            title: Text(name),
            subtitle: isMe
                ? Text(l10n.getString('chatReactorsTapToRemove'))
                : null,
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
                      try {
                        ref.invalidate(chatMessagesProvider(matchId));
                      } catch (_) {}
                      navigator.pop();
                    } catch (e) {
                      debugPrint(
                        'Failed to clear reaction for message $messageId: $e',
                      );
                      try {
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(l10n.getString('generalError')),
                          ),
                        );
                      } catch (_) {}
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

class _TypingRow extends ConsumerWidget {
  final String name;
  final String otherUserId;
  const _TypingRow({required this.name, required this.otherUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final profileAsync = ref.watch(userProfileProvider(otherUserId));
    final gender = profileAsync.asData?.value?.gender;
    final displayName = name.trim().isNotEmpty
        ? name.trim()
        : l10n.getString('generalUnknown');
    // Gender-aware lookup first (e.g. Hebrew מקליד vs מקלידה), with {name} substitution.
    final typed = l10n.getString(
      'chatIsTyping',
      gender: gender,
      params: {'name': displayName},
    );

    String text;
    if (typed.contains(displayName)) {
      text = typed;
    } else {
      // Fallback to base translation with name parameter.
      final baseWithName = l10n.getString(
        'chatIsTyping',
        params: {'name': displayName},
      );
      if (baseWithName.contains(displayName)) {
        text = baseWithName;
      } else {
        // Final fallback: prepend the name to the (possibly gendered) suffix.
        text = displayName.isNotEmpty ? '$displayName ${typed.trim()}' : typed;
      }
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ),
      ],
    );
  }
}
