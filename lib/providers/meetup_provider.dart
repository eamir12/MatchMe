// Meet-up state for one match.
//
// The notifier is an autoDispose family keyed by match id. The chat banner
// and the meet-up screen watch the same instance, so they share one realtime
// channel and one snapshot. Leaving both screens tears everything down.
//
// All writes go through MeetupService -> SECURITY DEFINER RPCs. The provider
// never patches the database directly, so it cannot outrun server-side rate
// limits or state rules.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/landmark_suggestion_service.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/meetup_service.dart';
import 'package:matchme/services/meetup_snapshot_cache.dart';
import 'package:matchme/services/meetup_suggestion_cache.dart';
import 'package:matchme/services/web_location_service.dart';
import 'package:matchme/services/windows_location_channel.dart';
import 'package:matchme/utils/location_deduplicator.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const Object _unset = Object();

class MeetupState {
  final bool loading;
  final bool busy;
  final bool offline;
  final bool suggesting;
  final String? errorKey;
  final String? currentUserId;
  final MeetupSession? session;
  final List<MeetupLandmark> landmarks;
  final List<MeetupSignal> signals;
  final List<MeetupSpotCard> spotCards;
  final List<MeetupPlaceSuggestion> suggestions;

  /// Ranked places beyond [suggestions] from the same lookup. "Show other
  /// places" pages through this without calling the provider again.
  final List<MeetupPlaceSuggestion> suggestionPool;

  /// Which provider produced [suggestions] (`"google"` or `"osm"`). Decides the
  /// attribution line the picker must show, so it is not a cosmetic detail.
  final String suggestionSource;

  /// Signals this device hides locally (a wave or beacon the user dismissed).
  /// It never changes what the other participant sees.
  final Set<String> hiddenSignalIds;

  const MeetupState({
    required this.loading,
    this.busy = false,
    this.offline = false,
    this.suggesting = false,
    this.errorKey,
    this.currentUserId,
    this.session,
    this.landmarks = const [],
    this.signals = const [],
    this.spotCards = const [],
    this.suggestions = const [],
    this.suggestionPool = const [],
    this.suggestionSource = 'osm',
    this.hiddenSignalIds = const <String>{},
  });

  factory MeetupState.initial({String? currentUserId}) =>
      MeetupState(loading: true, currentUserId: currentUserId);

  bool get isProposed => session?.status == MeetupStatus.proposed;

  bool get isActive => session?.status == MeetupStatus.active;

  bool get isEnded => session?.status == MeetupStatus.ended;

  bool get hasOpenSession => session?.isOpen ?? false;

  bool get isOpenAndAlive =>
      session != null && session!.isOpen && !session!.isExpired;

  bool get isMyProposal =>
      session != null && session!.proposedBy == currentUserId;

  bool get canRespond => isProposed && !isMyProposal;

  bool get canCounter => canRespond && (session?.proposalRound ?? 0) < 2;

  bool get canAccept => canRespond;

  /// The proposer may edit their own pending options while the other side is
  /// still deciding. Event meet-ups propose a venue zone, not landmarks.
  bool get canReplaceProposal =>
      isProposed &&
      isMyProposal &&
      !(session?.isExpired ?? true) &&
      session?.origin == MeetupOrigin.proximity;

  bool get hasPendingPlaceChange =>
      isActive && (session?.pendingLandmarkId != null);

  bool get isMyPlaceChange =>
      hasPendingPlaceChange && session!.pendingChangeBy == currentUserId;

  bool get canRequestPlaceChange =>
      isActive &&
      !(session?.isExpired ?? true) &&
      session?.origin == MeetupOrigin.proximity &&
      !hasPendingPlaceChange;

  MeetupLandmark? get pendingLandmark {
    final id = session?.pendingLandmarkId;
    if (id == null) return null;
    for (final landmark in landmarks) {
      if (landmark.id == id) return landmark;
    }
    return null;
  }

  List<MeetupLandmark> get roundLandmarks {
    final current = session;
    if (current == null) return const [];
    return landmarks
        .where((item) => item.round == current.proposalRound)
        .toList(growable: false);
  }

  MeetupLandmark? get chosenLandmark {
    final id = session?.chosenLandmarkId;
    if (id == null) return null;
    for (final landmark in landmarks) {
      if (landmark.id == id) return landmark;
    }
    return null;
  }

  List<MeetupSpotCard> get incomingSpotCards => spotCards
      .where(
        (card) =>
            card.senderId != currentUserId &&
            card.hiddenAt == null &&
            !card.isDeleted &&
            !card.isExpired,
      )
      .toList(growable: false);

  List<MeetupSpotCard> get mySpotCards => spotCards
      .where(
        (card) =>
            card.senderId == currentUserId &&
            !card.isDeleted &&
            !card.isExpired,
      )
      .toList(growable: false);

  MeetupSignal? get incomingWave =>
      _latestSignal(mine: false, type: MeetupSignalType.wave);

  MeetupSignal? get myWave =>
      _latestSignal(mine: true, type: MeetupSignalType.wave);

  MeetupSignal? get incomingBeacon =>
      _latestSignal(mine: false, type: MeetupSignalType.beacon);

  MeetupSignal? get myBeacon =>
      _latestSignal(mine: true, type: MeetupSignalType.beacon);

  /// The live signal the other side sent most recently, whatever its type.
  ///
  /// Anything that announces one thing per match has to use this rather than
  /// choosing by type. A beacon turned on after a wave is the newer signal, and
  /// a surface that still reports the wave disagrees with the alert bar, which
  /// already ranks the alerts by time. Nothing is hidden by this: every live
  /// tool keeps its own card in the hub feed, and a wave that wins a beacon
  /// only holds the banner until it expires, when the beacon reappears.
  MeetupSignal? get latestIncomingSignal =>
      _latestSignal(mine: false, type: null);

  MeetupSignal? _latestSignal({
    required bool mine,
    required MeetupSignalType? type,
  }) {
    MeetupSignal? latest;
    for (final signal in signals) {
      if (type != null && signal.type != type) continue;
      if (signal.isExpired) continue;
      if (hiddenSignalIds.contains(signal.id)) continue;
      final isMine = signal.senderId == currentUserId;
      if (isMine != mine) continue;
      if (latest == null || signal.createdAt.isAfter(latest.createdAt)) {
        latest = signal;
      }
    }
    return latest;
  }

  MeetupState copyWith({
    bool? loading,
    bool? busy,
    bool? offline,
    bool? suggesting,
    Object? errorKey = _unset,
    Object? currentUserId = _unset,
    Object? session = _unset,
    List<MeetupLandmark>? landmarks,
    List<MeetupSignal>? signals,
    List<MeetupSpotCard>? spotCards,
    List<MeetupPlaceSuggestion>? suggestions,
    List<MeetupPlaceSuggestion>? suggestionPool,
    String? suggestionSource,
    Set<String>? hiddenSignalIds,
  }) {
    return MeetupState(
      loading: loading ?? this.loading,
      busy: busy ?? this.busy,
      offline: offline ?? this.offline,
      suggesting: suggesting ?? this.suggesting,
      errorKey: identical(errorKey, _unset)
          ? this.errorKey
          : errorKey as String?,
      currentUserId: identical(currentUserId, _unset)
          ? this.currentUserId
          : currentUserId as String?,
      session: identical(session, _unset)
          ? this.session
          : session as MeetupSession?,
      landmarks: landmarks ?? this.landmarks,
      signals: signals ?? this.signals,
      spotCards: spotCards ?? this.spotCards,
      suggestions: suggestions ?? this.suggestions,
      suggestionPool: suggestionPool ?? this.suggestionPool,
      suggestionSource: suggestionSource ?? this.suggestionSource,
      hiddenSignalIds: hiddenSignalIds ?? this.hiddenSignalIds,
    );
  }

  /// Advances to the next page of already-fetched places. Returns this state
  /// unchanged when the pool is empty, so callers need no guard.
  MeetupState nextSuggestionPage() {
    if (suggestionPool.isEmpty) return this;
    return copyWith(
      suggestions: suggestionPool
          .take(LandmarkSuggestionService.pageSize)
          .toList(growable: false),
      suggestionPool: suggestionPool
          .skip(LandmarkSuggestionService.pageSize)
          .toList(growable: false),
    );
  }
}

class MeetupNotifier extends Notifier<MeetupState> {
  MeetupNotifier(this.matchId);

  final String matchId;
  final MeetupService _service = MeetupService();

  RealtimeChannel? _channel;
  Timer? _reloadDebounce;
  bool _disposed = false;
  bool _hydrated = false;
  String? _cleanedSessionId;
  DateTime? _lastMatchSpotPurge;

  static const List<String> _realtimeTables = [
    'meetup_sessions',
    'meetup_landmarks',
    'meetup_signals',
    'meetup_spot_cards',
  ];

  @override
  MeetupState build() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    ref.onDispose(() {
      _disposed = true;
      _reloadDebounce?.cancel();
      _reloadDebounce = null;
      _channel?.unsubscribe();
      _channel = null;
    });

    ref.listen<AsyncValue<ConnectivityHealth>>(connectivityHealthProvider, (
      previous,
      next,
    ) {
      if (_disposed) return;
      final online = next.asData?.value.isOnline ?? false;
      final wasOnline = previous?.asData?.value.isOnline ?? false;
      if (online && !wasOnline) {
        _startRealtime();
        unawaited(refresh());
      } else if (!online) {
        state = state.copyWith(offline: true, loading: false);
      }
    });

    // Stale-while-revalidate: paint the last persisted snapshot immediately
    // instead of a full-page spinner, and let the refresh below correct
    // anything stale. The spinner gate (loading && session == null) only
    // fires on a match's very first visit with nothing cached.
    final cached = MeetupSnapshotCache.instance.peek(userId ?? '', matchId);
    if (cached != null) {
      _hydrated = true;
      Future.microtask(() async {
        if (_disposed) return;
        _startRealtime();
        await refresh();
      });
      return MeetupState(
        loading: false,
        currentUserId: userId,
        session: cached.session,
        landmarks: cached.landmarks,
        signals: cached.signals,
        spotCards: cached.spotCards,
      );
    }

    Future.microtask(() async {
      if (_disposed) return;
      _startRealtime();
      final cachedFromDisk = await MeetupSnapshotCache.instance.load(
        userId ?? '',
        matchId,
      );
      if (_disposed) return;
      if (cachedFromDisk != null) {
        _hydrated = true;
        state = MeetupState(
          loading: false,
          currentUserId: userId,
          session: cachedFromDisk.session,
          landmarks: cachedFromDisk.landmarks,
          signals: cachedFromDisk.signals,
          spotCards: cachedFromDisk.spotCards,
        );
      }
      await refresh(showLoading: !_hydrated);
    });

    return MeetupState.initial(currentUserId: userId);
  }

  Future<void> refresh({bool showLoading = false}) async {
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) {
      state = state.copyWith(loading: false, offline: true);
      return;
    }
    if (showLoading) {
      state = state.copyWith(loading: true, errorKey: null);
    }
    try {
      final snapshot = await _service.loadSnapshot(matchId);
      if (_disposed) return;
      final visibleCards = snapshot.spotCards
          .where((card) {
            if (card.isDeleted || card.isExpired) return false;
            if (card.senderId == state.currentUserId) return true;
            return card.hiddenAt == null;
          })
          .toList(growable: false);
      state = state.copyWith(
        loading: false,
        offline: false,
        errorKey: null,
        session: snapshot.session,
        landmarks: snapshot.landmarks,
        signals: snapshot.signals,
        spotCards: visibleCards,
      );
      // Persist for the next entry so the screens hydrate from local
      // storage instead of spinning through a full network round-trip.
      unawaited(
        MeetupSnapshotCache.instance.save(
          userId: state.currentUserId ?? '',
          matchId: matchId,
          session: snapshot.session,
          landmarks: snapshot.landmarks,
          signals: snapshot.signals,
          spotCards: visibleCards,
        ),
      );
      final closed = snapshot.session;
      if (closed != null &&
          (closed.status == MeetupStatus.ended || closed.isExpired)) {
        _cleanupSpotObjects(closed.id);
      }
      _purgeInactiveMatchSpotObjects();
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        offline: shouldSkipSupabaseCalls(),
        errorKey: state.session == null ? 'meetupActionFailed' : null,
      );
    }
  }

  /// Both sides best-effort delete the session's spot photos once it closes.
  /// Ending from this device already does it; this covers the other user's
  /// device and sessions closed by the expiry job.
  void _cleanupSpotObjects(String sessionId) {
    if (_cleanedSessionId == sessionId) return;
    _cleanedSessionId = sessionId;
    unawaited(() async {
      try {
        final paths = await _service.spotPaths(sessionId);
        await _service.deleteSpotObjects(paths);
      } catch (_) {}
    }());
  }

  /// Match-scoped spot photos have no session to cascade with. When a card is
  /// replaced, deleted or expires, either device purges its object; the server
  /// returns only inactive paths, so a live card's photo is never touched.
  void _purgeInactiveMatchSpotObjects() {
    final now = DateTime.now();
    if (_lastMatchSpotPurge != null &&
        now.difference(_lastMatchSpotPurge!) < const Duration(minutes: 5)) {
      return;
    }
    _lastMatchSpotPurge = now;
    unawaited(() async {
      try {
        final paths = await _service.spotPathsForMatch(
          matchId,
          onlyInactive: true,
        );
        await _service.deleteSpotObjects(paths);
      } catch (_) {}
    }());
  }

  void _startRealtime() {
    if (_disposed || _channel != null || shouldSkipSupabaseCalls()) return;
    final channel = Supabase.instance.client.channel('meetup:$matchId');
    void onChange(PostgresChangePayload payload) => _scheduleReload();
    for (final table in _realtimeTables) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'match_id',
          value: matchId,
        ),
        callback: onChange,
      );
    }
    _channel = channel;
    channel.subscribe((status, error) {
      if (_disposed) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        _scheduleReload();
      }
    });
  }

  void _scheduleReload() {
    if (_disposed) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(refresh()),
    );
  }

  Future<String?> loadSuggestions() async {
    if (state.suggesting) return null;
    if (shouldSkipSupabaseCalls()) return 'meetupOffline';
    state = state.copyWith(suggesting: true, errorKey: null);
    try {
      final position = await _fetchOneShotPosition();
      if (position == null) {
        if (!_disposed) state = state.copyWith(suggesting: false);
        return 'meetupLocationUnavailable';
      }
      final anchor = LandmarkSuggestionService.coarsen(
        position.latitude,
        position.longitude,
      );
      final languageCode = _languageCode();
      final provider = await _placesProvider();

      // A re-entry within the same block restores the previous answer instead
      // of paying for another provider call. The comparison uses the same
      // coarsened anchor that was sent to the provider.
      final userId = state.currentUserId ?? '';
      final cached = MeetupSuggestionCache.instance.lookup(
        userId: userId,
        matchId: matchId,
        anchor: anchor,
        languageCode: languageCode,
        provider: provider,
      );
      if (cached != null) {
        if (_disposed) return null;
        state = state.copyWith(
          suggesting: false,
          suggestions: cached.suggestions,
          suggestionPool: cached.pool,
          suggestionSource: cached.source,
        );
        return null;
      }

      final endpoints = await _overpassEndpoints();
      final service = LandmarkSuggestionService(
        endpoints: endpoints,
        provider: provider,
        languageCode: languageCode,
      );
      final result = await service
          .suggest(latitude: anchor.latitude, longitude: anchor.longitude)
          .timeout(const Duration(seconds: 16));
      if (_disposed) return null;
      state = state.copyWith(
        suggesting: false,
        suggestions: result.places,
        suggestionPool: result.pool,
        suggestionSource: result.source,
      );
      if (result.places.isNotEmpty) {
        MeetupSuggestionCache.instance.store(
          userId: userId,
          matchId: matchId,
          anchor: anchor,
          languageCode: languageCode,
          provider: provider,
          suggestions: result.places,
          pool: result.pool,
          source: result.source,
        );
      }
      return result.places.isEmpty ? 'meetupNoPlacesFound' : null;
    } on LandmarkSuggestionException {
      if (!_disposed) state = state.copyWith(suggesting: false);
      return 'meetupLandmarkLookupFailed';
    } catch (_) {
      if (!_disposed) state = state.copyWith(suggesting: false);
      return 'meetupLandmarkLookupFailed';
    }
  }

  /// Pages through places already fetched by [loadSuggestions]. No provider
  /// call, so it costs neither latency nor the lookup quota.
  void showMoreSuggestions() {
    if (_disposed || state.suggestionPool.isEmpty) return;
    state = state.nextSuggestionPage();
    MeetupSuggestionCache.instance.updatePage(
      userId: state.currentUserId ?? '',
      matchId: matchId,
      suggestions: state.suggestions,
      pool: state.suggestionPool,
    );
  }

  /// Re-shows the last lookup for this match without a position fix or a
  /// provider call. Returns false when this device has no usable list, so the
  /// caller can fall back to [loadSuggestions].
  bool restoreCachedSuggestions() {
    if (_disposed) return false;
    final cached = MeetupSuggestionCache.instance.latest(
      userId: state.currentUserId ?? '',
      matchId: matchId,
      languageCode: _languageCode(),
    );
    if (cached == null) return false;
    state = state.copyWith(
      suggesting: false,
      suggestions: cached.suggestions,
      suggestionPool: cached.pool,
      suggestionSource: cached.source,
    );
    return true;
  }

  Future<List<String>> _overpassEndpoints() async {
    try {
      final raw = await appConfigService.getString('meetup.overpass_endpoints');
      final parsed = raw
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.startsWith('https://'))
          .toList(growable: false);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {
      // Fall through to the built-in endpoints.
    }
    return LandmarkSuggestionService.defaultEndpoints;
  }

  /// Which provider answers first. A missing or unreadable row keeps Google as
  /// the default; any other stored value forces the keyless OSM path, which is
  /// the remote switch for turning Google off without a client release.
  Future<String> _placesProvider() async {
    try {
      final value = await appConfigService.getString('meetup.places_provider');
      final trimmed = value.trim().toLowerCase();
      if (trimmed.isNotEmpty) return trimmed;
    } catch (_) {
      // Fall through to the default.
    }
    return LandmarkSuggestionService.googleProvider;
  }

  /// The member's language, so Google returns native place names instead of
  /// transliterations. English when the locale is not readable yet.
  String _languageCode() {
    try {
      return ref.read(localizationProvider).currentLocale.languageCode;
    } catch (_) {
      return 'en';
    }
  }

  Future<Position?> _fetchOneShotPosition() async {
    final locationService = ref.read(locationServiceProvider);
    final granted = await locationService.handleLocationPermission();
    if (!granted) return null;

    if (kIsWeb) {
      if (locationService is WebLocationService) {
        final position = await locationService.getCurrentPosition();
        if (position != null) return position;
      }
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return last;
      } catch (_) {}
      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
      } catch (_) {
        return null;
      }
    }

    try {
      final position = await LocationDeduplicator.getPosition(
        label: 'meetup_suggestion',
        fetcher: () => WindowsLocationChannel.getPosition(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        ),
      );
      if (position != null) return position;
    } catch (_) {}

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> startProximityMeetup(
    List<MeetupPlaceSuggestion> selected,
  ) async {
    if (selected.isEmpty) return 'meetupNoPlacesFound';
    final error = await _run(
      () => _service.proposeProximity(matchId: matchId, suggestions: selected),
    );
    if (error == null && !_disposed) {
      state = state.copyWith(suggestions: const [], suggestionPool: const []);
    }
    return error;
  }

  Future<String?> startEventMeetup(String zone) async {
    final trimmed = zone.trim();
    if (trimmed.isEmpty) return 'meetupActionFailed';
    final error = await _run(
      () => _service.proposeEventZone(matchId: matchId, zone: trimmed),
    );
    if (error == null && !_disposed) {
      state = state.copyWith(suggestions: const [], suggestionPool: const []);
    }
    return error;
  }

  Future<String?> startCustomMeetup(String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return 'meetupCustomPlaceInvalid';
    final error = await _run(
      () => _service.proposeCustomPlace(matchId: matchId, label: trimmed),
    );
    if (error == null && !_disposed) {
      state = state.copyWith(suggestions: const [], suggestionPool: const []);
    }
    return error;
  }

  Future<String?> counterProximityMeetup(
    List<MeetupPlaceSuggestion> selected,
  ) async {
    final session = state.session;
    if (session == null || selected.isEmpty) return 'meetupActionFailed';
    return _run(
      () => _service.counterProximity(
        sessionId: session.id,
        suggestions: selected,
      ),
    );
  }

  /// Edits the proposer's own pending options. Same round, no counter spent.
  Future<String?> replaceProposal(List<MeetupPlaceSuggestion> selected) async {
    final session = state.session;
    if (session == null || selected.isEmpty) return 'meetupNoPlacesFound';
    if (!state.canReplaceProposal) return 'meetupChangePlaceUnavailable';
    final error = await _run(
      () => _service.replaceProposal(
        sessionId: session.id,
        suggestions: selected,
      ),
    );
    if (error == null && !_disposed) {
      state = state.copyWith(suggestions: const [], suggestionPool: const []);
    }
    return error;
  }

  Future<String?> counterEventMeetup(String zone) async {
    final session = state.session;
    final trimmed = zone.trim();
    if (session == null || trimmed.isEmpty) return 'meetupActionFailed';
    return _run(
      () => _service.counterEventZone(sessionId: session.id, zone: trimmed),
    );
  }

  Future<String?> counterCustomPlace(String label) async {
    final session = state.session;
    final trimmed = label.trim();
    if (session == null) return 'meetupActionFailed';
    if (trimmed.isEmpty) return 'meetupCustomPlaceInvalid';
    return _run(
      () => _service.counterCustomPlace(sessionId: session.id, label: trimmed),
    );
  }

  Future<String?> acceptMeetup([String? landmarkId]) async {
    final session = state.session;
    if (session == null) return 'meetupActionFailed';
    return _run(
      () => _service.accept(sessionId: session.id, landmarkId: landmarkId),
    );
  }

  Future<String?> requestPlaceChange(MeetupPlaceSuggestion place) async {
    final session = state.session;
    if (session == null || !state.canRequestPlaceChange) {
      return 'meetupChangePlaceUnavailable';
    }
    return _run(
      () => _service.requestPlaceChange(sessionId: session.id, place: place),
    );
  }

  Future<String?> resolvePlaceChange({required bool accept}) async {
    final session = state.session;
    if (session == null ||
        !state.hasPendingPlaceChange ||
        state.isMyPlaceChange) {
      return 'meetupChangePlaceNoPending';
    }
    return _run(
      () => _service.resolvePlaceChange(sessionId: session.id, accept: accept),
    );
  }

  Future<String?> withdrawPlaceChange() async {
    final session = state.session;
    if (session == null || !state.isMyPlaceChange) {
      return 'meetupChangePlaceNoPending';
    }
    return _run(() => _service.withdrawPlaceChange(sessionId: session.id));
  }

  void dismissSignal(String signalId) {
    if (signalId.isEmpty || state.hiddenSignalIds.contains(signalId)) return;
    state = state.copyWith(
      hiddenSignalIds: {...state.hiddenSignalIds, signalId},
    );
  }

  Future<String?> clearSignal(MeetupSignalType type) async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      await _service.clearSignal(matchId: matchId, type: type);
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          signals: state.signals
              .where(
                (item) =>
                    !(item.senderId == state.currentUserId &&
                        item.type == type),
              )
              .toList(growable: false),
        );
      }
      return null;
    } on MeetupActionException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false);
      return error.code;
    } catch (_) {
      if (!_disposed) state = state.copyWith(busy: false);
      return 'meetupActionFailed';
    }
  }

  Future<String?> sendGesture([String gesture = kMeetupGestureWave]) async {
    if (state.busy) return null;
    final token = kMeetupGestureTokens.contains(gesture)
        ? gesture
        : kMeetupGestureWave;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      final signal = await _service.sendSignal(
        matchId: matchId,
        type: MeetupSignalType.wave,
        payload: {'gesture': token},
      );
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          signals: replaceOwnMeetupSignal(
            signals: state.signals,
            userId: state.currentUserId,
            type: MeetupSignalType.wave,
            signal: signal,
          ),
        );
      }
      return null;
    } on MeetupActionException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false);
      return error.code;
    } catch (_) {
      if (!_disposed) state = state.copyWith(busy: false);
      return 'meetupActionFailed';
    }
  }

  Future<String?> showBeacon() async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      final signal = await _service.sendSignal(
        matchId: matchId,
        type: MeetupSignalType.beacon,
      );
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          signals: replaceOwnMeetupSignal(
            signals: state.signals,
            userId: state.currentUserId,
            type: MeetupSignalType.beacon,
            signal: signal,
          ),
        );
      }
      return null;
    } on MeetupActionException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false);
      return error.code;
    } catch (_) {
      if (!_disposed) state = state.copyWith(busy: false);
      return 'meetupActionFailed';
    }
  }

  Future<String?> hideBeacon() async {
    return clearSignal(MeetupSignalType.beacon);
  }

  Future<String?> shareSpot({
    required String kind,
    Uint8List? photoBytes,
    Map<String, String> outfit = const {},
    String? note,
  }) async {
    final userId = state.currentUserId;
    if (userId == null) return 'meetupActionFailed';
    if (state.busy) return null;

    state = state.copyWith(busy: true, errorKey: null);
    var storagePath = '';
    try {
      if (photoBytes != null && photoBytes.isNotEmpty) {
        storagePath = await _service.uploadSpotPhoto(
          matchId: matchId,
          userId: userId,
          originalBytes: photoBytes,
        );
      }
      await _service.shareSpot(
        matchId: matchId,
        kind: kind,
        storagePath: storagePath,
        outfit: outfit,
        note: note,
      );
      await refresh();
      return null;
    } on MeetupActionException catch (error) {
      if (storagePath.isNotEmpty) {
        await _service.deleteSpotObjects([storagePath]);
      }
      return error.code;
    } catch (_) {
      if (storagePath.isNotEmpty) {
        await _service.deleteSpotObjects([storagePath]);
      }
      return 'meetupActionFailed';
    } finally {
      if (!_disposed) state = state.copyWith(busy: false);
    }
  }

  Future<String?> hideSpot(String cardId) async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      await _service.hideSpot(cardId);
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          spotCards: state.spotCards
              .where((card) => card.id != cardId)
              .toList(growable: false),
        );
      }
      return null;
    } on MeetupActionException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false);
      return error.code;
    } catch (_) {
      if (!_disposed) state = state.copyWith(busy: false);
      return 'meetupActionFailed';
    }
  }

  Future<String?> deleteSpot(String cardId) async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      final path = await _service.deleteSpot(cardId);
      await _service.deleteSpotObjects([path]);
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          spotCards: state.spotCards
              .where((card) => card.id != cardId)
              .toList(growable: false),
        );
      }
      return null;
    } on MeetupActionException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false);
      return error.code;
    } catch (_) {
      if (!_disposed) state = state.copyWith(busy: false);
      return 'meetupActionFailed';
    }
  }

  Future<String> signedSpotUrl(String path) async {
    final url = await _service.signedSpotUrl(path);
    return url ?? '';
  }

  Future<String?> endMeetup({bool found = true}) async {
    final session = state.session;
    if (session == null || !session.isOpen) return null;
    if (state.busy) return null;

    List<String> paths = const [];
    try {
      paths = await _service.spotPaths(session.id);
    } catch (_) {}

    final error = await _run(
      () => _service.end(
        sessionId: session.id,
        reason: found ? 'found' : 'cancelled',
      ),
    );
    if (error == null) {
      await _service.deleteSpotObjects(paths);
    }
    return error;
  }

  Future<String?> _run(Future<MeetupSession> Function() action) async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, errorKey: null);
    try {
      await action();
      await refresh();
      return null;
    } on MeetupActionException catch (error) {
      unawaited(refresh());
      return error.code;
    } catch (_) {
      return 'meetupActionFailed';
    } finally {
      if (!_disposed) state = state.copyWith(busy: false);
    }
  }
}

final meetupProvider = NotifierProvider.autoDispose
    .family<MeetupNotifier, MeetupState, String>(MeetupNotifier.new);
