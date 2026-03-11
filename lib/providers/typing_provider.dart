// lib/providers/typing_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

/// Parameters to scope typing channel per conversation
class TypingParams {
  final String matchId;
  final String selfUserId;
  final String otherUserId;
  const TypingParams({
    required this.matchId,
    required this.selfUserId,
    required this.otherUserId,
  });

  @override
  String toString() =>
      'TypingParams(matchId: $matchId, self: $selfUserId, other: $otherUserId)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TypingParams &&
        other.matchId == matchId &&
        other.selfUserId == selfUserId &&
        other.otherUserId == otherUserId;
  }

  @override
  int get hashCode => Object.hash(matchId, selfUserId, otherUserId);
}

/// Provider to get a scoped TypingService instance
/// NOTE: not autoDispose so the service remains alive while the chat is open.
/// UI consumers can still use autoDispose StreamProviders to observe the stream.
final typingServiceProvider = Provider.family<TypingService, TypingParams>((
  ref,
  params,
) {
  final svc = TypingService(params);
  ref.onDispose(() {
    svc.dispose();
  });
  return svc;
});

/// Provider to subscribe to the "other user is typing" stream as Riverpod state
final isOtherTypingProvider = StreamProvider.autoDispose
    .family<bool, TypingParams>((ref, params) {
      final svc = ref.read(typingServiceProvider(params));
      return svc.isOtherTyping$;
    });

/// Service encapsulating presence for typing
class TypingService {
  final TypingParams _p;
  late final RealtimeChannel _ch;
  final _ctrl = StreamController<bool>.broadcast();
  bool _last = false;
  Timer? _pollTimer;

  TypingService(this._p) {
    // Use a dedicated channel name for typing presence per match
    _ch = supabase.channel('typing:${_p.matchId}');

    // Try to hook presence sync if available; if not, fall back to polling presenceState
    try {
      _ch.onPresenceSync((_) {
        _recompute();
      });
    } catch (e) {
      // Some versions may not expose onPresenceSync - just continue
    }

    // Subscribe and ensure we set an initial not-typing presence
    _ch.subscribe((status, [err]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        // set initial tracked meta as not typing for this user
        _track(typing: false);
      }
      return;
    });

    // Start a short poll that calls _recompute so presence changes are observed
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      try {
        _recompute();
      } catch (_) {
        // swallow errors silently to avoid noisy logs
      }
    });

    // Emit initial false so Stream consumers get an immediate value
    _emit(false);
  }

  /// Public stream of whether the other user is actively typing
  Stream<bool> get isOtherTyping$ => _ctrl.stream;

  /// Should be called on every local text change
  void startTyping() {
    _track(typing: true);
  }

  /// Should be called after inactivity / on send / on dispose
  void stopTyping() {
    _track(typing: false);
  }

  void _track({required bool typing}) {
    try {
      final meta = {
        'typing': typing,
        'ts': DateTime.now().toUtc().toIso8601String(),
        'user_id': _p.selfUserId,
      };
      _ch.track(meta);
    } catch (_) {
      // track may fail if channel not yet joined; ignore silently
    }
  }

  /// Robust presence-state parsing:
  /// Supabase realtime_client / JS runtimes may return presenceState in different shapes:
  ///  - Map&lt;String, dynamic&gt; where keys are userIds and values are { metas: [...] } or { presences: [...] }
  ///  - List of SinglePresenceState-like objects (JSArray) where each entry has `key` and `presences` (or `metas`)
  /// This function handles these shapes and extracts the latest meta for _p.otherUserId.
  void _recompute() {
    try {
      final dynamic raw = _ch.presenceState();

      // Helper to coerce a "presences/metas" container into a List<Map<String, dynamic>> of payloads
      List<Map<String, dynamic>> metasFromContainer(dynamic container) {
        final List<Map<String, dynamic>> out = [];
        if (container == null) return out;

        // If container itself is a List of payload-like maps
        if (container is List) {
          for (final item in container) {
            try {
              if (item is Map) {
                // item may already be the payload
                if (item.containsKey('ts') && item.containsKey('user_id')) {
                  out.add(Map<String, dynamic>.from(item));
                  continue;
                }
                // item may be Presence object with 'payload'
                if (item.containsKey('payload')) {
                  final payload = item['payload'];
                  if (payload is Map) {
                    out.add(Map<String, dynamic>.from(payload));
                  }
                  continue;
                }
              } else {
                // item may be JS interop Presence object with .payload
                try {
                  final dynamic payload = (item as dynamic).payload;
                  if (payload != null) {
                    out.add(Map<String, dynamic>.from(payload as Map));
                    continue;
                  }
                } catch (_) {}
              }
            } catch (_) {}
          }
          return out;
        }

        // If container is a Map that contains 'metas' or 'presences'
        if (container is Map) {
          if (container['metas'] is List) {
            return metasFromContainer(container['metas']);
          }
          if (container['presences'] is List) {
            return metasFromContainer(container['presences']);
          }
          // Maybe the map is directly a payload
          if (container.containsKey('ts') && container.containsKey('user_id')) {
            out.add(Map<String, dynamic>.from(container));
            return out;
          }
        }

        // Try dynamic access (JS objects)
        try {
          final dynamic metasDyn =
              (container as dynamic).metas ?? (container as dynamic).presences;
          return metasFromContainer(metasDyn);
        } catch (_) {}

        return out;
      }

      // If raw is a Map keyed by some id
      if (raw is Map) {
        // Try direct key lookup first
        final dynamic direct = raw[_p.otherUserId];
        if (direct != null) {
          final metas = metasFromContainer(direct);
          _processMetasAndEmit(metas);
          return;
        }

        // Not found directly — iterate all entries; check payloads for matching user_id
        for (final entryKey in raw.keys) {
          final dynamic entryVal = raw[entryKey];
          final metas = metasFromContainer(entryVal);
          // if any payload in metas has matching user_id, use them
          final filtered = metas
              .where((m) => m['user_id']?.toString() == _p.otherUserId)
              .toList();
          if (filtered.isNotEmpty) {
            _processMetasAndEmit(filtered);
            return;
          }
        }

        _emit(false);
        return;
      }

      // If raw is a List (e.g., JSArray<SinglePresenceState>)
      if (raw is List) {
        // Each entry might be a PresenceState-like object with key / presences properties
        for (final entry in raw) {
          String? key;
          dynamic presContainer;
          try {
            if (entry is Map) {
              key = entry['key']?.toString();
              presContainer =
                  entry['presences'] ??
                  entry['metas'] ??
                  entry['presence'] ??
                  entry['presences'];
            } else {
              // dynamic JS interop object: try .key and .presences
              try {
                key = (entry as dynamic).key?.toString();
              } catch (_) {
                try {
                  key = (entry as dynamic)['key']?.toString();
                } catch (_) {
                  key = null;
                }
              }
              try {
                presContainer =
                    (entry as dynamic).presences ?? (entry as dynamic).metas;
              } catch (_) {
                try {
                  presContainer =
                      (entry as dynamic)['presences'] ??
                      (entry as dynamic)['metas'];
                } catch (_) {
                  presContainer = null;
                }
              }
            }

            // Extract payload-based metas from presContainer
            final metas = metasFromContainer(presContainer);

            // If the entry's key equals otherUserId => accept metas
            if (key == _p.otherUserId) {
              _processMetasAndEmit(metas);
              return;
            }

            // Otherwise, check payload.user_id inside metas (some runtimes use different key)
            final filtered = metas
                .where((m) => m['user_id']?.toString() == _p.otherUserId)
                .toList();
            if (filtered.isNotEmpty) {
              _processMetasAndEmit(filtered);
              return;
            }
          } catch (_) {
            // ignore malformed entry and continue
            continue;
          }
        }

        // No entry matched for other user
        _emit(false);
        return;
      }

      // Unknown raw type - try some best-effort access patterns
      try {
        final dynamic dyn = raw;
        final dynamic maybe = dyn[_p.otherUserId];
        if (maybe != null) {
          final metas = metasFromContainer(maybe);
          _processMetasAndEmit(metas);
          return;
        }
      } catch (_) {}

      _emit(false);
    } catch (_) {
      _emit(false);
    }
  }

  void _processMetasAndEmit(List<Map<String, dynamic>> metas) {
    if (metas.isEmpty) {
      _emit(false);
      return;
    }

    metas.sort((a, b) {
      final at =
          DateTime.tryParse((a['ts'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bt =
          DateTime.tryParse((b['ts'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });

    final latest = metas.first;
    final typing = (latest['typing'] == true);
    final ts = DateTime.tryParse((latest['ts'] as String?) ?? '');
    final fresh =
        ts != null && DateTime.now().toUtc().difference(ts).inSeconds <= 5;

    _emit(typing && fresh);
  }

  void _emit(bool v) {
    if (v == _last) return;
    _last = v;
    if (!_ctrl.isClosed) {
      _ctrl.add(v);
    }
  }

  Future<void> dispose() async {
    _track(typing: false);
    _pollTimer?.cancel();
    try {
      await _ch.unsubscribe();
      supabase.removeChannel(_ch);
    } catch (_) {}
    await _ctrl.close();
  }
}
