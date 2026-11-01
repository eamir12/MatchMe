// lib/providers/notification_inbox_provider.dart
//
// State for the persistent notification inbox (public.user_notifications).
// Mirrors the lifecycle patterns of match_notification_provider: realtime
// subscription registered with SupabaseRealtimeManager, offline-safe initial
// load, cleanup on sign-out, and optimistic read/delete updates.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';

final supabase = Supabase.instance.client;

class NotificationInboxState {
  final List<NotificationInboxItem> items;
  final int unreadCount;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  const NotificationInboxState({
    this.items = const [],
    this.unreadCount = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
  });

  NotificationInboxState copyWith({
    List<NotificationInboxItem>? items,
    int? unreadCount,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return NotificationInboxState(
      items: items ?? this.items,
      unreadCount: unreadCount ?? this.unreadCount,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class NotificationInboxNotifier extends Notifier<NotificationInboxState> {
  RealtimeChannel? _channel;
  String _channelName = '';
  String _userId = '';
  bool _isLoadingMore = false;
  bool _isSettingUpChannel = false;
  void Function()? _resumeDispose;

  // Reconnect state for a dead channel (mirrors match_notification_provider).
  // A postgres_changes channel can report `subscribed` yet deliver nothing
  // when the server-side replication setup fails, and that verdict only
  // reaches the subscribe status callback. Without this, the channel stays
  // "active" in the manager forever and the inbox silently stops updating.
  static const int _maxReconnectAttempts = 5;
  int _reconnectAttempts = 0;
  DateTime? _lastReconnectAt;
  Timer? _reconnectTimer;

  // Rows that arrived over realtime while a fetch was in flight. The fetch
  // snapshot predates them, so they are merged back in after the fetch
  // instead of being clobbered until the next manual refresh.
  int _realtimeInsertSeq = 0;
  final Map<String, int> _realtimeInsertedAt = <String, int>{};

  NotificationInboxService get _service => NotificationInboxService.instance;

  int _countUnread(List<NotificationInboxItem> items) =>
      items.where((n) => n.isUnread).length;

  Duration _jitteredBackoff(int attempt) {
    final base = Duration(milliseconds: (1000 * math.pow(2, attempt)).round());
    final jitter = Duration(milliseconds: math.Random().nextInt(1000));
    return base + jitter;
  }

  Future<void> _cacheItems(List<NotificationInboxItem> items) async {
    try {
      await _service.cacheNotifications(_userId, items);
    } catch (error) {
      debugPrint('NotificationInbox: could not persist local snapshot: $error');
    }
  }

  @override
  NotificationInboxState build() {
    _reconnectAttempts = 0;
    _lastReconnectAt = null;
    ref.onDispose(() {
      _resumeDispose?.call();
      _resumeDispose = null;
      _teardownChannel();
    });

    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      _teardownChannel();
      _userId = '';
      return const NotificationInboxState();
    }
    _userId = userId;

    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      final authState = next.asData?.value;
      if (authState == null) return;
      if (authState.event == AuthChangeEvent.signedOut) {
        _reconnectAttempts = 0;
        _teardownChannel();
        _userId = '';
        state = const NotificationInboxState();
      }
    });

    _resumeDispose?.call();
    _resumeDispose = onSupabaseResume(() {
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
      if (shouldSkipSupabaseCalls()) return;
      if (_channel == null ||
          !SupabaseRealtimeManager.instance.isActive(_channelName)) {
        unawaited(_setupRealtime());
      }
      // Catch anything missed while offline.
      unawaited(refresh());
    });

    unawaited(_initialLoad());
    if (!shouldSkipSupabaseCalls()) {
      unawaited(_setupRealtime());
    } else {
      debugPrint('⏸️ Notification inbox: loading local snapshot - offline');
    }

    return const NotificationInboxState(isLoading: true);
  }

  Future<void> _initialLoad() async {
    try {
      List<NotificationInboxItem>? cached;
      try {
        cached = await _service.loadCachedNotifications(_userId);
      } catch (error) {
        debugPrint('NotificationInbox: could not read local snapshot: $error');
      }
      if (!ref.mounted || supabase.auth.currentUser?.id != _userId) return;
      if (cached != null) {
        state = state.copyWith(
          items: cached,
          unreadCount: _countUnread(cached),
          isLoading: !shouldSkipSupabaseCalls(),
          hasMore: cached.length >= NotificationInboxService.pageSize,
        );
      }
      if (shouldSkipSupabaseCalls()) {
        if (cached == null) {
          state = state.copyWith(isLoading: false, hasMore: false);
        }
        return;
      }

      final items = await _fetchLatestPage();
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
      await _cacheItems(items);
      state = state.copyWith(
        items: items,
        unreadCount: _countUnread(items),
        isLoading: false,
        hasMore: items.length >= NotificationInboxService.pageSize,
      );
    } catch (e) {
      debugPrint('NotificationInbox: initial load failed: $e');
      if (ref.mounted) state = state.copyWith(isLoading: false);
    }
  }

  /// Fetches the newest page and reconciles it with rows that arrived over
  /// realtime while the request was in flight. Those rows are newer than the
  /// query snapshot, so the server's page cannot contain them yet; without
  /// the merge they would vanish from the list until the next refresh.
  Future<List<NotificationInboxItem>> _fetchLatestPage() async {
    final seqAtStart = _realtimeInsertSeq;
    final page = await _service.fetchNotifications();
    if (!ref.mounted || _realtimeInsertedAt.isEmpty) return page;
    final fetchedIds = page.map((n) => n.id).toSet();
    final carried = state.items
        .where(
          (n) =>
              !fetchedIds.contains(n.id) &&
              (_realtimeInsertedAt[n.id] ?? 0) > seqAtStart,
        )
        .toList(growable: false);
    if (carried.isEmpty) return page;
    return [...carried, ...page];
  }

  Future<void> _setupRealtime() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    if (_isSettingUpChannel) return;
    if (_channel != null &&
        SupabaseRealtimeManager.instance.isActive(_channelName)) {
      return;
    }
    _isSettingUpChannel = true;
    try {
      final channelName = 'notification_inbox_$userId';
      _channelName = channelName;
      SupabaseRealtimeManager.instance.register(channelName, () {
        if (supabase.auth.currentSession == null) {
          throw Exception(
            'No active session — skipping notification inbox subscription',
          );
        }
        return _service.subscribeInbox(
          userId,
          _handleInsert,
          onUpdate: _handleUpdate,
          onDelete: _handleDelete,
          onSubscribeStatus: _handleSubscribeStatus,
        );
      });
      _channel = SupabaseRealtimeManager.instance.getChannel(channelName);
    } catch (e) {
      debugPrint('NotificationInbox: realtime setup failed: $e');
    } finally {
      _isSettingUpChannel = false;
    }
  }

  void _teardownChannel() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_channelName.isNotEmpty) {
      SupabaseRealtimeManager.instance.unregister(_channelName);
    }
    _channel = null;
    _channelName = '';
  }

  /// Realtime channel lifecycle. On `subscribed`, run a catch-up refresh: the
  /// server reports the join before postgres_changes replication is actually
  /// live, so rows inserted around that handshake are never delivered. On
  /// `channelError`/`closed`/`timedOut` the channel is dead (or can never
  /// deliver): unregister it so the manager stops treating it as active, and
  /// re-subscribe with backoff.
  void _handleSubscribeStatus(RealtimeSubscribeStatus status, Object? error) {
    if (!ref.mounted) return;
    if (supabase.auth.currentUser?.id != _userId) return;

    if (status == RealtimeSubscribeStatus.subscribed) {
      _reconnectAttempts = 0;
      // Catch anything inserted while the join was in flight or while the
      // channel was down.
      unawaited(refresh());
      return;
    }
    if (status != RealtimeSubscribeStatus.channelError &&
        status != RealtimeSubscribeStatus.closed &&
        status != RealtimeSubscribeStatus.timedOut) {
      return;
    }

    if (handleExpectedSupabaseOfflineFailure(error)) return;
    if (SupabaseRealtimeManager.instance.isPaused) return;
    // Dead refresh token / RLS rejection: hot-retrying just hammers the
    // backend. Session refresh + the onSupabaseResume path re-subscribe.
    if (error != null && isAuthRateLimitFailure(error)) return;
    // Intentional teardown (sign-out, provider dispose, user switch) already
    // removed the channel from the manager — nothing to recover.
    if (!SupabaseRealtimeManager.instance.isActive(_channelName)) return;

    debugPrint(
      'NotificationInbox: realtime status=$status error=$error — rebuilding channel',
    );
    _teardownChannel();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!ref.mounted) return;
    if (shouldSkipSupabaseCalls()) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint(
        'NotificationInbox: reconnect attempts exhausted ($_maxReconnectAttempts)',
      );
      return;
    }
    final now = DateTime.now();
    // Coalesce bursts of status events (error + closed often arrive together).
    if (_lastReconnectAt != null &&
        now.difference(_lastReconnectAt!) < const Duration(seconds: 8)) {
      return;
    }
    _lastReconnectAt = now;
    _reconnectAttempts++;
    final delay = _jitteredBackoff(_reconnectAttempts);
    debugPrint(
      'NotificationInbox: scheduling reconnect (attempt $_reconnectAttempts/$_maxReconnectAttempts, delay=${delay.inMilliseconds}ms)',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
      if (shouldSkipSupabaseCalls()) return;
      unawaited(_setupRealtime());
    });
  }

  void _handleInsert(NotificationInboxItem item) {
    if (!ref.mounted) return;
    if (item.deletedAt != null) return;
    if (state.items.any((n) => n.id == item.id)) return;
    final items = [item, ...state.items];
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    unawaited(_cacheItems(items));
    _realtimeInsertedAt[item.id] = ++_realtimeInsertSeq;
    if (_realtimeInsertedAt.length > 200) {
      final cutoff = _realtimeInsertSeq - 100;
      _realtimeInsertedAt.removeWhere((_, seq) => seq <= cutoff);
    }
  }

  /// Cross-device reconciliation for read_at / deleted_at changes: replaces
  /// the row in place, drops it when soft-deleted elsewhere, and recomputes
  /// the unread badge. Rows we haven't loaded (beyond the first page) are
  /// ignored — refresh() covers those.
  void _handleUpdate(NotificationInboxItem item) {
    if (!ref.mounted) return;
    if (item.deletedAt != null) {
      _handleDelete(item.id);
      return;
    }
    final index = state.items.indexWhere((n) => n.id == item.id);
    if (index == -1) return;
    final items = [...state.items];
    items[index] = item;
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    unawaited(_cacheItems(items));
  }

  void _handleDelete(String id) {
    if (!ref.mounted) return;
    if (!state.items.any((n) => n.id == id)) return;
    final items = state.items.where((n) => n.id != id).toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    unawaited(_cacheItems(items));
  }

  /// Reload the list from the server (used on pull-to-refresh and on resume).
  Future<void> refresh() async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final items = await _fetchLatestPage();
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
      await _cacheItems(items);
      state = state.copyWith(
        items: items,
        unreadCount: _countUnread(items),
        hasMore: items.length >= NotificationInboxService.pageSize,
      );
    } catch (e) {
      debugPrint('NotificationInbox: refresh failed: $e');
    }
  }

  Future<void> loadMore() async {
    if (shouldSkipSupabaseCalls()) return;
    if (_isLoadingMore || !state.hasMore || state.isLoading) return;
    _isLoadingMore = true;
    state = state.copyWith(isLoadingMore: true);
    try {
      final more = await _service.fetchNotifications(
        offset: state.items.length,
      );
      if (!ref.mounted) return;
      final existingIds = state.items.map((n) => n.id).toSet();
      final newItems = more.where((n) => !existingIds.contains(n.id)).toList();
      final items = [...state.items, ...newItems];
      await _cacheItems(items);
      state = state.copyWith(
        items: items,
        unreadCount: _countUnread(items),
        hasMore: more.length >= NotificationInboxService.pageSize,
      );
    } catch (e) {
      debugPrint('NotificationInbox: loadMore failed: $e');
    } finally {
      _isLoadingMore = false;
      if (ref.mounted) state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Returns [item] with [readAt] applied — the optimistic shape used by the
  /// single and batch read/unread mutations below.
  NotificationInboxItem _withReadAt(
    NotificationInboxItem item,
    DateTime? readAt,
  ) {
    return NotificationInboxItem(
      id: item.id,
      type: item.type,
      title: item.title,
      body: item.body,
      data: item.data,
      createdAt: item.createdAt,
      readAt: readAt,
      deletedAt: item.deletedAt,
    );
  }

  Future<void> markRead(String id) async {
    final items = state.items
        .map(
          (n) => n.id == id && n.isUnread ? _withReadAt(n, DateTime.now()) : n,
        )
        .toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    await _cacheItems(items);
    try {
      await _service.markRead(id);
    } catch (e) {
      debugPrint('NotificationInbox: markRead failed: $e');
    }
  }

  Future<void> markReadMany(Set<String> ids) async {
    if (ids.isEmpty) return;
    final items = state.items
        .map(
          (n) => ids.contains(n.id) && n.isUnread
              ? _withReadAt(n, DateTime.now())
              : n,
        )
        .toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    await _cacheItems(items);
    try {
      await _service.markReadMany(ids);
    } catch (e) {
      debugPrint('NotificationInbox: markReadMany failed: $e');
    }
  }

  /// Marks every unread row for [matchId] whose kind (data `kind`, falling
  /// back to the row type) is in [kinds] read. Surfaces that display the item
  /// itself — the live-location map, the chat — call this so the bell, the
  /// Matches badge and the OS icon clear the moment the item is seen, even
  /// when the row was never opened in the inbox.
  Future<void> markMatchKindsRead(String matchId, Set<String> kinds) async {
    final id = matchId.trim();
    if (id.isEmpty || kinds.isEmpty) return;
    final ids = state.items
        .where((n) {
          if (!n.isUnread || n.deletedAt != null) return false;
          final kind = n.data['kind']?.toString() ?? n.type;
          if (!kinds.contains(kind)) return false;
          final rowMatchId =
              (n.data['matchId'] ?? n.data['match_id'])?.toString().trim() ??
              '';
          return rowMatchId == id;
        })
        .map((n) => n.id)
        .toSet();
    if (ids.isEmpty) return;
    await markReadMany(ids);
  }

  Future<void> markUnreadMany(Set<String> ids) async {
    if (ids.isEmpty) return;
    final items = state.items
        .map(
          (n) => ids.contains(n.id) && !n.isUnread ? _withReadAt(n, null) : n,
        )
        .toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    await _cacheItems(items);
    try {
      await _service.markUnreadMany(ids);
    } catch (e) {
      debugPrint('NotificationInbox: markUnreadMany failed: $e');
    }
  }

  Future<void> delete(String id) async {
    final items = state.items.where((n) => n.id != id).toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    await _cacheItems(items);
    try {
      await _service.delete(id);
    } catch (e) {
      debugPrint('NotificationInbox: delete failed: $e');
      unawaited(refresh());
    }
  }

  Future<void> deleteMany(Set<String> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    final items = state.items.where((n) => !idSet.contains(n.id)).toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    await _cacheItems(items);
    try {
      await _service.deleteMany(idSet);
    } catch (e) {
      debugPrint('NotificationInbox: deleteMany failed: $e');
      unawaited(refresh());
    }
  }
}

final notificationInboxProvider =
    NotifierProvider<NotificationInboxNotifier, NotificationInboxState>(() {
      return NotificationInboxNotifier();
    });

final unreadInboxCountProvider = Provider<int>((ref) {
  return ref.watch(notificationInboxProvider).unreadCount;
});
