import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A change to the signed-in user's own row in `public.users`.
class MyUserUpdate {
  const MyUserUpdate({
    required this.row,
    required this.changedKeys,
  });

  /// The new row, as delivered by the realtime event.
  ///
  /// Depending on the table's replica identity the payload may only carry the
  /// columns that actually changed, so consumers must treat a missing key as
  /// "unchanged" rather than "cleared".
  final Map<String, dynamic> row;

  /// The keys whose value differs from the previously seen row.
  ///
  /// Empty only for an event that changed nothing. The first event after a
  /// (re)connect reports every key of the row as changed, so a consumer that
  /// missed earlier updates still applies the current values.
  final Set<String> changedKeys;

  bool changed(String key) => changedKeys.contains(key);
}

/// Single owner of the realtime subscription to the signed-in user's own row
/// in `public.users`.
///
/// The theme, language, visibility and general-preferences notifiers all need
/// to know when *their* columns change on another device. Subscribing to the
/// same row from four different channels meant:
///
///   * four channels per client instead of one - the realtime connection and
///     the server-side replication slots are the scarce resource,
///   * four independent places where the subscription could silently die,
///     each with its own re-subscribe logic,
///   * every write to `users` - including unrelated profile edits, location
///     updates and verification changes - fanning out to all four.
///
/// One channel, one owner, one place to fix.
class MyUserRealtimeService {
  MyUserRealtimeService._() {
    _listenAuthState();
  }

  static final MyUserRealtimeService instance = MyUserRealtimeService._();

  final StreamController<MyUserUpdate> _updates =
      StreamController<MyUserUpdate>.broadcast();

  final StreamController<MyUserUpdate> _profileUpdates =
      StreamController<MyUserUpdate>.broadcast();

  final StreamController<void> _resyncRequests =
      StreamController<void>.broadcast();

  StreamSubscription<AuthState>? _authSubscription;
  RealtimeChannel? _channel;
  String? _userId;

  /// Whether the app asked for the subscription to be live.
  ///
  /// The service does not open a channel on its own: the app owns the
  /// realtime lifecycle, and a provider that merely listens must not leave a
  /// half-open channel (and its join timeout) behind.
  bool _enabled = false;

  /// Subscribes to the auth state.
  ///
  /// The service can be constructed before Supabase is initialised (a
  /// bootstrap-time singleton), in which case the subscription fails and is
  /// retried when the app starts.
  void _listenAuthState() {
    if (_authSubscription != null) return;
    try {
      _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
        (event) {
          if (!_enabled) return;
          switch (event.event) {
            case AuthChangeEvent.signedOut:
              _stop();
              return;
            case AuthChangeEvent.initialSession:
            case AuthChangeEvent.signedIn:
            case AuthChangeEvent.userUpdated:
              _ensureChannel();
              return;
            default:
              return;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[MY-USER-REALTIME] Auth stream error: $error');
        },
      );
    } catch (_) {
      // Supabase is not initialised yet. [start] retries.
    }
  }

  /// The last row the service has seen, used to compute [MyUserUpdate.changedKeys].
  ///
  /// Keyed by table: the account settings live on `public.users`, the match
  /// preferences on `public.user_profiles`.
  final Map<String, Map<String, dynamic>> _previousRows = {};

  /// Whether the channel has been subscribed at least once. Used to tell a
  /// first subscribe (nothing was missed) from a re-subscribe (events may
  /// have been missed).
  bool _everSubscribed = false;

  /// Changes to the signed-in user's own `users` row.
  Stream<MyUserUpdate> get updates => _updates.stream;

  /// Changes to the signed-in user's own `user_profiles` row.
  ///
  /// The match preferences (preferred gender, age range, and the lifestyle,
  /// family, religion and height filters) live in
  /// `user_profiles.intent_preferences` rather than on the `users` row.
  Stream<MyUserUpdate> get profileUpdates => _profileUpdates.stream;

  /// Emitted when the subscription was lost or re-established. Consumers
  /// should re-pull the authoritative values, because the events that were
  /// missed while the channel was down are not replayed.
  Stream<void> get resyncRequests => _resyncRequests.stream;

  /// Enables the subscription and opens the channel for the signed-in user.
  ///
  /// Called by the app when it starts. Consumers only listen to [updates]
  /// and [resyncRequests]; they never open a channel themselves.
  void start() {
    _enabled = true;
    // The service may have been constructed before Supabase was ready.
    _listenAuthState();
    _ensureChannel();
  }

  /// Disables the subscription and closes the channel.
  void stop() {
    _enabled = false;
    _stop();
  }

  void _ensureChannel() {
    if (!_enabled) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _stop();
      return;
    }
    if (_channel != null && _userId == userId) return;
    _stop();
    _userId = userId;
    _previousRows.clear();

    final channelName = 'me_$userId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      _channel = Supabase.instance.client
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'users',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: userId,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              if (newRecord.isEmpty) return;
              _emit('users', _updates, newRecord);
            },
          )
          // The match preferences live on `user_profiles`, not on `users`.
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'user_profiles',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              if (newRecord.isEmpty) return;
              _emit('user_profiles', _profileUpdates, newRecord);
            },
          )
          .subscribe((status, err) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              // The events that were missed while the channel was down are
              // not replayed, so ask the consumers to re-pull. The very first
              // subscribe is skipped: every consumer already pulls the
              // authoritative values when it starts.
              if (_everSubscribed) {
                _requestResync();
              }
              _everSubscribed = true;
              return;
            }
            if (status != RealtimeSubscribeStatus.channelError &&
                status != RealtimeSubscribeStatus.timedOut &&
                status != RealtimeSubscribeStatus.closed) {
              return;
            }
            if (err != null && isExpectedOfflineFailure(err)) {
              // Proactively pause to suppress errors from the other channels
              // and to avoid racing the connectivity provider's own
              // pauseAll() call.
              SupabaseRealtimeManager.instance.pauseAll();
              return;
            }
            if (SupabaseRealtimeManager.instance.isPaused) return;
            _requestResync();
          });
      return _channel!;
    });
  }

  /// Drops the subscription. The service keeps its auth listener, so a later
  /// sign-in re-creates it.
  void _stop() {
    final userId = _userId;
    _channel = null;
    _userId = null;
    _previousRows.clear();
    if (userId != null) {
      SupabaseRealtimeManager.instance.unregister('me_$userId');
    }
  }

  /// Releases every resource. The service is a singleton and normally lives
  /// for the whole process; this exists for tests and for a hard shutdown.
  void dispose() {
    _stop();
    _authSubscription?.cancel();
    _authSubscription = null;
    _updates.close();
    _profileUpdates.close();
    _resyncRequests.close();
  }

  void _emit(
    String table,
    StreamController<MyUserUpdate> sink,
    Map<String, dynamic> newRecord,
  ) {
    final previous = _previousRows[table];
    final merged = <String, dynamic>{...?previous, ...newRecord};
    final changedKeys = computeChangedKeys(previous, merged);
    _previousRows[table] = merged;
    if (changedKeys.isEmpty) return;
    if (sink.isClosed) return;
    sink.add(MyUserUpdate(row: merged, changedKeys: changedKeys));
  }

  void _requestResync() {
    if (_resyncRequests.isClosed) return;
    _resyncRequests.add(null);
  }

  /// The keys of [next] whose value differs from [previous].
  ///
  /// [previous] is null for the first event, in which case every key counts
  /// as changed - a consumer that missed earlier updates still applies the
  /// current values.
  static Set<String> computeChangedKeys(
    Map<String, dynamic>? previous,
    Map<String, dynamic> next,
  ) {
    if (previous == null) return next.keys.toSet();
    final changed = <String>{};
    for (final entry in next.entries) {
      if (!_deepEquals(previous[entry.key], entry.value)) {
        changed.add(entry.key);
      }
    }
    return changed;
  }

  static bool _deepEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (!b.containsKey(entry.key)) return false;
        if (!_deepEquals(entry.value, b[entry.key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
