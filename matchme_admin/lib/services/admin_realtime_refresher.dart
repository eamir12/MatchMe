// matchme_admin/lib/services/admin_realtime_refresher.dart
//
// Realtime + poll fallback for admin list screens: subscribes a Postgres
// change channel on [table] and invokes [onChange] on any event, with a
// periodic fallback poll for when realtime delivery is unavailable
// (publication membership off, RLS change, or a silently dead socket).
// Screens call [onChange] themselves — typically a mounted/_isLoading-guarded
// force reload — so the screen stays current without a refresh button.
// [onChange] must be safe to call after dispose; the helper never fires it
// once [dispose] has run.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminRealtimeRefresher {
  AdminRealtimeRefresher({
    required this.channelName,
    required this.table,
    required this.onChange,
    this.pollInterval = const Duration(seconds: 60),
  });

  final String channelName;
  final String table;
  final VoidCallback onChange;
  final Duration pollInterval;

  RealtimeChannel? _channel;
  Timer? _pollTimer;
  int _retries = 0;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _ensureChannel();
    _pollTimer = Timer.periodic(pollInterval, (_) => onChange());
  }

  void _ensureChannel() {
    if (_disposed) return;
    try {
      _channel = Supabase.instance.client
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) {
              if (_disposed) return;
              onChange();
            },
          )
          .subscribe((status, error) {
            debugPrint('[$channelName] subscribe status=$status error=$error');
            // Bounded re-subscribe when the channel dies without a clean
            // close; the poll covers us in the meantime and afterwards.
            if (!_disposed &&
                _retries < 3 &&
                (status == RealtimeSubscribeStatus.channelError ||
                    status == RealtimeSubscribeStatus.timedOut)) {
              _retries++;
              Future.delayed(const Duration(seconds: 2), () {
                if (_disposed) return;
                final channel = _channel;
                _channel = null;
                if (channel != null) {
                  try {
                    Supabase.instance.client.removeChannel(channel);
                  } catch (_) {}
                }
                _ensureChannel();
              });
            }
          });
    } catch (_) {
      // Realtime is an enhancement; the poll keeps the screen current.
      _channel = null;
    }
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
  }
}
