import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/services/windows_location_channel.dart';
import 'package:matchme/utils/location_deduplicator.dart';
import 'package:matchme/utils/location_share_countdown.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/sensitive_session_store.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../web_imports.dart' as html;

class LocationShareNotifier extends Notifier<LocationShareSession?> {
  final ChatKeyService _chatKeyService = ChatKeyService.instance;
  final CryptoService _crypto = CryptoService.instance;

  RealtimeChannel? _channel;
  RealtimeChannel? _signalChannel;
  bool _signalChannelSubscribed = false;
  String? _signalChannelUserId;
  bool _signalSubscribeInFlight = false;
  DateTime? _lastSignalSubscribeAt;
  int _signalTimeoutStreak = 0;
  RealtimeChannel? _positionChannel;
  Future<RealtimeChannel?>? _positionChannelFuture;
  bool _positionChannelSubscribed = false;
  StreamSubscription<Position>? _gpsSubscription;
  Timer? _gpsTimer;
  Timer? _staleTimer;
  Timer? _expirationTimer;
  Uint8List? _sessionKey;
  bool _disposed = false;
  // Own-signal deletes caused by us (stop or stale-row refresh) rather than
  // by pg_cron expiry must not surface as "the peer stopped sharing".
  int _ownSignalDeleteSuppressions = 0;
  bool get _suppressOwnSignalDelete => _ownSignalDeleteSuppressions > 0;
  final Map<String, String> _lastNotifiedExpiresAt = {};
  // Live per-second countdown ticker for incoming-share notifications
  Timer? _notifCountdownTimer;
  String? _notifCountdownMatchId;
  DateTime? _notifCountdownExpiresAt;
  String _notifCountdownName = '';
  ProviderSubscription<AsyncValue<ConnectivityHealth>>?
  _connectivitySubscription;
  bool _wasOnlineBeforeDisconnect = true;
  dynamic _webHideListener;

  @override
  LocationShareSession? build() {
    ref.onDispose(() {
      _disposed = true;
      _cleanup();
      _signalChannel?.unsubscribe();
      _signalChannel = null;
      _signalChannelSubscribed = false;
      _signalChannelUserId = null;
      _signalSubscribeInFlight = false;
      _connectivitySubscription?.close();
      _connectivitySubscription = null;
      _detachWebHideListener();
    });
    // Restore session if we have an active signal in the DB — skip when offline
    debugPrint(
      '⏱️ [BOOTSTRAP] location_share build shouldSkip=${shouldSkipSupabaseCalls()} isSupabaseAvailable=${offlineCacheManager.isSupabaseAvailable}',
    );
    if (!shouldSkipSupabaseCalls()) {
      _restoreSessionFromSignal();
      // Check for active signals from other users that we may have missed
      // (Postgres Changes INSERT events are not replayed on reconnect).
      _recoverMissedSignals();
    } else {
      debugPrint('⏱️ [BOOTSTRAP] Skipping location_share restore (offline)');
    }

    // Listen for auth state changes so the signal channel is cleaned up
    // when the user signs out, preventing stale subscriptions from
    // persisting across sessions.
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      final authState = next.asData?.value;
      if (authState != null && authState.event == AuthChangeEvent.signedOut) {
        _signalChannel?.unsubscribe();
        _signalChannel = null;
        _signalChannelSubscribed = false;
        _signalChannelUserId = null;
        _signalSubscribeInFlight = false;
      }
    });

    // Listen for connectivity changes to pause/resume location sharing when
    // the device goes offline/online. This ensures the sender stops wasting
    // GPS resources when there's no network, and resumes immediately when
    // connectivity is restored.
    _connectivitySubscription?.close();
    _connectivitySubscription = ref.listen<AsyncValue<ConnectivityHealth>>(
      connectivityHealthProvider,
      _onConnectivityChanged,
    );

    // On web, fire a best-effort final position broadcast when the tab is
    // hidden, since the browser suspends timers and WebSockets for hidden
    // tabs until the next visibility change.
    _attachWebHideListener();

    return null;
  }

  void _attachWebHideListener() {
    if (!kIsWeb) return;
    if (_webHideListener != null) return;
    try {
      _webHideListener = (_) {
        try {
          if (html.document.hidden == true) {
            // Best-effort final broadcast before the browser throttles the
            // hidden tab. Sharing resumes on the next visibility change via
            // onAppResumed / visibilityProvider.
            _sendLocationUpdate();
          }
        } catch (_) {}
      };
      html.document.addEventListener('visibilitychange', _webHideListener);
    } catch (_) {}
  }

  void _detachWebHideListener() {
    if (!kIsWeb || _webHideListener == null) return;
    try {
      html.document.removeEventListener('visibilitychange', _webHideListener);
      _webHideListener = null;
    } catch (_) {}
  }

  Future<void> _restoreSessionFromSignal() async {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) return;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final now = DateTime.now().toUtc().toIso8601String();
      final signals = await _supabase
          .from('location_share_signals')
          .select('match_id, expires_at')
          .eq('sharer_id', user.id)
          .or('expires_at.gt.$now,expires_at.is.null')
          .limit(1);

      if (signals.isEmpty || _disposed) return;

      final signal = signals.first;
      final matchId = signal['match_id'] as String;
      final expiresAtStr = signal['expires_at'] as String?;

      if (matchId.isEmpty) return;

      // Look up the other user's info from the match
      final matchData = await _supabase
          .from('matches')
          .select('user1_id, user2_id')
          .eq('id', matchId)
          .maybeSingle();

      if (matchData == null || _disposed) return;

      final otherUserId = (matchData['user1_id'] as String) == user.id
          ? matchData['user2_id'] as String
          : matchData['user1_id'] as String;

      // Get the other user's display name from users table
      final profile = await _supabase
          .from('users')
          .select('name')
          .eq('id', otherUserId)
          .maybeSingle();

      if (_disposed) return;

      final updateInterval = await appConfigService.getInt(
        'location_sharing.update_interval_seconds',
        defaultValue: 5,
      );

      final otherUserName = _formatUserName(profile?['name'] as String?);
      String? otherUserPhoto;
      try {
        final photoProfile = await _supabase
            .from('user_profiles')
            .select('photos')
            .eq('user_id', otherUserId)
            .maybeSingle();
        otherUserPhoto = _extractFirstPhoto(photoProfile?['photos']);
      } catch (_) {}
      final myUserPhoto = await _getCurrentUserPhoto();

      final expiresAt = expiresAtStr != null
          ? DateTime.parse(expiresAtStr).toLocal()
          : null;

      state = LocationShareSession(
        matchId: matchId,
        myUserId: user.id,
        otherUserId: otherUserId,
        otherUserName: otherUserName,
        otherUserPhoto: otherUserPhoto,
        myUserPhoto: myUserPhoto,
        myStatus: ShareStatus.sharing,
        otherStatus: ShareStatus.unknown,
        updateInterval: Duration(seconds: updateInterval),
        expiresAt: expiresAt,
        broadcastMode: BroadcastMode.flutter,
      );

      await _deriveSessionKey(otherUserId);
      await _subscribeToBroadcastChannel();
      _startGpsStreaming(state!.updateInterval);
      _startStaleTimer();

      // Re-arm the native background service and expiration timer so
      // sharing continues even after an app restart.
      await _persistSessionState(expiresAt);
      await BackgroundService.startLocationShare(
        matchId: matchId,
        otherUserId: otherUserId,
        sessionKeyBase64: base64Encode(_sessionKey!),
        updateIntervalSeconds: updateInterval,
        expiresAtIso: expiresAt?.toUtc().toIso8601String(),
      );
      _startExpirationTimer(expiresAt);
    } catch (e) {
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        print('LocationShare: Failed to restore session: $e');
      }
    }
  }

  Future<String?> _getCurrentUserPhoto() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return null;
      final profile = await ref.read(userProfileProvider(userId).future);
      if (profile != null && profile.photos.isNotEmpty) {
        return profile.photos.first;
      }
    } catch (_) {}
    return null;
  }

  bool _photoRefreshInFlight = false;

  /// Fetch the other user's first profile photo from the DB. Used when the
  /// caller passes no photo (profile still loading) so the map marker does
  /// not stay a generic placeholder forever — [copyWith] previously had no
  /// way to set the photo after session creation.
  Future<String?> _fetchOtherUserPhoto(String otherUserId) async {
    if (shouldSkipSupabaseCalls()) return null;
    try {
      final photoProfile = await _supabase
          .from('user_profiles')
          .select('photos')
          .eq('user_id', otherUserId)
          .maybeSingle();
      return _extractFirstPhoto(photoProfile?['photos']);
    } catch (_) {
      return null;
    }
  }

  /// Refresh the peer photo on the active session when missing. Safe to call
  /// from hot paths (broadcast callbacks); concurrent calls are collapsed.
  Future<void> ensureOtherUserPhoto() async {
    final current = state;
    if (_disposed ||
        current == null ||
        _photoRefreshInFlight ||
        (current.otherUserPhoto?.isNotEmpty == true)) {
      return;
    }
    _photoRefreshInFlight = true;
    try {
      final photo = await _fetchOtherUserPhoto(current.otherUserId);
      if (photo != null && photo.isNotEmpty && !_disposed && state != null) {
        state = state!.copyWith(otherUserPhoto: photo);
      }
    } finally {
      _photoRefreshInFlight = false;
    }
  }

  /// Extract the first photo URL from the `photos` column, which may be
  /// stored as a JSON array string or a Dart List depending on the driver.
  String? _extractFirstPhoto(dynamic photos) {
    if (photos == null) return null;
    try {
      if (photos is List && photos.isNotEmpty) {
        return photos.first as String;
      }
      if (photos is String && photos.isNotEmpty) {
        // Could be a JSON-encoded array like '["url"]' or a plain URL
        final decoded = jsonDecode(photos);
        if (decoded is List && decoded.isNotEmpty) {
          return decoded.first as String;
        }
        return photos;
      }
    } catch (_) {}
    return null;
  }

  /// "John S." — the app's only display-name format. A single-word name has
  /// no valid form, so it shows the neutral 'Someone' placeholder instead of
  /// the bare first name.
  String _formatUserName(String? name) =>
      (name ?? '').formatAsFirstNameLastInitial(fallback: 'Someone');

  SupabaseClient get _supabase => Supabase.instance.client;

  /// Best-effort request for background ("Always") location permission so
  /// sharing keeps broadcasting when the UI is minimized/closed.
  /// Foreground sharing still works without it, but the receiver will see
  /// "Stale" as soon as the sender backgrounds the app. Missing permission
  /// is recorded for PermissionCoordinator to surface on next resume.
  /// Returns true when background permission is granted.
  Future<bool> ensureBackgroundLocationPermission() async {
    if (kIsWeb) return true;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }
    try {
      final current = await WindowsLocationChannel.checkPermission();
      if (current == LocationPermission.always) return true;
      if (current == LocationPermission.deniedForever) {
        await BackgroundService.setNativePermissionIssueCode('location_always');
        return false;
      }
      // permission_handler maps "Allow all the time" to locationAlways.
      // On Android 11+ this may open Settings; on iOS it upgrades WhenInUse.
      final status = await perm.Permission.locationAlways.request();
      if (status.isGranted) return true;
      final rechecked = await WindowsLocationChannel.checkPermission();
      if (rechecked == LocationPermission.always) return true;
      await BackgroundService.setNativePermissionIssueCode('location_always');
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _warnBackgroundPermissionIfMissing() async {
    try {
      final ok = await ensureBackgroundLocationPermission();
      if (!ok && !_disposed) {
        try {
          final l10n = ref.read(localizationProvider);
          _showInAppNotification(
            l10n.getString('locationPermissionDenied'),
            'location_sharing',
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Start sharing location (initiator flow)
  Future<void> startSharing({
    required String matchId,
    required String otherUserId,
    required String otherUserName,
    String? otherUserPhoto,
    Duration? duration,
  }) async {
    print(
      'LocationShare: startSharing called match=$matchId other=$otherUserId',
    );
    if (_disposed) {
      print('LocationShare: startSharing aborted - disposed');
      return;
    }

    final user = _supabase.auth.currentUser;
    if (user == null) {
      print('LocationShare: startSharing aborted - no user');
      return;
    }

    final updateIntervalSeconds = await appConfigService.getInt(
      'location_sharing.update_interval_seconds',
      defaultValue: 5,
    );
    final updateInterval = Duration(seconds: updateIntervalSeconds);
    print('LocationShare: updateInterval=${updateIntervalSeconds}s');

    DateTime? expiresAt;
    if (duration != null) {
      expiresAt = DateTime.now().add(duration);
    }

    // Resolve the peer photo even when the caller had none (profile still
    // loading) — otherwise the map marker stays a generic placeholder.
    // Kicked off before the awaits below so both photo fetches run in parallel.
    final Future<String?> otherPhotoFuture = otherUserPhoto != null
        ? Future<String?>.value(otherUserPhoto)
        : _fetchOtherUserPhoto(otherUserId);
    final myUserPhoto = await _getCurrentUserPhoto();
    final resolvedOtherPhoto = await otherPhotoFuture;

    // Prompt for background ("Always") permission while the UI is still in
    // the foreground. Foreground sharing works regardless; without it the
    // receiver sees "Stale" once the sender backgrounds the app.
    unawaited(_warnBackgroundPermissionIfMissing());

    state = LocationShareSession(
      matchId: matchId,
      myUserId: user.id,
      otherUserId: otherUserId,
      otherUserName: otherUserName,
      otherUserPhoto: resolvedOtherPhoto,
      myUserPhoto: myUserPhoto,
      expiresAt: expiresAt,
      updateInterval: updateInterval,
      broadcastMode: BroadcastMode.flutter,
    );
    print('LocationShare: session created, deriving key...');

    await _deriveSessionKey(otherUserId);
    print('LocationShare: key derived, subscribing broadcast...');
    await _subscribeToBroadcastChannel();
    print('LocationShare: broadcast subscribed, sending session start...');
    await _sendSessionStart();
    print('LocationShare: session start sent, starting GPS...');
    _startGpsStreaming(updateInterval);
    _startStaleTimer();

    print('LocationShare: inserting signal...');
    await _insertSignal(matchId, expiresAt);

    // Persist session state so the native background service can continue
    // broadcasting encrypted location updates when the app is backgrounded.
    await _persistSessionState(expiresAt);
    await BackgroundService.startLocationShare(
      matchId: matchId,
      otherUserId: otherUserId,
      sessionKeyBase64: base64Encode(_sessionKey!),
      updateIntervalSeconds: updateIntervalSeconds,
      expiresAtIso: expiresAt?.toUtc().toIso8601String(),
    );
    _startExpirationTimer(expiresAt);

    print('LocationShare: startSharing complete');
  }

  /// Join an existing share (receiver flow)
  Future<void> joinExistingShare({
    required String matchId,
    required String otherUserId,
    required String otherUserName,
    String? otherUserPhoto,
  }) async {
    if (_disposed) return;

    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final updateIntervalSeconds = await appConfigService.getInt(
      'location_sharing.update_interval_seconds',
      defaultValue: 5,
    );
    final updateInterval = Duration(seconds: updateIntervalSeconds);
    final myUserPhoto = await _getCurrentUserPhoto();

    // See startSharing: prompt for background permission while foregrounded.
    unawaited(_warnBackgroundPermissionIfMissing());

    state = LocationShareSession(
      matchId: matchId,
      myUserId: user.id,
      otherUserId: otherUserId,
      otherUserName: otherUserName,
      otherUserPhoto: otherUserPhoto,
      myUserPhoto: myUserPhoto,
      myStatus: ShareStatus.sharing,
      otherStatus: ShareStatus.sharing,
      updateInterval: updateInterval,
      broadcastMode: BroadcastMode.flutter,
    );

    await _deriveSessionKey(otherUserId);
    await _subscribeToBroadcastChannel();
    await _sendSessionStart();
    _startGpsStreaming(updateInterval);
    _startStaleTimer();
    unawaited(ensureOtherUserPhoto());

    // Persist and start native service for the joiner too
    await _persistSessionState(null);
    await BackgroundService.startLocationShare(
      matchId: matchId,
      otherUserId: otherUserId,
      sessionKeyBase64: base64Encode(_sessionKey!),
      updateIntervalSeconds: updateIntervalSeconds,
      expiresAtIso: null,
    );
  }

  /// View an existing share without broadcasting our own location (view-only receiver flow)
  Future<void> viewExistingShare({
    required String matchId,
    required String otherUserId,
    required String otherUserName,
    String? otherUserPhoto,
    DateTime? expiresAt,
  }) async {
    if (_disposed) return;

    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // If expiresAt was not provided by the caller, look it up from DB
    expiresAt ??= await _fetchSignalExpiresAt(matchId, otherUserId);

    final updateIntervalSeconds = await appConfigService.getInt(
      'location_sharing.update_interval_seconds',
      defaultValue: 5,
    );
    final updateInterval = Duration(seconds: updateIntervalSeconds);
    // Fetch both photos in parallel; the caller often passes no peer photo
    // because the profile is still loading.
    final Future<String?> otherPhotoFuture = otherUserPhoto != null
        ? Future<String?>.value(otherUserPhoto)
        : _fetchOtherUserPhoto(otherUserId);
    final myUserPhoto = await _getCurrentUserPhoto();
    final resolvedOtherPhoto = await otherPhotoFuture;

    state = LocationShareSession(
      matchId: matchId,
      myUserId: user.id,
      otherUserId: otherUserId,
      otherUserName: otherUserName,
      otherUserPhoto: resolvedOtherPhoto,
      myUserPhoto: myUserPhoto,
      myStatus: ShareStatus.stopped,
      otherStatus: ShareStatus.sharing,
      expiresAt: expiresAt,
      updateInterval: updateInterval,
      broadcastMode: BroadcastMode.none,
    );

    await _deriveSessionKey(otherUserId);
    await _subscribeToBroadcastChannel();
    // Join the position channel immediately (not only when the map opens) so
    // the first coordinates render as soon as the sender broadcasts them.
    await subscribeToLocationUpdates();
    // Do NOT send session start or start GPS streaming
    _startStaleTimer();
  }

  /// Start sharing our own location back to the peer in an active session
  Future<void> startSharingBack({Duration? duration}) async {
    final current = state;
    if (current == null || _disposed) return;

    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // See startSharing: prompt for background permission while foregrounded.
    unawaited(_warnBackgroundPermissionIfMissing());

    DateTime? expiresAt;
    if (duration != null) {
      expiresAt = DateTime.now().add(duration);
    }

    state = LocationShareSession(
      matchId: current.matchId,
      myUserId: current.myUserId,
      otherUserId: current.otherUserId,
      otherUserName: current.otherUserName,
      otherUserPhoto: current.otherUserPhoto,
      myUserPhoto: current.myUserPhoto,
      myStatus: ShareStatus.sharing,
      otherStatus: current.otherStatus,
      myPosition: current.myPosition,
      otherPosition: current.otherPosition,
      otherPositionTimestamp: current.otherPositionTimestamp,
      startedAt: current.startedAt,
      expiresAt: expiresAt,
      updateInterval: current.updateInterval,
      sessionKey: current.sessionKey,
      broadcastMode: BroadcastMode.flutter,
    );

    await _sendSessionStart();
    _startGpsStreaming(current.updateInterval);

    // Also insert the signal so peer knows we are sharing
    await _insertSignal(current.matchId, expiresAt);

    // Persist and start native service
    await _persistSessionState(expiresAt);
    await BackgroundService.startLocationShare(
      matchId: current.matchId,
      otherUserId: current.otherUserId,
      sessionKeyBase64: base64Encode(_sessionKey!),
      updateIntervalSeconds: current.updateInterval.inSeconds,
      expiresAtIso: expiresAt?.toUtc().toIso8601String(),
    );
    _startExpirationTimer(expiresAt);
  }

  /// Update the duration of an active share without tearing down the session.
  ///
  /// Unlike stopSharing+startSharing, this preserves the broadcast channel,
  /// GPS streaming, and session state, and broadcasts a [duration_updated]
  /// event so the peer's banner updates in real-time.
  Future<void> updateDuration(Duration? duration) async {
    final current = state;
    if (current == null || _disposed) return;

    DateTime? expiresAt;
    if (duration != null) {
      expiresAt = DateTime.now().add(duration);
    }

    // Update local session immediately
    if (!_disposed) {
      state = current.copyWith(expiresAt: expiresAt);
    }

    // Notify peer via broadcast channel
    await _sendDurationUpdated(expiresAt);

    // Persist in DB (update existing signal to avoid delete+insert flash)
    await _updateSignalExpiry(current.matchId, expiresAt);

    // Update persisted state and restart expiration timer
    await _persistSessionState(expiresAt);
    _startExpirationTimer(expiresAt);

    // Notify the native background service (Android/iOS) so the persistent
    // notification countdown and in-memory expiry timer reflect the new
    // duration. Without this, the native side keeps the old expiresAt
    // value, so the notification shows the wrong remaining time after the
    // user minimises the UI.
    if (current.myStatus == ShareStatus.sharing) {
      await BackgroundService.updateLocationShareDuration(expiresAt);
    }
  }

  /// Whether a signal channel object exists (regardless of its async
  /// subscribe ACK). Callers (e.g. recentChatsProvider rebuilds on app resume)
  /// should check this to avoid re-entering setup while healthy.
  bool get hasSignalChannel => _signalChannel != null;

  /// Listen for incoming share signals from other users.
  ///
  /// Stays subscribed across screen off/on: if a channel object already exists
  /// it is kept as-is so the pending/current subscription is not torn down
  /// and recreated on every resume. A new channel is only created when there
  /// is none, when the user changed, or after a real teardown (offline,
  /// sign-out, dispose) cleared [_signalChannel] to null.
  void startListeningForSignals() {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '⏱️ [BOOTSTRAP] Skipping startListeningForSignals (offline) shouldSkip=true',
      );
      return;
    }
    final user = _supabase.auth.currentUser;
    if (user == null) {
      debugPrint('LocationShare: startListeningForSignals - no current user');
      return;
    }

    // Stay subscribed: an existing channel (even one still awaiting its
    // subscribe ACK) is kept. Tearing it down here is what caused a fresh
    // "Signal channel subscribed" log on every screen off/on.
    if (_signalChannel != null) {
      // Same user: keep existing channel. Adopt subscribed state lazily via
      // the subscribe callback; do not recreate.
      if (_signalChannelUserId == user.id) return;
      // Different user (account switch without dispose): tear down stale one.
      try {
        _signalChannel!.unsubscribe();
      } catch (_) {}
      _signalChannel = null;
      _signalChannelSubscribed = false;
      _signalSubscribeInFlight = false;
    }

    // Coalesce rapid duplicate calls (provider rebuild + connectivity resume
    // + map screen resume firing together) that arrive after a real teardown
    // but before the new subscribe ACK flips [_signalChannelSubscribed].
    final now = DateTime.now();
    if (_signalSubscribeInFlight &&
        _lastSignalSubscribeAt != null &&
        now.difference(_lastSignalSubscribeAt!) < const Duration(seconds: 10)) {
      return;
    }
    _signalSubscribeInFlight = true;
    _lastSignalSubscribeAt = now;
    _signalChannelUserId = user.id;

    debugPrint(
      'LocationShare: startListeningForSignals - setting up for user ${user.id}',
    );

    _signalChannel = _supabase
        .channel('location_share_signals:${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'location_share_signals',
          callback: (payload) async {
            print('LocationShare: SIGNAL RECEIVED! payload=$payload');
            if (_disposed) return;
            final newRecord = payload.newRecord;
            final sharerId = newRecord['sharer_id'] as String?;
            final matchId = newRecord['match_id'] as String?;
            final expiresAtStr = newRecord['expires_at'] as String?;

            if (sharerId == null || matchId == null) return;
            if (sharerId == user.id) return; // Ignore own signals

            // Check if expired (compare in UTC to avoid timezone issues)
            if (expiresAtStr != null) {
              final expiresAt = DateTime.parse(expiresAtStr).toUtc();
              if (DateTime.now().toUtc().isAfter(expiresAt)) {
                print(
                  'LocationShare: Signal expired (expiresAt=$expiresAt, now=${DateTime.now().toUtc()})',
                );
                return;
              }
            }

            // Don't notify if we already showed a notification for this exact expiresAt
            final expiresKey = expiresAtStr ?? 'null';
            if (_lastNotifiedExpiresAt[matchId] == expiresKey) return;
            _lastNotifiedExpiresAt[matchId] = expiresKey;

            // Look up the sharer's name from Supabase (avoids stale container issues)
            String otherUserName = 'Someone';
            try {
              final profile = await _supabase
                  .from('users')
                  .select('name')
                  .eq('id', sharerId)
                  .maybeSingle();
              if (profile != null && profile['name'] != null) {
                otherUserName = _formatUserName(profile['name'] as String);
              }
            } catch (e) {
              if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
                print('LocationShare: Failed to fetch profile: $e');
              }
            }

            print('LocationShare: Showing notifications for $otherUserName');

            final DateTime? countdownExpiresAt = expiresAtStr != null
                ? DateTime.parse(expiresAtStr).toUtc()
                : null;

            // Get localized strings
            String inAppText;
            String notifTitle;
            String notifBody;
            try {
              final l10n = ref.read(localizationProvider);
              final base = l10n
                  .getString('locationShareReceiving')
                  .replaceAll('{name}', otherUserName);
              final durationStr = buildLocationShareCountdownSuffix(
                expiresAt: countdownExpiresAt,
                now: DateTime.now(),
                getString: l10n.getString,
              );
              final untilOffSuffix = durationStr.isEmpty && expiresAtStr == null
                  ? ' - ${l10n.getString('locationShareUntilOff')}'
                  : '';

              inAppText = '$base$durationStr$untilOffSuffix';
              notifTitle = '📍 $otherUserName';
              notifBody = inAppText;
            } catch (_) {
              // Fallback to English if localization not available
              // Build duration string
              String fallbackDuration;
              if (countdownExpiresAt != null) {
                final remaining = countdownExpiresAt.difference(
                  DateTime.now().toUtc(),
                );
                if (remaining.isNegative || remaining.inSeconds <= 0) {
                  fallbackDuration = '';
                } else if (remaining.inHours > 0) {
                  final hours = remaining.inHours;
                  final minutes = remaining.inMinutes % 60;
                  final seconds = remaining.inSeconds % 60;
                  fallbackDuration =
                      ' - for another ${_englishCountUnit(hours, 'hour')}, '
                      '${_englishCountUnit(minutes, 'minute')} and '
                      '${_englishCountUnit(seconds, 'second')}';
                } else {
                  final minutes = remaining.inMinutes;
                  final seconds = remaining.inSeconds % 60;
                  fallbackDuration =
                      ' - for another ${_englishCountUnit(minutes, 'minute')} '
                      'and ${_englishCountUnit(seconds, 'second')}';
                }
              } else {
                fallbackDuration = ' - until turned off';
              }
              inAppText =
                  '$otherUserName is sharing their live location with you$fallbackDuration';
              notifTitle = '📍 $otherUserName';
              notifBody =
                  'is sharing their live location with you$fallbackDuration';
            }

            // Show in-app notification (persistent until user acts).
            // When a fixed expiry is known, the overlay ticks the countdown
            // every second via [SystemNotification.countdownExpiresAt].
            _showInAppNotification(
              inAppText,
              'location_sharing',
              persistent: true,
              countdownExpiresAt: countdownExpiresAt,
            );

            // Show OS notification
            try {
              if (kIsWeb) {
                await WebNotificationService.showLocationShareNotification(
                  title: notifTitle,
                  body: notifBody,
                );
              } else if (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS) {
                await MobileLocalNotificationService.showLocationShareNotification(
                  notificationId: 'location_share_$matchId',
                  title: notifTitle,
                  body: notifBody,
                );
              }
            } catch (e) {
              print('LocationShare: Failed to show OS notification: $e');
            }

            // Note: the persistent inbox row for this alert is written by
            // the server (trigger on location_share_signals ->
            // user_notifications), which also covers killed-state recipients
            // via FCM. The client deliberately does not insert a row here —
            // that would duplicate the server's.

            // Keep the OS notification's duration text ticking every second.
            // The in-app banner is re-rendered by the overlay itself.
            if (countdownExpiresAt != null) {
              _startNotifCountdown(
                matchId: matchId,
                otherUserName: otherUserName,
                expiresAt: countdownExpiresAt,
              );
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'location_share_signals',
          callback: (payload) async {
            if (_disposed) return;

            final current = state;
            if (current == null) return;

            final updatedRecord = payload.newRecord;
            final sharerId = updatedRecord['sharer_id'] as String?;

            // Ignore own signals — we manage our own state directly.
            final user = _supabase.auth.currentUser;
            if (sharerId == null || sharerId == user?.id) return;

            // Only process updates for our active session's peer
            if (sharerId != current.otherUserId) return;

            // The only field that gets updated is expires_at (duration change).
            final newExpiresAtStr = updatedRecord['expires_at'] as String?;
            if (newExpiresAtStr != null && !_disposed) {
              final dbExpiresAt = DateTime.parse(newExpiresAtStr).toLocal();
              final ce = state?.expiresAt;
              final changed =
                  (ce == null) ||
                  (dbExpiresAt.difference(ce).abs().inSeconds > 1);
              if (changed) {
                updateOtherExpiresAt(dbExpiresAt);
              }
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'location_share_signals',
          callback: (payload) {
            if (_disposed) return;
            unawaited(
              handleSignalDeleted(
                deletedSharerId: payload.oldRecord['sharer_id'] as String?,
                deletedMatchId: payload.oldRecord['match_id'] as String?,
              ),
            );
          },
        )
        .subscribe((status, error) {
          if (handleExpectedSupabaseOfflineFailure(error)) {
            _signalChannelSubscribed = false;
            _signalSubscribeInFlight = false;
            return;
          }
          // Auth failures (dead refresh token) leave realtime unable to auth —
          // don't spam; REST fallback + resume callback will retry after refresh.
          if (error != null && isAuthRateLimitFailure(error)) {
            _signalChannelSubscribed = false;
            _signalSubscribeInFlight = false;
            return;
          }
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('LocationShare: Signal channel subscribed');
            _signalChannelSubscribed = true;
            _signalSubscribeInFlight = false;
            _signalTimeoutStreak = 0;
          } else if (status == RealtimeSubscribeStatus.timedOut) {
            // Back off noisy retries: only log first of a streak, retry is via
            // Supabase REST + onSupabaseResume, not a hot loop here.
            _signalTimeoutStreak += 1;
            if (_signalTimeoutStreak <= 1) {
              debugPrint(
                'LocationShare: Signal channel timed out (will retry via Supabase)',
              );
            }
            _signalChannelSubscribed = false;
            _signalSubscribeInFlight = false;
          } else if (status == RealtimeSubscribeStatus.channelError) {
            if (error == null ||
                (!isExpectedOfflineFailure(error) &&
                    !isAuthRateLimitFailure(error))) {
              debugPrint('LocationShare: Signal channel error: $error');
            }
            _signalChannelSubscribed = false;
            _signalSubscribeInFlight = false;
          } else if (status == RealtimeSubscribeStatus.closed) {
            _signalChannelSubscribed = false;
            _signalSubscribeInFlight = false;
          }
        });
  }

  /// Handles a DELETE on `location_share_signals`.
  ///
  /// [deletedSharerId] / [deletedMatchId] identify the removed row, read from
  /// the delete payload (the table has REPLICA IDENTITY FULL). Callers that
  /// cannot supply them fall back to attributing the delete by querying.
  ///
  /// A delete of our own row is never the peer stopping: it is our explicit
  /// stop or a stale row replaced by a new share. Only the peer's row ending
  /// while they were actually sharing may produce the "stopped" notice.
  Future<void> handleSignalDeleted({
    String? deletedSharerId,
    String? deletedMatchId,
  }) async {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) return;

    final current = state;
    if (current == null) return;
    if (deletedMatchId != null && deletedMatchId != current.matchId) return;

    final myId = _supabase.auth.currentUser?.id;

    if (deletedSharerId != null && myId != null) {
      if (deletedSharerId == myId) {
        if (_suppressOwnSignalDelete) return;
        await _handleOwnSignalGone(current);
        return;
      }
      // Delete in another match — nothing in this session changed.
      if (deletedSharerId != current.otherUserId) return;

      // Unknown/stopped peers were never seen sharing, and duplicate DELETE
      // events for the same row must not re-notify.
      if (current.otherStatus == ShareStatus.sharing ||
          current.otherStatus == ShareStatus.paused) {
        markOtherStopped();
      }
      return;
    }

    // Fallback: no sharer id in the payload — attribute via the DB.
    final now = DateTime.now().toUtc().toIso8601String();

    final peerSignal = await _supabase
        .from('location_share_signals')
        .select('id')
        .eq('match_id', current.matchId)
        .eq('sharer_id', current.otherUserId)
        .or('expires_at.gt.$now,expires_at.is.null')
        .maybeSingle();

    if (_disposed) return;

    final peerWasSharing =
        current.otherStatus == ShareStatus.sharing ||
        current.otherStatus == ShareStatus.paused;

    if (peerSignal == null && peerWasSharing) {
      // Peer's signal is gone — they stopped or it expired.
      // Defer state update to avoid "setState during build".
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) markOtherStopped();
      });
      return;
    }

    // No attributable peer stop — check whether our own row was removed.
    await _handleOwnSignalGone(current);
  }

  /// Handles our own signal row disappearing (pg_cron expiry, or a stale row
  /// replaced while re-sharing). Announces the expiry only when this device
  /// still believed it was sharing and the row is really gone.
  Future<void> _handleOwnSignalGone(LocationShareSession current) async {
    if (_disposed) return;
    final user = _supabase.auth.currentUser;
    if (user == null || current.myStatus != ShareStatus.sharing) return;

    final now = DateTime.now().toUtc().toIso8601String();
    final mySignal = await _supabase
        .from('location_share_signals')
        .select('id')
        .eq('match_id', current.matchId)
        .eq('sharer_id', user.id)
        .or('expires_at.gt.$now,expires_at.is.null')
        .maybeSingle();

    if (_disposed || mySignal != null) return;

    // Our signal was deleted — share expired.
    // Stop GPS but keep receiving if peer is still sharing.
    _stopGpsSubscription();
    await BackgroundService.stopLocationShare();
    _cancelExpirationTimer();
    String notifText;
    try {
      final l10n = ref.read(localizationProvider);
      notifText = l10n.getString('locationShareExpired');
    } catch (_) {
      notifText = 'Location sharing has ended';
    }
    _showInAppNotification(notifText, 'location_sharing');
    // Defer state update to avoid "setState during build".
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        state = (state ?? current).copyWith(
          myStatus: ShareStatus.stopped,
          myPosition: null,
        );
      }
    });
  }

  /// Stop listening for signals
  void stopListeningForSignals() {
    _signalChannel?.unsubscribe();
    _signalChannel = null;
    _signalChannelSubscribed = false;
    _signalChannelUserId = null;
    _signalSubscribeInFlight = false;
  }

  /// Whether the signal listener is currently active and subscribed.
  bool get isListeningForSignals => _signalChannelSubscribed;

  /// Check if there's an active share signal from the other user for a given match
  Future<bool> hasActiveShareSignal(String matchId) async {
    if (shouldSkipSupabaseCalls()) return false;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return false;

      final signals = await _supabase
          .from('location_share_signals')
          .select('id')
          .eq('match_id', matchId)
          .neq('sharer_id', user.id)
          .or(
            'expires_at.gt.${DateTime.now().toUtc().toIso8601String()},'
            'expires_at.is.null',
          )
          .limit(1);

      return signals.isNotEmpty;
    } catch (e) {
      print('LocationShare: Failed to check signal: $e');
      return false;
    }
  }

  Future<DateTime?> _fetchSignalExpiresAt(
    String matchId,
    String sharerId,
  ) async {
    if (shouldSkipSupabaseCalls()) return null;
    try {
      final signal = await _supabase
          .from('location_share_signals')
          .select('expires_at')
          .eq('match_id', matchId)
          .eq('sharer_id', sharerId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (signal == null) return null;
      final expiresAtStr = signal['expires_at'] as String?;
      return expiresAtStr != null ? DateTime.parse(expiresAtStr) : null;
    } catch (_) {
      return null;
    }
  }

  /// Update signal expiry without delete+insert cycle to avoid a brief
  /// "stopped" flash on the receiver's side (DELETE triggers markOtherStopped).
  Future<void> _updateSignalExpiry(String matchId, DateTime? expiresAt) async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      print(
        'LocationShare: Updating signal for match=$matchId user=${user.id}',
      );
      print('LocationShare: expires_at=${expiresAt?.toIso8601String()}');

      await _supabase
          .from('location_share_signals')
          .update({'expires_at': expiresAt?.toUtc().toIso8601String()})
          .eq('match_id', matchId)
          .eq('sharer_id', user.id);
    } catch (e) {
      print('LocationShare: Failed to update signal: $e');
      // Fallback to insert if update fails (signal may not exist)
      await _insertSignal(matchId, expiresAt);
    }
  }

  Future<void> _insertSignal(String matchId, DateTime? expiresAt) async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      print(
        'LocationShare: Inserting signal for match=$matchId user=${user.id}',
      );
      print('LocationShare: expires_at=${expiresAt?.toIso8601String()}');

      // Delete any stale signal for this match+sharer before inserting a new
      // one. The realtime DELETE it emits is ours, not the peer stopping.
      _ownSignalDeleteSuppressions++;
      try {
        await _supabase
            .from('location_share_signals')
            .delete()
            .eq('match_id', matchId)
            .eq('sharer_id', user.id);

        await _supabase.from('location_share_signals').insert({
          'match_id': matchId,
          'sharer_id': user.id,
          if (expiresAt != null)
            'expires_at': expiresAt.toUtc().toIso8601String(),
        });
      } finally {
        _ownSignalDeleteSuppressions--;
      }
      print('LocationShare: Signal inserted successfully');
    } catch (e) {
      print('LocationShare: Failed to insert signal: $e');
    }
  }

  Future<void> stopSharing() async {
    if (state == null) return;
    final current = state!;
    _ownSignalDeleteSuppressions++;
    try {
      await _sendSessionStop();
      await _deleteSignal();
      await _deletePositionFromDb(current.matchId);
      _stopGpsSubscription();
      await BackgroundService.stopLocationShare();
      _cancelExpirationTimer();
      await _clearPersistedSessionState();

      // Check if the peer is still sharing — if so, transition to receiver
      // mode instead of tearing everything down.
      final peerStillSharing = await _isPeerSignalActive(
        current.matchId,
        current.otherUserId,
      );
      if (peerStillSharing && !_disposed) {
        state = current.copyWith(
          myStatus: ShareStatus.stopped,
          myPosition: null,
          broadcastMode: BroadcastMode.none,
        );
        _startStaleTimer();
        return;
      }

      // Peer is not sharing — full cleanup
      await _cleanup();
      state = null;
    } finally {
      _ownSignalDeleteSuppressions--;
    }
  }

  Future<bool> _isPeerSignalActive(String matchId, String peerId) async {
    if (shouldSkipSupabaseCalls()) return false;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final signal = await _supabase
          .from('location_share_signals')
          .select('id')
          .eq('match_id', matchId)
          .eq('sharer_id', peerId)
          .or('expires_at.gt.$now,expires_at.is.null')
          .maybeSingle();
      return signal != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteSignal() async {
    if (shouldSkipSupabaseCalls()) return;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null || state == null) return;

      await _supabase
          .from('location_share_signals')
          .delete()
          .eq('sharer_id', user.id)
          .eq('match_id', state!.matchId);
    } catch (e) {
      print('LocationShare: Failed to delete signal: $e');
    }
  }

  Future<void> pauseSharing() async {
    if (state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.sharing) return;
    _stopGpsSubscription();
    await BackgroundService.stopLocationShare();
    state = current.copyWith(
      myStatus: ShareStatus.paused,
      broadcastMode: BroadcastMode.none,
    );
    await _sendSessionPause();
  }

  Future<void> resumeSharing() async {
    if (state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.paused) return;
    state = current.copyWith(
      myStatus: ShareStatus.sharing,
      broadcastMode: BroadcastMode.flutter,
    );
    _startGpsStreaming(current.updateInterval);
    await BackgroundService.startLocationShare(
      matchId: current.matchId,
      otherUserId: current.otherUserId,
      sessionKeyBase64: base64Encode(_sessionKey!),
      updateIntervalSeconds: current.updateInterval.inSeconds,
      expiresAtIso: current.expiresAt?.toUtc().toIso8601String(),
    );
    await _sendSessionResume();
    _sendLocationUpdate();
  }

  // ---------------------------------------------------------------------------
  // Session key derivation & encryption
  // ---------------------------------------------------------------------------

  Future<void> _deriveSessionKey(String otherUserId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final myPrivateKey = await _chatKeyService.loadPrivateKeyBytes(user.id);
      if (myPrivateKey == null) {
        print('LocationShare: Failed to load private key');
        return;
      }

      final theirActiveKey = await _chatKeyService.fetchActiveKey(otherUserId);
      if (theirActiveKey == null) {
        print('LocationShare: Failed to fetch peer active key');
        return;
      }

      final theirPublicKeyBytes = base64Decode(theirActiveKey.publicKeyBase64);

      final sharedSecret = await _crypto.x25519SharedSecretFromPrivateKey(
        myPrivateKey: myPrivateKey,
        theirPublicKey: theirPublicKeyBytes,
      );

      final saltUserIds = [user.id, otherUserId]..sort();
      final salt = Uint8List.fromList(
        utf8.encode('location_share:${saltUserIds[0]}:${saltUserIds[1]}'),
      );
      _sessionKey = await _crypto.hkdfDeriveBytes(
        inputKeyMaterial: sharedSecret,
        salt: salt,
        info: 'matchme-location-share-v1',
      );

      state = state!.copyWith(sessionKey: _sessionKey);
    } catch (e) {
      print('LocationShare: Key derivation failed: $e');
    }
  }

  Future<Uint8List?> _encryptLocationPayload(Map<String, dynamic> data) async {
    if (_sessionKey == null) return null;
    try {
      final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      final nonce = _crypto.generateNonce();
      final aad = Uint8List.fromList(utf8.encode('matchme.location.v1'));

      final encrypted = await _crypto.aesGcmEncrypt(
        plaintext: plaintext,
        key: _sessionKey!,
        nonce: nonce,
        aad: aad,
      );

      return Uint8List.fromList(nonce + encrypted);
    } catch (e) {
      print('LocationShare: Encryption failed: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _decryptLocationPayload(
    Uint8List encryptedData,
  ) async {
    if (_sessionKey == null) return null;
    try {
      final nonce = encryptedData.sublist(0, 12);
      final ciphertext = encryptedData.sublist(12);
      final aad = Uint8List.fromList(utf8.encode('matchme.location.v1'));

      final decrypted = await _crypto.aesGcmDecrypt(
        ciphertext: ciphertext,
        key: _sessionKey!,
        nonce: nonce,
        aad: aad,
      );

      return jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
    } catch (e) {
      print('LocationShare: Decryption failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Broadcast channel (session control messages + low-latency location updates)
  // ---------------------------------------------------------------------------

  Future<void> _subscribeToBroadcastChannel() async {
    if (state == null || _disposed) return;
    if (shouldSkipSupabaseCalls()) return;

    final channelName = 'location_share:${state!.matchId}';

    // Clean up any previous channel before creating a new one
    if (_channel != null) {
      try {
        await _supabase.removeChannel(_channel!);
      } catch (_) {}
      _channel = null;
    }

    _channel = _supabase.channel(channelName);

    _channel!.onBroadcast(
      event: 'session_start',
      callback: (data) {
        if (_disposed || state == null) return;
        final senderId = _unwrapBroadcastPayload(data)['userId'] as String?;
        final current = state;
        if (current == null || senderId == current.myUserId) return;

        if (!_disposed) {
          state = current.copyWith(otherStatus: ShareStatus.sharing);
        }
        // The peer may have started before their photo finished loading.
        unawaited(ensureOtherUserPhoto());
      },
    );

    _channel!.onBroadcast(
      event: 'session_stop',
      callback: (data) {
        if (_disposed || state == null) return;
        final senderId = _unwrapBroadcastPayload(data)['userId'] as String?;
        final current = state;
        if (current == null || senderId == current.myUserId) return;

        final otherName = current.otherUserName;
        if (!_disposed) {
          state = current.copyWith(
            otherStatus: ShareStatus.stopped,
            otherPosition: null,
            otherPositionTimestamp: null,
          );
        }

        String notifText;
        try {
          final l10n = ref.read(localizationProvider);
          notifText = l10n
              .getString('locationShareOtherStopped')
              .replaceAll('{name}', otherName);
        } catch (_) {
          notifText = '$otherName stopped sharing their location';
        }

        _showInAppNotification(notifText, 'location_sharing');
      },
    );

    _channel!.onBroadcast(
      event: 'session_pause',
      callback: (data) {
        if (_disposed || state == null) return;
        final senderId = _unwrapBroadcastPayload(data)['userId'] as String?;
        final current = state;
        if (current == null || senderId == current.myUserId) return;

        if (!_disposed) {
          state = current.copyWith(otherStatus: ShareStatus.paused);
        }
      },
    );

    _channel!.onBroadcast(
      event: 'session_resume',
      callback: (data) {
        if (_disposed || state == null) return;
        final senderId = _unwrapBroadcastPayload(data)['userId'] as String?;
        final current = state;
        if (current == null || senderId == current.myUserId) return;

        if (!_disposed) {
          state = current.copyWith(otherStatus: ShareStatus.sharing);
        }
      },
    );

    _channel!.onBroadcast(
      event: 'duration_updated',
      callback: (data) {
        if (_disposed || state == null) return;
        final unwrapped = _unwrapBroadcastPayload(data);
        final senderId = unwrapped['userId'] as String?;
        final current = state;
        if (current == null || senderId == current.myUserId) return;

        DateTime? expiresAt;
        if (unwrapped.containsKey('expiresAt')) {
          final expiresAtStr = unwrapped['expiresAt'] as String?;
          if (expiresAtStr != null) {
            expiresAt = DateTime.parse(expiresAtStr);
          }
        }

        if (!_disposed) {
          state = current.copyWith(
            otherStatus: ShareStatus.sharing,
            expiresAt: expiresAt,
          );
        }
      },
    );

    // Position broadcasts (encrypted location data)
    _channel!.onBroadcast(
      event: 'broadcast',
      callback: (data) {
        // The data is already the payload from the sender
        unawaited(_handlePositionBroadcast(data));
      },
    );

    final completer = Completer<void>();
    _channel!.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        print('LocationShare: Subscribed to Broadcast channel $channelName');
        if (!completer.isCompleted) completer.complete();
      } else if (status == RealtimeSubscribeStatus.channelError) {
        print('LocationShare: Broadcast channel error: $error');
        if (!completer.isCompleted) {
          completer.completeError(error ?? 'Channel error');
        }
      } else if (status == RealtimeSubscribeStatus.timedOut) {
        print('LocationShare: Broadcast channel timed out (will retry)');
      }
    });

    // Timeout so callers don't hang if subscription never completes
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        print(
          'LocationShare: Broadcast channel subscribe timeout (10s), continuing',
        );
      },
    );
  }

  /// realtime-dart delivers broadcast events as
  /// `{type: 'broadcast', event: <name>, payload: <original payload>}`,
  /// so the original payload sent by the peer must be unwrapped.
  Map<String, dynamic> _unwrapBroadcastPayload(Map<String, dynamic> data) {
    final inner = data['payload'];
    return inner is Map<String, dynamic> ? inner : data;
  }

  // ---------------------------------------------------------------------------
  // GPS streaming & location broadcasting (sender side)
  // ---------------------------------------------------------------------------

  Future<void> _startGpsStreaming(Duration interval) async {
    _stopGpsSubscription();

    // Check location permission before attempting GPS
    try {
      if (!kIsWeb) {
        final permission = await WindowsLocationChannel.checkPermission();
        if (permission == LocationPermission.denied) {
          final requested = await WindowsLocationChannel.requestPermission();
          if (requested == LocationPermission.denied ||
              requested == LocationPermission.deniedForever) {
            print('LocationShare: Location permission denied, stopping share');
            await stopSharing();
            return;
          }
        } else if (permission == LocationPermission.deniedForever) {
          print(
            'LocationShare: Location permission permanently denied, stopping share',
          );
          await stopSharing();
          return;
        }
      }
    } catch (e) {
      print('LocationShare: Permission check failed: $e');
    }

    // Try continuous stream first (works on mobile)
    _gpsSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((position) => _onPositionUpdate(position), onError: (_) {});

    // Also use timer as fallback — on web the stream may not emit
    _gpsTimer = Timer.periodic(interval, (_) => _sendLocationUpdate());

    // Update broadcast mode
    final current = state;
    if (!_disposed &&
        current != null &&
        current.myStatus == ShareStatus.sharing) {
      state = current.copyWith(broadcastMode: BroadcastMode.flutter);
    }

    // Fast path: broadcast the last-known position immediately so the peer
    // renders a marker within ~1s. The high-accuracy fix below refines it.
    // Previously the first broadcast waited for a high-accuracy fix (up to
    // the 10s timeLimit), which is why receivers saw nothing for 10-15s.
    unawaited(_broadcastLastKnownPosition());

    // Send initial high-accuracy position immediately
    _sendLocationUpdate();

    print('LocationShare: Flutter GPS streaming started');
  }

  void _stopGpsSubscription() {
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _gpsTimer?.cancel();
    _gpsTimer = null;
  }

  /// Broadcasts the cached last-known position without waiting for a fresh
  /// GPS fix. Cheap and instant; the periodic high-accuracy updates refine or
  /// replace it via stale-timestamp deduplication on the receiver.
  Future<void> _broadcastLastKnownPosition() async {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.sharing) return;
    try {
      final last = await WindowsLocationChannel.getLastKnownPosition();
      if (last != null) _onPositionUpdate(last);
    } catch (_) {
      // No cached fix — the high-accuracy request below covers it.
    }
  }

  void _onPositionUpdate(Position position) {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.sharing) return;

    final latLng = LatLng(position.latitude, position.longitude);

    if (!_disposed) {
      state = current.copyWith(myPosition: latLng);
    }

    _broadcastLocation(position);
  }

  Future<void> _sendLocationUpdate() async {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.sharing) return;

    // Check if location services are enabled before attempting GPS
    try {
      final serviceEnabled = await WindowsLocationChannel.isLocationServiceEnabled();
      if (!serviceEnabled) return;
    } catch (_) {
      return;
    }

    try {
      // Use deduplicator to prevent concurrent getCurrentPosition calls
      // when timer ticks, NearbyMapScreen, and visibility changes all
      // request position simultaneously.
      final position = await LocationDeduplicator.getPosition(
        label: 'locationShare',
        fetcher: () async {
          final pos = await WindowsLocationChannel.getPosition(
            accuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 10),
          );
          if (pos != null) return pos;
          try {
            return await WindowsLocationChannel.getLastKnownPosition();
          } catch (_) {
            return null;
          }
        },
      );

      if (position != null) _onPositionUpdate(position);
    } catch (_) {
      // GPS unavailable — timer will retry on next tick
    }
  }

  /// Broadcasts the location via the Flutter Realtime broadcast channel.
  /// The native background service broadcasts via its own Realtime WebSocket.
  Future<void> _broadcastLocation(Position position) async {
    if (_disposed || state == null) return;

    try {
      final locationData = {
        'lat': position.latitude,
        'lng': position.longitude,
        'heading': position.heading,
        'speed': position.speed,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'userId': state!.myUserId,
      };

      final encrypted = await _encryptLocationPayload(locationData);
      if (encrypted == null || _disposed) return;

      final encryptedB64 = base64Encode(encrypted);

      // Broadcast via Realtime position channel (low-latency, foreground).
      // The channel must be subscribed before sending so the message flows
      // over the WebSocket — the REST fallback used by realtime-dart for
      // unsubscribed channels requires RLS policies on realtime.messages,
      // which are not provisioned in this project.
      final posChannel = await _getPositionChannel();
      if (posChannel == null || _disposed) return;
      await posChannel.sendBroadcastMessage(
        event: 'position',
        payload: {'data': encryptedB64, 'userId': state!.myUserId},
      );
    } catch (e) {
      print('LocationShare: Failed to broadcast location update: $e');
    }
  }

  /// Returns the shared position channel, creating and subscribing it on
  /// first use. Both the sharer (sending) and the viewer (receiving) use
  /// this same channel, so broadcasts flow over the WebSocket in both
  /// directions.
  Future<RealtimeChannel?> _getPositionChannel() {
    if (shouldSkipSupabaseCalls()) return Future.value(null);
    final current = state;
    if (_disposed || current == null) return Future.value(null);

    final existing = _positionChannel;
    if (existing != null && _positionChannelSubscribed) {
      return Future.value(existing);
    }

    final inFlight = _positionChannelFuture;
    if (inFlight != null) return inFlight;

    final future = _createPositionChannel();
    _positionChannelFuture = future;
    return future;
  }

  Future<RealtimeChannel?> _createPositionChannel() async {
    if (shouldSkipSupabaseCalls()) return null;
    try {
      if (_disposed || state == null) return null;
      final topic = 'location-share:${state!.matchId}';

      var channel = _positionChannel;
      if (channel == null) {
        channel = _supabase.channel(topic);
        _positionChannel = channel;
        _positionChannelSubscribed = false;
        channel.onBroadcast(
          event: 'position',
          callback: (payload) async => _handlePositionBroadcast(payload),
        );
        channel.onBroadcast(
          event: 'location_update',
          callback: (payload) async => _handlePositionBroadcast(payload),
        );
      }

      final completer = Completer<bool>();
      try {
        channel.subscribe((status, error) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            _positionChannelSubscribed = true;
            if (!completer.isCompleted) completer.complete(true);
          } else if (status == RealtimeSubscribeStatus.channelError &&
              !completer.isCompleted) {
            completer.complete(false);
          }
        });
      } catch (_) {
        // subscribe() can only be called once per channel instance; if this
        // channel was already subscribed or joined once, tear it down and
        // create a fresh one.
        _positionChannel = null;
        _positionChannelSubscribed = false;
        try {
          await _supabase.removeChannel(channel);
        } catch (_) {}
        return await _createPositionChannel();
      }

      final ok = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      if (!ok || _disposed || state == null) return null;
      return channel;
    } finally {
      _positionChannelFuture = null;
    }
  }

  /// Handles an inbound position broadcast. realtime-dart delivers broadcast
  /// events as `{type: 'broadcast', event: <name>, payload: <original payload>}`,
  /// so the base64 data lives at `payload['payload']['data']`.
  Future<void> _handlePositionBroadcast(Map<String, dynamic> payload) async {
    if (_disposed || state == null) return;

    final inner = payload['payload'];
    dynamic encryptedPayload = inner is Map ? inner['data'] : payload['data'];
    final encryptedB64 = encryptedPayload is String ? encryptedPayload : null;
    if (encryptedB64 == null) return;

    // Fast-path: if the broadcast envelope includes the sender's userId,
    // immediately skip our own broadcasts — this prevents the sharer's own
    // GPS updates from being applied as "other user's location", which was
    // causing the banner to falsely toggle to "mutual sharing active"
    // (every ~5 s) then back to "you are sharing" (~35 s, stale timeout).
    final envelopeUserId = inner is Map
        ? inner['userId'] as String?
        : payload['userId'] as String?;
    if (envelopeUserId != null && envelopeUserId == state!.myUserId) {
      return;
    }

    try {
      final encryptedBytes = base64Decode(encryptedB64);
      final locationData = await _decryptLocationPayload(encryptedBytes);
      if (locationData == null || _disposed || state == null) return;
      _applyPeerLocation(locationData, envelopeSenderUserId: envelopeUserId);
    } catch (_) {
      // Malformed or undecryptable payloads are ignored.
    }
  }

  /// No-op: positions are never stored in the database.
  Future<void> _deletePositionFromDb(String matchId) async {
    // No-op: positions are never stored in the database.
  }

  // ---------------------------------------------------------------------------
  // Session control broadcast messages
  // ---------------------------------------------------------------------------

  Future<void> _sendSessionStart() async {
    if (_channel == null || state == null || _disposed) return;
    await _channel!.sendBroadcastMessage(
      event: 'session_start',
      payload: {'userId': state!.myUserId},
    );
  }

  Future<void> _sendSessionStop() async {
    if (_channel == null || state == null) return;
    await _channel!.sendBroadcastMessage(
      event: 'session_stop',
      payload: {'userId': state!.myUserId},
    );
  }

  Future<void> _sendSessionPause() async {
    if (_channel == null || state == null) return;
    await _channel!.sendBroadcastMessage(
      event: 'session_pause',
      payload: {'userId': state!.myUserId},
    );
  }

  Future<void> _sendSessionResume() async {
    if (_channel == null || state == null) return;
    await _channel!.sendBroadcastMessage(
      event: 'session_resume',
      payload: {'userId': state!.myUserId},
    );
  }

  Future<void> _sendDurationUpdated(DateTime? expiresAt) async {
    if (_channel == null || state == null || _disposed) return;
    await _channel!.sendBroadcastMessage(
      event: 'duration_updated',
      payload: {
        'userId': state!.myUserId,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Stale timer (receiver-side staleness detection)
  // ---------------------------------------------------------------------------

  void _startStaleTimer() {
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkStaleness();
    });
  }

  Future<void> _checkStaleness() async {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null) return;
    if (current.otherPositionTimestamp == null) return;
    if (current.otherStatus != ShareStatus.sharing) return;

    final inactiveTimeout = await appConfigService.getInt(
      'location_sharing.inactive_timeout_seconds',
      defaultValue: 30,
    );

    if (_disposed || state == null) return;
    final latest = state;
    if (latest == null) return;

    // Re-check: otherStatus might have changed during the await gap above
    // (e.g. broadcast session_stop set it to stopped, or the sharer sent a
    // new position).  Don't overwrite with unknown if it's no longer sharing.
    if (latest.otherStatus != ShareStatus.sharing) return;

    final elapsed = DateTime.now().difference(latest.otherPositionTimestamp!);
    if (elapsed.inSeconds > inactiveTimeout) {
      state = latest.copyWith(otherStatus: ShareStatus.unknown);
    }
  }

  // ---------------------------------------------------------------------------
  // Receiver-side: subscribe to position updates from the DB table
  // ---------------------------------------------------------------------------

  /// Subscribes to the Realtime broadcast channel for live position updates.
  /// The sender (both Flutter foreground and native background service)
  /// broadcasts encrypted positions on this channel. Should be called when
  /// the user opens the live location share map screen and unsubscribed
  /// when they leave.
  Future<void> subscribeToLocationUpdates() async {
    await _getPositionChannel();
  }

  /// Unsubscribe from position updates. Should be called when the user
  /// leaves the live location share map screen.
  void unsubscribeFromLocationUpdates() {
    if (_positionChannel != null) {
      try {
        _supabase.removeChannel(_positionChannel!);
      } catch (_) {}
      _positionChannel = null;
      _positionChannelSubscribed = false;
    }
  }

  /// Fetches the latest position from the DB and applies it to state.
  Future<void> _fetchLatestPositionFromDb() async {
    // No-op: positions are never stored in the database.
    // The receiver receives live updates via the Realtime broadcast channel.
    // When the broadcast channel is reconnected (on app resume), the next
    // position update from the sender will be delivered automatically.
  }

  /// Applies decrypted peer location data to the session state.
  ///
  /// [envelopeSenderUserId] is set when the Realtime broadcast envelope
  /// includes a `userId` field (Flutter foreground sender path). The native
  /// Android/iOS services do not currently include the userId in the envelope,
  /// so we also read and validate a `userId` field inside the [locationData]
  /// payload itself (newer senders write it). If neither source provides a
  /// userId, we fall back to accepting the update only when the peer's share
  /// was already confirmed via another signal (a DB signal or `session_start`
  /// broadcast) — this prevents the sharer's own encrypted positions (which
  /// we could not decrypt from the *other* user's session key, but could in
  /// mutual-sharing scenarios) from being misattributed.
  void _applyPeerLocation(
    Map<String, dynamic> locationData, {
    String? envelopeSenderUserId,
  }) {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null) return;

    final lat = (locationData['lat'] as num).toDouble();
    final lng = (locationData['lng'] as num).toDouble();
    final timestamp = locationData['ts'] as int?;
    final innerUserId = locationData['userId'] as String?;

    // 1) Strongest identity: userId stored inside the encrypted payload
    //    itself (written by the sender). Cannot be spoofed because payload is
    //    authenticated via AES-GCM tag. Only decrypts when both users share
    //    the same session key (which they do for a given match).
    final senderUserId = innerUserId ?? envelopeSenderUserId;
    if (senderUserId != null && senderUserId == current.myUserId) {
      // This is *our own* broadcast being echoed back by Realtime. Ignore.
      return;
    }

    if (current.otherStatus == ShareStatus.stopped) {
      // The peer already stopped sharing — drop any late/in-flight position
      // packets so a stale coordinate cannot resurrect the banner.
      return;
    }

    // 2) Stale-timestamp deduplication.
    final newTs = timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : DateTime.now();
    if (current.otherPositionTimestamp != null &&
        newTs.isBefore(current.otherPositionTimestamp!)) {
      return;
    }

    // 3) Only elevate `otherStatus` to `sharing` when we have evidence the
    //    other user actually started sharing: either the sender ID is the
    //    other user's ID, or we had already set `otherStatus = sharing` via
    //    a trusted channel (session_start broadcast, other signal in DB).
    //    Without this guard, the sharer's own misattributed broadcasts
    //    would toggle the banner between "mutual" and "sharer-only".
    final canSetSharing =
        (senderUserId == current.otherUserId) ||
        (current.otherStatus == ShareStatus.sharing) ||
        (current.otherStatus == ShareStatus.paused) ||
        (senderUserId == null && current.otherPosition != null);

    state = current.copyWith(
      otherPosition: LatLng(lat, lng),
      otherPositionTimestamp: newTs,
      otherStatus: canSetSharing ? ShareStatus.sharing : current.otherStatus,
    );

    // Late photo backfill: the first coordinates may arrive before the peer
    // photo fetch finished (or the session was created with none).
    if (current.otherUserPhoto?.isNotEmpty != true) {
      unawaited(ensureOtherUserPhoto());
    }
  }

  // ---------------------------------------------------------------------------
  // App resume reconciliation
  // ---------------------------------------------------------------------------

  /// Re-fetches the sharer's signal from the database after the app returns
  /// to foreground.  Broadcast and Postgres Changes events may have been
  /// missed while the app was backgrounded, so we reconcile against the
  /// source of truth.
  Future<void> syncOtherSignalFromDb() async {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) return;

    final current = state;
    if (current == null) {
      // No session exists — the INSERT event may have been missed while
      // backgrounded.  Check for any active signals from other users.
      await _recoverMissedSignals();
      return;
    }

    // --- Sharer-side sync: if I am the sharer, force-send my position ---
    if (current.myStatus == ShareStatus.sharing) {
      debugPrint(
        'LocationShare: syncOtherSignalFromDb - resending own position',
      );
      _sendLocationUpdate();
    }

    try {
      debugPrint(
        'LocationShare: syncOtherSignalFromDb querying match=${current.matchId} sharer=${current.otherUserId}',
      );

      if (_disposed || state == null) return;
      final latest = state!;

      final signal = await _supabase
          .from('location_share_signals')
          .select('expires_at')
          .eq('match_id', current.matchId)
          .eq('sharer_id', current.otherUserId)
          .or(
            'expires_at.gt.${DateTime.now().toUtc().toIso8601String()},'
            'expires_at.is.null',
          )
          .maybeSingle();

      if (signal == null) {
        // Signal was deleted while we were in the background — peer stopped.
        // Only mark as stopped if the other user was actually sharing before
        // (otherStatus was sharing/paused). If otherStatus is unknown, the
        // other user was never sharing (e.g. we are the sharer and they are
        // only receiving), so a missing signal is expected — not a stop.
        if (latest.otherStatus == ShareStatus.sharing ||
            latest.otherStatus == ShareStatus.paused) {
          debugPrint(
            'LocationShare: syncOtherSignalFromDb - no signal found, marking stopped',
          );
          markOtherStopped();
          return;
        }
        debugPrint(
          'LocationShare: syncOtherSignalFromDb - no signal from other user (otherStatus=${latest.otherStatus}), skipping stop',
        );
        return;
      }

      // The other user has an ACTIVE signal in the DB → they are sharing.
      // Promote their status to `sharing` so subsequent position applies
      // correctly and the banner no longer toggles due to stale-timer.
      if (latest.otherStatus != ShareStatus.sharing &&
          latest.otherStatus != ShareStatus.paused &&
          !_disposed) {
        state = latest.copyWith(otherStatus: ShareStatus.sharing);
      }

      // --- Check duration changes ---
      final dbExpiresAtStr = signal['expires_at'] as String?;
      final dbExpiresAt = dbExpiresAtStr != null
          ? DateTime.parse(dbExpiresAtStr).toLocal()
          : null;

      if (!_disposed && state != null) {
        final ce = state!.expiresAt;
        final changed =
            (dbExpiresAt == null && ce != null) ||
            (dbExpiresAt != null &&
                (ce == null || dbExpiresAt.difference(ce).abs().inSeconds > 1));
        if (changed) {
          debugPrint(
            'LocationShare: syncOtherSignalFromDb - expiresAt changed, updating',
          );
          updateOtherExpiresAt(dbExpiresAt);
        }
      }

      // Also fetch the latest position from the DB if we're actively
      // viewing the share (position channel is active).
      if (_positionChannel != null) {
        await _fetchLatestPositionFromDb();
      }
    } catch (e) {
      debugPrint('LocationShare: Failed to sync signal from DB: $e');
    }
  }

  /// Force an immediate GPS position broadcast. Called when the app resumes
  /// from background so the peer sees our current position right away
  /// instead of waiting for the next timer tick.
  void forceBroadcastLocation() {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null || current.myStatus != ShareStatus.sharing) return;
    _sendLocationUpdate();
  }

  /// Called when the app UI becomes visible again (e.g. user returns to the
  /// app after it was backgrounded or the browser tab was hidden). On web
  /// and desktop, the JavaScript event loop is throttled while the tab/app
  /// is in the background, so timers and WebSocket connections may have
  /// stalled. This method forces a position broadcast and ensures the
  /// broadcast channel is still subscribed.
  ///
  /// Call this from WidgetsBindingObserver.didChangeAppLifecycleState when
  /// the state becomes AppLifecycleState.resumed, or from visibility
  /// change handlers.
  void onAppResumed() {
    if (_disposed || state == null) return;
    final current = state;
    if (current == null) return;

    // The position channel (live coordinates) is torn down with every
    // Realtime disconnect (main.dart disconnects on background). Rejoin it
    // whenever a session is active — sender and receiver alike — otherwise
    // the receiver never gets positions again until the map is reopened.
    unawaited(subscribeToLocationUpdates());

    // Re-subscribe to the broadcast channel in case it was disconnected
    // while the app was in the background (e.g. browser closed idle
    // WebSocket connections).
    if (current.myStatus == ShareStatus.sharing && !_disposed) {
      _subscribeToBroadcastChannel().then((_) {
        if (!_disposed) {
          // Force an immediate GPS position broadcast so the peer sees
          // our current location right away.
          _sendLocationUpdate();
        }
      });
    }

    // Also re-subscribe the receiver if we are viewing someone else's share
    if (current.myStatus == ShareStatus.stopped &&
        current.otherStatus == ShareStatus.sharing &&
        !_disposed) {
      _subscribeToBroadcastChannel();
    }
  }

  /// App-level background entry: hand sender broadcasting to the native
  /// service. Safe to call from anywhere (map screen + root observer);
  /// [handoffToNativeService] is idempotent. No-op on web (no native).
  Future<void> handleAppBackgrounded() => handoffToNativeService();

  /// App-level foreground entry: take back sender broadcasting, rejoin the
  /// position + control channels, and reconcile missed signals against the
  /// DB (Postgres Changes events are not replayed on reconnect).
  Future<void> handleAppResumed() async {
    if (_disposed || state == null) return;
    await takeoverFromNativeService();
    onAppResumed();
    await syncOtherSignalFromDb();
  }

  /// Queries the database for any active location share signals from other
  /// users that we may have missed while the app was backgrounded (Postgres
  /// Changes INSERT events are not replayed on WebSocket reconnect).
  Future<void> _recoverMissedSignals() async {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) return;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final now = DateTime.now().toUtc().toIso8601String();
      debugPrint(
        'LocationShare: _recoverMissedSignals checking for missed signals',
      );

      final signals = await _supabase
          .from('location_share_signals')
          .select('match_id, sharer_id, expires_at')
          .neq('sharer_id', user.id)
          .or('expires_at.gt.$now,expires_at.is.null')
          .limit(5);

      for (final signal in signals) {
        if (_disposed || state != null) {
          break; // Session was created by a concurrent call
        }

        final matchId = signal['match_id'] as String?;
        final sharerId = signal['sharer_id'] as String?;
        final expiresAtStr = signal['expires_at'] as String?;
        if (matchId == null || sharerId == null) continue;

        // Fetch the sharer's display name from users table
        final profile = await _supabase
            .from('users')
            .select('name')
            .eq('id', sharerId)
            .maybeSingle();
        if (_disposed) return;
        final otherUserName = _formatUserName(profile?['name'] as String?);
        String? otherUserPhoto;
        try {
          final photoProfile = await _supabase
              .from('user_profiles')
              .select('photos')
              .eq('user_id', sharerId)
              .maybeSingle();
          otherUserPhoto = _extractFirstPhoto(photoProfile?['photos']);
        } catch (_) {}

        final DateTime? expiresAt = expiresAtStr != null
            ? DateTime.parse(expiresAtStr).toLocal()
            : null;

        debugPrint(
          'LocationShare: _recoverMissedSignals - creating session for match=$matchId sharer=$sharerId',
        );
        await viewExistingShare(
          matchId: matchId,
          otherUserId: sharerId,
          otherUserName: otherUserName,
          otherUserPhoto: otherUserPhoto,
          expiresAt: expiresAt,
        );
      }

      if (signals.isEmpty) {
        debugPrint(
          'LocationShare: _recoverMissedSignals - no missed signals found',
        );
      }
    } catch (e) {
      debugPrint('LocationShare: Failed to recover missed signals: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // State mutation helpers
  // ---------------------------------------------------------------------------

  /// Marks the other user's share as stopped (called from Postgres Changes
  /// DELETE handlers once the deleted row is attributed to the peer).
  void markOtherStopped() {
    final current = state;
    if (current == null || _disposed) return;

    // Stop ticking the incoming-share notification and remove it from the
    // notification tray — the share it advertised is over.
    _cancelNotifCountdown();
    if (!kIsWeb) {
      MobileLocalNotificationService.cancelLocationShareNotification(
        notificationId: 'location_share_${current.matchId}',
      );
    }

    // Only the peer ending an actual share is worth announcing. `unknown`
    // means they were never seen sharing, and `stopped` was already
    // announced — neither may produce the "stopped sharing" notice again.
    if (current.otherStatus != ShareStatus.sharing &&
        current.otherStatus != ShareStatus.paused) {
      return;
    }

    final otherName = current.otherUserName;
    if (!_disposed) {
      state = current.copyWith(
        otherStatus: ShareStatus.stopped,
        otherPosition: null,
        otherPositionTimestamp: null,
      );
    }

    String notifText;
    try {
      final l10n = ref.read(localizationProvider);
      notifText = l10n
          .getString('locationShareOtherStopped')
          .replaceAll('{name}', otherName);
    } catch (_) {
      notifText = '$otherName stopped sharing their location';
    }

    _showInAppNotification(notifText, 'location_sharing');
  }

  /// Updates the local expiresAt from a signal re-insertion (duration change).
  void updateOtherExpiresAt(DateTime? expiresAt) {
    final current = state;
    if (current == null || _disposed) return;

    if (!_disposed) {
      state = current.copyWith(
        otherStatus: ShareStatus.sharing,
        expiresAt: expiresAt,
      );
    }

    // Keep the live notification countdown in sync with the new expiry.
    if (expiresAt != null) {
      _startNotifCountdown(
        matchId: current.matchId,
        otherUserName: current.otherUserName,
        expiresAt: expiresAt.toUtc(),
      );
    } else {
      _cancelNotifCountdown();
    }
  }

  void _showInAppNotification(
    String text,
    String type, {
    bool persistent = false,
    DateTime? countdownExpiresAt,
  }) {
    if (_disposed) return;
    try {
      ref
          .read(systemNotificationProvider.notifier)
          .notify(
            SystemNotification(
              text: text,
              isPersistent: persistent,
              notificationType: type,
              countdownExpiresAt: countdownExpiresAt,
            ),
          );
    } catch (e) {
      print('LocationShare: Failed to show in-app notification: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming-share notification live countdown
  // ---------------------------------------------------------------------------

  /// Starts a per-second ticker that re-renders the OS-level "X is sharing
  /// their location" notification with an up-to-date remaining-time suffix,
  /// until the share expires or the peer stops sharing. The in-app banner
  /// does not need this — the overlay re-renders it itself every second.
  void _startNotifCountdown({
    required String matchId,
    required String otherUserName,
    required DateTime expiresAt,
  }) {
    _cancelNotifCountdown();
    if (_disposed) return;

    _notifCountdownMatchId = matchId;
    _notifCountdownName = otherUserName;
    _notifCountdownExpiresAt = expiresAt;

    void updateOsNotifications({required bool silent}) {
      if (_disposed || _notifCountdownExpiresAt == null) return;
      String title;
      String body;
      try {
        final l10n = ref.read(localizationProvider);
        final base = l10n
            .getString('locationShareReceiving')
            .replaceAll('{name}', _notifCountdownName);
        final suffix = buildLocationShareCountdownSuffix(
          expiresAt: _notifCountdownExpiresAt,
          now: DateTime.now(),
          getString: l10n.getString,
        );
        title = '📍 $_notifCountdownName';
        body = '$base$suffix';
      } catch (_) {
        final remaining = _notifCountdownExpiresAt!.difference(
          DateTime.now().toUtc(),
        );
        if (remaining.isNegative || remaining.inSeconds <= 0) return;
        final hours = remaining.inHours;
        final minutes = remaining.inMinutes % 60;
        final seconds = remaining.inSeconds % 60;
        title = '📍 $_notifCountdownName';
        // English fallback for the case where the localization layer is not
        // available: the units still take the right plural form.
        final duration = hours > 0
            ? '${_englishCountUnit(hours, 'hour')} and '
                  '${_englishCountUnit(minutes, 'minute')} and '
                  '${_englishCountUnit(seconds, 'second')}'
            : '${_englishCountUnit(minutes, 'minute')} and '
                  '${_englishCountUnit(seconds, 'second')}';
        body =
            '$_notifCountdownName is sharing their live location with you'
            ' - for another $duration';
      }

      try {
        if (kIsWeb) {
          WebNotificationService.showLocationShareNotification(
            title: title,
            body: body,
            silent: silent,
          );
        } else if (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) {
          MobileLocalNotificationService.showLocationShareNotification(
            notificationId: 'location_share_$_notifCountdownMatchId',
            title: title,
            body: body,
            silent: silent,
          );
        }
      } catch (e) {
        print('LocationShare: Failed to update OS notification: $e');
      }
    }

    bool tickInProgress = false;
    _notifCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      _,
    ) async {
      if (_disposed) {
        _cancelNotifCountdown();
        return;
      }
      if (tickInProgress) return;
      tickInProgress = true;
      try {
        final expiresAtUtc = _notifCountdownExpiresAt?.toUtc();
        if (expiresAtUtc == null) {
          _cancelNotifCountdown();
          return;
        }
        final remaining = expiresAtUtc.difference(DateTime.now().toUtc());
        if (remaining.isNegative || remaining.inSeconds <= 0) {
          final matchId = _notifCountdownMatchId;
          _cancelNotifCountdown();
          if (matchId != null && !kIsWeb) {
            await MobileLocalNotificationService.cancelLocationShareNotification(
              notificationId: 'location_share_$matchId',
            );
          }
          return;
        }

        // If the user cleared the OS notification from the tray, stop
        // updating it — a re-post would make it reappear.
        if (!kIsWeb) {
          final matchId = _notifCountdownMatchId;
          if (matchId == null) {
            _cancelNotifCountdown();
            return;
          }
          final stillVisible =
              await MobileLocalNotificationService.isLocationShareNotificationActive(
                notificationId: 'location_share_$matchId',
              );
          // Timer may have been cancelled while awaiting the platform check.
          if (_disposed || _notifCountdownTimer == null) return;
          if (!stillVisible) {
            _cancelNotifCountdown();
            return;
          }
        }

        // Silent so per-second updates don't replay sound/vibration.
        updateOsNotifications(silent: true);
      } finally {
        tickInProgress = false;
      }
    });
  }

  void _cancelNotifCountdown() {
    _notifCountdownTimer?.cancel();
    _notifCountdownTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Session state persistence (for native background service)
  // ---------------------------------------------------------------------------

  /// Persists the session state so the native background service can continue
  /// broadcasting when the app is backgrounded.
  ///
  /// Security: the raw AES session key is stored in SecureStorage (source of
  /// truth). A plain SharedPreferences copy is ALSO kept because the native
  /// Android service/BootReceiver reads FlutterSharedPreferences directly and
  /// would break without it. Backup of these keys is excluded (see Android
  /// dataExtractionRules) and both copies are wiped on stop/logout.
  /// Never log the key value.
  Future<void> _persistSessionState(DateTime? expiresAt) async {
    if (_sessionKey == null || state == null) return;
    try {
      final encodedKey = base64Encode(_sessionKey!);
      // Secure copy first (survives even if shim write fails).
      await SensitiveSessionStore.instance.writeLocationShareKey(encodedKey);
      await SensitiveSessionStore.instance.writeLocationShareIds(
        matchId: state!.matchId,
        otherUserId: state!.otherUserId,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'flutter.location_share_interval',
        state!.updateInterval.inSeconds,
      );
      if (expiresAt != null) {
        await prefs.setString(
          'flutter.location_share_expires_at',
          expiresAt.toUtc().toIso8601String(),
        );
      } else {
        await prefs.remove('flutter.location_share_expires_at');
      }
    } catch (e) {
      print('LocationShare: Failed to persist session state: $e');
    }
  }

  /// Clears the persisted session state from both SecureStorage and prefs.
  /// Also zeroes the in-memory key so it cannot linger after stop.
  Future<void> _clearPersistedSessionState() async {
    try {
      await SensitiveSessionStore.instance.clearLocationShareKey();
    } catch (_) {}
    try {
      if (_sessionKey != null) {
        for (var i = 0; i < _sessionKey!.length; i++) {
          _sessionKey![i] = 0;
        }
      }
    } catch (_) {}
    _sessionKey = null;
  }

  // ---------------------------------------------------------------------------
  // Expiration timer
  // ---------------------------------------------------------------------------

  /// Starts a client-side timer that automatically stops sharing when the
  /// duration expires, rather than relying solely on the DB cleanup.
  void _startExpirationTimer(DateTime? expiresAt) {
    _cancelExpirationTimer();
    if (expiresAt == null) return;

    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) {
      // Already expired — stop immediately
      _expirationTimer = Timer(const Duration(milliseconds: 100), () {
        if (!_disposed) stopSharing();
      });
      return;
    }

    _expirationTimer = Timer(remaining, () {
      if (!_disposed) {
        print('LocationShare: Expiration timer fired, stopping share');
        stopSharing();
      }
    });
  }

  void _cancelExpirationTimer() {
    _expirationTimer?.cancel();
    _expirationTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Broadcast mode coordination (Flutter ↔ Native)
  // ---------------------------------------------------------------------------

  /// Hand off broadcasting to the native background service.
  /// Called when the app is backgrounded or minimized.
  /// Idempotent: repeated calls while already handed off are no-ops, so both
  /// the app-level lifecycle observer and the map screen may call it safely.
  Future<void> handoffToNativeService() async {
    if (_disposed || state == null) return;
    final current = state!;

    if (current.myStatus != ShareStatus.sharing) return;
    if (current.broadcastMode == BroadcastMode.native) return;
    // No native service on web/desktop — keep Flutter GPS running; the
    // browser throttles hidden tabs regardless (see _attachWebHideListener).
    if (kIsWeb) return;

    print('LocationShare: Handing off to native service');

    // Stop Flutter GPS but keep session active
    _stopGpsSubscription();

    // Update broadcast mode
    if (!_disposed) {
      state = current.copyWith(broadcastMode: BroadcastMode.native);
    }

    // Native service should already be running via BackgroundService.startLocationShare()
    // but verify it's active
    try {
      final isNativeRunning = await BackgroundService.isRunning();
      if (!isNativeRunning) {
        print('LocationShare: Native service not running, restarting');
        await BackgroundService.startLocationShare(
          matchId: current.matchId,
          otherUserId: current.otherUserId,
          sessionKeyBase64: base64Encode(_sessionKey!),
          updateIntervalSeconds: current.updateInterval.inSeconds,
          expiresAtIso: current.expiresAt?.toUtc().toIso8601String(),
        );
      }
    } catch (e) {
      print('LocationShare: Failed to hand off to native service: $e');
    }

    print('LocationShare: Handoff complete - native service active');
  }

  /// Take back broadcasting from the native background service.
  /// Called when the app returns to foreground.
  /// Idempotent: no-op unless a previous handoff set native mode.
  Future<void> takeoverFromNativeService() async {
    if (_disposed || state == null) return;
    final current = state!;

    if (current.myStatus != ShareStatus.sharing) return;
    if (current.broadcastMode != BroadcastMode.native) return;

    print('LocationShare: Taking over from native service');

    // Stop native service
    await BackgroundService.stopLocationShare();

    // Restart Flutter GPS
    _startGpsStreaming(current.updateInterval);

    // Update broadcast mode
    if (!_disposed) {
      state = current.copyWith(broadcastMode: BroadcastMode.flutter);
    }

    // Force immediate position broadcast
    _sendLocationUpdate();

    print('LocationShare: Takeover complete - Flutter GPS active');
  }

  /// Log current broadcast state for debugging
  Future<void> logBroadcastState() async {
    if (_disposed) return;

    final current = state;
    if (current == null) {
      print('LocationShare: No active session');
      return;
    }

    final isNativeRunning = await BackgroundService.isRunning();

    print('''
LocationShare Broadcast State:
  Session: ${current.matchId}
  My Status: ${current.myStatus}
  Broadcast Mode: ${current.broadcastMode}
  Flutter GPS: ${_gpsSubscription != null ? "Active" : "Inactive"}
  Native Service: ${isNativeRunning ? "Active" : "Inactive"}
  Expires At: ${current.expiresAt}
  Time Remaining: ${current.timeRemaining}
''');
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Connectivity-aware pause/resume for sender GPS loop
  // ---------------------------------------------------------------------------

  /// Called when connectivity health changes. Pauses GPS streaming when
  /// the device goes offline and resumes when it comes back online.
  void _onConnectivityChanged(
    AsyncValue<ConnectivityHealth>? previous,
    AsyncValue<ConnectivityHealth> next,
  ) {
    if (_disposed) return;
    final health = next.asData?.value;
    if (health == null) return;

    final isOnline = health.isOnline;
    final wasOnline = _wasOnlineBeforeDisconnect;
    final current = state;

    if (!isOnline && wasOnline) {
      // Going offline — pause everything. Clearing [_signalChannel] to null
      // is what allows a fresh subscribe on reconnect; short screen off/on
      // without transport loss never enters this branch, so the channel stays
      // subscribed.
      _wasOnlineBeforeDisconnect = false;
      if (_signalChannel != null) {
        try {
          _signalChannel?.unsubscribe();
        } catch (_) {}
        _signalChannel = null;
        _signalChannelSubscribed = false;
        _signalChannelUserId = null;
        _signalSubscribeInFlight = false;
        debugPrint('LocationShare: Device offline, pausing signal listener');
      }
      if (current != null && current.myStatus == ShareStatus.sharing) {
        _stopGpsSubscription();
        debugPrint('LocationShare: Device offline, pausing GPS streaming');
      }
    } else if (isOnline && !wasOnline) {
      // Coming back online
      _wasOnlineBeforeDisconnect = true;
      if (_signalChannel == null || !_signalChannelSubscribed) {
        debugPrint('LocationShare: Device online, restarting signal listener');
        startListeningForSignals();
      }
      if (current != null && current.myStatus == ShareStatus.sharing) {
        debugPrint('LocationShare: Device online, resuming GPS streaming');
        _startGpsStreaming(current.updateInterval);
        _sendLocationUpdate();
      }
    }
  }

  Future<void> _cleanup() async {
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _gpsTimer?.cancel();
    _gpsTimer = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _cancelExpirationTimer();
    _cancelNotifCountdown();
    _connectivitySubscription?.close();
    _connectivitySubscription = null;

    if (_channel != null) {
      try {
        await _supabase.removeChannel(_channel!);
      } catch (_) {}
      _channel = null;
    }
    if (_signalChannel != null) {
      try {
        await _supabase.removeChannel(_signalChannel!);
      } catch (_) {}
      _signalChannel = null;
      _signalChannelSubscribed = false;
      _signalChannelUserId = null;
      _signalSubscribeInFlight = false;
    }
    if (_positionChannel != null) {
      try {
        await _supabase.removeChannel(_positionChannel!);
      } catch (_) {}
      _positionChannel = null;
      _positionChannelSubscribed = false;
    }
  }
}

/// "1 hour" / "3 hours" — the English fallback used when the localization
/// layer is not available.
String _englishCountUnit(int count, String unit) {
  return '$count $unit${count == 1 ? '' : 's'}';
}

final locationShareProvider =
    NotifierProvider<LocationShareNotifier, LocationShareSession?>(
      LocationShareNotifier.new,
    );
