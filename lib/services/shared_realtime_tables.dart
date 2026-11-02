import 'package:flutter/foundation.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tables that more than one provider watches over Realtime.
///
/// Every local `postgres_changes` binding counts as realtime work on the
/// server, so duplicate channels for the same table (Home + nearby map + the
/// online map each bound `presence_tick`, for example) were pure overhead.
/// The hub owns one channel per table per signed-in user and fans each event
/// out to the local listeners.
enum SharedRealtimeTable {
  /// Home counts and the nearby-map cells refresh on other users' activity.
  userActivity('user_activity', excludeSelf: true),

  /// Nearby counts and map cells refresh on other users' location updates.
  userLocations('user_locations', excludeSelf: true),

  /// Readable-by-all tick touched whenever any user's presence flips.
  presenceTick('presence_tick'),

  /// Other users' profile edits: visibility, pinned flag, photos.
  users('users');

  const SharedRealtimeTable(this.table, {this.excludeSelf = false});

  final String table;

  /// Apply a server-side `user_id != auth.uid()` filter. Every listener for
  /// these tables already drops its own rows locally, so filtering once on
  /// the channel avoids delivering them at all.
  final bool excludeSelf;
}

/// One shared Realtime channel per table, with local fan-out.
class SharedRealtimeTables {
  SharedRealtimeTables._();

  static final SharedRealtimeTables instance = SharedRealtimeTables._();

  final Map<String, _SharedTableChannel> _channels = {};

  /// Subscribes [onPayload] to [table]'s change stream.
  ///
  /// The first listener for a table creates the channel; the last one to
  /// cancel tears it down. Listeners are isolated: a throwing callback does
  /// not stop delivery to the others.
  SharedTableSubscription subscribe({
    required SharedRealtimeTable table,
    required String userId,
    required void Function(PostgresChangePayload payload) onPayload,
    Set<PostgresChangeEvent> events = const {
      PostgresChangeEvent.insert,
      PostgresChangeEvent.update,
      PostgresChangeEvent.delete,
    },
  }) {
    final name = 'shared_${table.table}_$userId';
    final listener = _SharedTableListener(events, onPayload);
    final entry = _channels[name];
    if (entry == null) {
      final created = _SharedTableChannel(name, table, userId);
      created.listeners.add(listener);
      _channels[name] = created;
      SupabaseRealtimeManager.instance.register(
        name,
        () => _createChannel(created),
      );
      return SharedTableSubscription._(created, listener);
    }
    entry.listeners.add(listener);
    return SharedTableSubscription._(entry, listener);
  }

  RealtimeChannel _createChannel(_SharedTableChannel entry) {
    final table = entry.table;
    return Supabase.instance.client
        .channel(entry.name)
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table.table,
          filter: table.excludeSelf
              ? PostgresChangeFilter(
                  type: PostgresChangeFilterType.neq,
                  column: 'user_id',
                  value: entry.userId,
                )
              : null,
          callback: (payload) {
            for (final listener in entry.listeners.toList(growable: false)) {
              if (!listener.events.contains(payload.eventType)) continue;
              try {
                listener.onPayload(payload);
              } catch (error, stack) {
                debugPrint(
                  '[SHARED-RT] ${entry.name} listener failed: $error\n$stack',
                );
              }
            }
          },
        )
        .subscribe((status, err) {
          if (err != null && !SupabaseRealtimeManager.instance.isPaused) {
            debugPrint('[SHARED-RT] ${entry.name} status: $status, $err');
          }
        });
  }

  void _release(_SharedTableChannel entry, _SharedTableListener listener) {
    if (!entry.listeners.remove(listener)) return;
    if (entry.listeners.isNotEmpty) return;
    if (!identical(_channels[entry.name], entry)) return;
    _channels.remove(entry.name);
    SupabaseRealtimeManager.instance.unregister(entry.name);
  }
}

class SharedTableSubscription {
  SharedTableSubscription._(this._channel, this._listener);

  final _SharedTableChannel _channel;
  final _SharedTableListener _listener;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    SharedRealtimeTables.instance._release(_channel, _listener);
  }
}

class _SharedTableChannel {
  _SharedTableChannel(this.name, this.table, this.userId);

  final String name;
  final SharedRealtimeTable table;
  final String userId;
  final List<_SharedTableListener> listeners = <_SharedTableListener>[];
}

class _SharedTableListener {
  const _SharedTableListener(this.events, this.onPayload);

  final Set<PostgresChangeEvent> events;
  final void Function(PostgresChangePayload payload) onPayload;
}
