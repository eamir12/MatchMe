// lib/providers/notification_inbox_provider.dart
//
// State for the persistent notification inbox (public.user_notifications).
// Mirrors the lifecycle patterns of match_notification_provider: realtime
// subscription registered with SupabaseRealtimeManager, offline-safe initial
// load, cleanup on sign-out, and optimistic read/delete updates.

import 'dart:async';

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

  NotificationInboxService get _service => NotificationInboxService.instance;

  int _countUnread(List<NotificationInboxItem> items) =>
      items.where((n) => n.isUnread).length;

  @override
  NotificationInboxState build() {
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

    if (!shouldSkipSupabaseCalls()) {
      unawaited(_initialLoad());
      unawaited(_setupRealtime());
    } else {
      debugPrint('⏸️ Notification inbox: skipping initial load - offline');
    }

    return const NotificationInboxState(isLoading: true);
  }

  Future<void> _initialLoad() async {
    try {
      final items = await _service.fetchNotifications();
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
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
        return _service.subscribeInbox(userId, _handleInsert);
      });
      _channel = SupabaseRealtimeManager.instance.getChannel(channelName);
    } catch (e) {
      debugPrint('NotificationInbox: realtime setup failed: $e');
    } finally {
      _isSettingUpChannel = false;
    }
  }

  void _teardownChannel() {
    if (_channelName.isNotEmpty) {
      SupabaseRealtimeManager.instance.unregister(_channelName);
    }
    _channel = null;
    _channelName = '';
  }

  void _handleInsert(NotificationInboxItem item) {
    if (!ref.mounted) return;
    if (item.deletedAt != null) return;
    if (state.items.any((n) => n.id == item.id)) return;
    final items = [item, ...state.items];
    state = state.copyWith(
      items: items,
      unreadCount: _countUnread(items),
    );
  }

  /// Reload the list from the server (used on pull-to-refresh and on resume).
  Future<void> refresh() async {
    try {
      final items = await _service.fetchNotifications();
      if (!ref.mounted) return;
      if (supabase.auth.currentUser?.id != _userId) return;
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
    if (_isLoadingMore || !state.hasMore || state.isLoading) return;
    _isLoadingMore = true;
    state = state.copyWith(isLoadingMore: true);
    try {
      final more = await _service.fetchNotifications(
        offset: state.items.length,
      );
      if (!ref.mounted) return;
      final existingIds = state.items.map((n) => n.id).toSet();
      final newItems =
          more.where((n) => !existingIds.contains(n.id)).toList();
      final items = [...state.items, ...newItems];
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

  Future<void> markRead(String id) async {
    final items = state.items
        .map((n) => n.id == id && n.isUnread
            ? NotificationInboxItem(
                id: n.id,
                type: n.type,
                title: n.title,
                body: n.body,
                data: n.data,
                createdAt: n.createdAt,
                readAt: DateTime.now(),
                deletedAt: n.deletedAt,
              )
            : n)
        .toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    try {
      await _service.markRead(id);
    } catch (e) {
      debugPrint('NotificationInbox: markRead failed: $e');
    }
  }

  Future<void> markAllRead() async {
    final items = state.items
        .map((n) => n.isUnread
            ? NotificationInboxItem(
                id: n.id,
                type: n.type,
                title: n.title,
                body: n.body,
                data: n.data,
                createdAt: n.createdAt,
                readAt: DateTime.now(),
                deletedAt: n.deletedAt,
              )
            : n)
        .toList();
    state = state.copyWith(items: items, unreadCount: 0);
    try {
      await _service.markAllRead();
    } catch (e) {
      debugPrint('NotificationInbox: markAllRead failed: $e');
    }
  }

  Future<void> delete(String id) async {
    final items = state.items.where((n) => n.id != id).toList();
    state = state.copyWith(items: items, unreadCount: _countUnread(items));
    try {
      await _service.delete(id);
    } catch (e) {
      debugPrint('NotificationInbox: delete failed: $e');
      unawaited(refresh());
    }
  }

  Future<void> deleteAll() async {
    state = state.copyWith(items: const [], unreadCount: 0);
    try {
      await _service.deleteAll();
    } catch (e) {
      debugPrint('NotificationInbox: deleteAll failed: $e');
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
