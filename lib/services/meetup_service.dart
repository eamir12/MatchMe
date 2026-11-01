// Data access for the in-person meet-up flow.
//
// The client never writes meet-up tables directly: every mutation goes
// through a SECURITY DEFINER RPC that enforces participation, session state,
// rate limits and expiry. This file only reads snapshots and calls those RPCs.
//
// Privacy posture:
//   * No user coordinates are written anywhere.
//   * Spot me photos live in a private bucket and are re-encoded before
//     upload, which also strips EXIF metadata (including GPS tags).
//   * Everything else is scoped to a match by RLS.

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:matchme/models/meetup_activity.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class MeetupActionException implements Exception {
  /// Localization key describing the failure, not a raw server message.
  final String code;

  const MeetupActionException(this.code);

  @override
  String toString() => 'MeetupActionException($code)';
}

class MeetupSnapshot {
  final MeetupSession? session;
  final List<MeetupLandmark> landmarks;
  final List<MeetupSignal> signals;
  final List<MeetupSpotCard> spotCards;

  const MeetupSnapshot({
    required this.session,
    required this.landmarks,
    required this.signals,
    required this.spotCards,
  });
}

class MeetupService {
  MeetupService({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  static const String spotBucket = 'meetup-spot';
  static const int _spotPhotoMaxDimension = 1280;
  static const int _spotPhotoQuality = 78;

  final SupabaseClient _client;
  static const Uuid _uuid = Uuid();

  SupabaseClient get _supabase => _client;

  /// The most recent meet-up for a match plus its live child rows.
  ///
  /// Ended sessions are returned so both sides can see who ended it and when;
  /// the UI decides whether an old session is still worth showing.
  ///
  /// Signals and Spot me cards are keyed to the match, not the session: they
  /// work with no location invite at all, so they are loaded even when the
  /// match never had a session (or its last one ended).
  Future<MeetupSnapshot> loadSnapshot(String matchId) async {
    final sessionRow = await _supabase
        .from('meetup_sessions')
        .select('*')
        .eq('match_id', matchId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    final session = sessionRow == null
        ? null
        : MeetupSession.fromJson(Map<String, dynamic>.from(sessionRow));
    final now = DateTime.now().toUtc().toIso8601String();

    final landmarkRows = session == null
        ? const <Map<String, dynamic>>[]
        : await _supabase
              .from('meetup_landmarks')
              .select('*')
              .eq('session_id', session.id)
              .order('created_at', ascending: true);

    final signalRows = await _supabase
        .from('meetup_signals')
        .select('*')
        .eq('match_id', matchId)
        .gt('expires_at', now)
        .order('created_at', ascending: true);

    final cardRows = await _supabase
        .from('meetup_spot_cards')
        .select('*')
        .eq('match_id', matchId)
        .isFilter('deleted_at', null)
        .gt('expires_at', now)
        .order('created_at', ascending: true);

    return MeetupSnapshot(
      session: session,
      landmarks: landmarkRows
          .map((row) => MeetupLandmark.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      signals: signalRows
          .map((row) => MeetupSignal.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      spotCards: cardRows
          .map((row) => MeetupSpotCard.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false),
    );
  }

  /// Live/pending meet-up activity for every match of the signed-in user.
  /// One aggregate call for the whole list; no per-card queries.
  Future<Map<String, MeetupActivity>> loadActivityByMatch() async {
    final result = await _supabase.rpc('meetup_activity_by_match');
    if (result is! List) return const {};
    final activity = <String, MeetupActivity>{};
    for (final row in result) {
      if (row is! Map) continue;
      final json = Map<String, dynamic>.from(row);
      final matchId = json['match_id']?.toString() ?? '';
      if (matchId.isEmpty) continue;
      activity[matchId] = MeetupActivity.fromJson(json);
    }
    return activity;
  }

  Future<MeetupSession> proposeProximity({
    required String matchId,
    required List<MeetupPlaceSuggestion> suggestions,
  }) async {
    final result = await _rpc('meetup_propose', {
      'p_match_id': matchId,
      'p_origin': 'proximity',
      'p_venue_zone': null,
      'p_landmarks': suggestions.map((item) => item.toJson()).toList(),
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> proposeEventZone({
    required String matchId,
    required String zone,
  }) async {
    final result = await _rpc('meetup_propose', {
      'p_match_id': matchId,
      'p_origin': 'event',
      'p_venue_zone': zone,
      'p_landmarks': null,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> proposeCustomPlace({
    required String matchId,
    required String label,
  }) async {
    return proposeProximity(
      matchId: matchId,
      suggestions: [MeetupPlaceSuggestion.custom(label: label)],
    );
  }

  Future<MeetupSession> counterProximity({
    required String sessionId,
    required List<MeetupPlaceSuggestion> suggestions,
  }) async {
    final result = await _rpc('meetup_counter', {
      'p_session_id': sessionId,
      'p_venue_zone': null,
      'p_landmarks': suggestions.map((item) => item.toJson()).toList(),
    });
    return MeetupSession.fromJson(result);
  }

  /// Replaces the proposer's own pending options. No consent round: nothing
  /// has been accepted yet, and the other side sees the new list live.
  Future<MeetupSession> replaceProposal({
    required String sessionId,
    required List<MeetupPlaceSuggestion> suggestions,
  }) async {
    final result = await _rpc('meetup_replace_proposal', {
      'p_session_id': sessionId,
      'p_landmarks': suggestions.map((item) => item.toJson()).toList(),
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> counterEventZone({
    required String sessionId,
    required String zone,
  }) async {
    final result = await _rpc('meetup_counter', {
      'p_session_id': sessionId,
      'p_venue_zone': zone,
      'p_landmarks': null,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> counterCustomPlace({
    required String sessionId,
    required String label,
  }) async {
    return counterProximity(
      sessionId: sessionId,
      suggestions: [MeetupPlaceSuggestion.custom(label: label)],
    );
  }

  Future<MeetupSession> accept({
    required String sessionId,
    String? landmarkId,
  }) async {
    final result = await _rpc('meetup_accept', {
      'p_session_id': sessionId,
      'p_landmark_id': landmarkId,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> end({
    required String sessionId,
    String reason = 'found',
  }) async {
    final result = await _rpc('meetup_end', {
      'p_session_id': sessionId,
      'p_reason': reason,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> requestPlaceChange({
    required String sessionId,
    required MeetupPlaceSuggestion place,
  }) async {
    final result = await _rpc('meetup_request_place_change', {
      'p_session_id': sessionId,
      'p_landmarks': [place.toJson()],
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> resolvePlaceChange({
    required String sessionId,
    required bool accept,
  }) async {
    final result = await _rpc('meetup_resolve_place_change', {
      'p_session_id': sessionId,
      'p_accept': accept,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSession> withdrawPlaceChange({required String sessionId}) async {
    final result = await _rpc('meetup_withdraw_place_change', {
      'p_session_id': sessionId,
    });
    return MeetupSession.fromJson(result);
  }

  Future<MeetupSignal> sendSignal({
    required String matchId,
    required MeetupSignalType type,
    Map<String, dynamic> payload = const {},
  }) async {
    final result = await _rpc('meetup_signal_for_match', {
      'p_match_id': matchId,
      'p_type': type.name,
      'p_payload': payload,
    });
    return MeetupSignal.fromJson(result);
  }

  Future<void> clearSignal({
    required String matchId,
    required MeetupSignalType type,
  }) async {
    await _rpc('meetup_clear_signal_for_match', {
      'p_match_id': matchId,
      'p_type': type.name,
    });
  }

  Future<MeetupSpotCard> shareSpot({
    required String matchId,
    required String kind,
    required String storagePath,
    Map<String, dynamic> outfit = const {},
    String? note,
  }) async {
    final result = await _rpc('meetup_spot_share_for_match', {
      'p_match_id': matchId,
      'p_storage_path': storagePath,
      'p_kind': kind,
      'p_outfit': outfit,
      'p_note': note,
    });
    return MeetupSpotCard.fromJson(result);
  }

  Future<void> hideSpot(String cardId) async {
    await _rpc('meetup_hide_spot', {'p_card_id': cardId});
  }

  /// Deletes the row and returns the storage object path to remove.
  Future<String> deleteSpot(String cardId) async {
    final result = await _rpc('meetup_delete_spot', {'p_card_id': cardId});
    return result['value']?.toString() ?? '';
  }

  Future<List<String>> spotPaths(String sessionId) async {
    final result = await _supabase.rpc(
      'meetup_spot_paths',
      params: {'p_session_id': sessionId},
    );
    if (result is List) {
      return result
          .map((item) => item?.toString() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  /// Photo paths for match-scoped cards. With [onlyInactive] the server only
  /// returns rows that are already deleted or expired, so a live card's photo
  /// can never be removed by cleanup on either device.
  Future<List<String>> spotPathsForMatch(
    String matchId, {
    bool onlyInactive = false,
  }) async {
    final result = await _supabase.rpc(
      'meetup_spot_paths_for_match',
      params: {'p_match_id': matchId, 'p_only_inactive': onlyInactive},
    );
    if (result is List) {
      return result
          .map((item) => item?.toString() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Future<String> uploadSpotPhoto({
    required String matchId,
    required String userId,
    required Uint8List originalBytes,
  }) async {
    final bytes = prepareSpotPhoto(originalBytes);
    final path = 'm_$matchId/$userId/${_uuid.v4()}.jpg';
    try {
      await _supabase.storage
          .from(spotBucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              cacheControl: 'no-store',
              upsert: false,
            ),
          )
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      throw const MeetupActionException('meetupActionFailed');
    }
    return path;
  }

  Future<void> deleteSpotObjects(Iterable<String> paths) async {
    final targets = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (targets.isEmpty) return;
    try {
      await _supabase.storage.from(spotBucket).remove(targets);
    } catch (_) {
      // Best effort: the bucket is private and every path is short-lived.
    }
  }

  Future<String?> signedSpotUrl(String path) {
    if (path.trim().isEmpty) return Future.value(null);
    return StorageHelper.getSignedUrlFromBucket(
      path,
      spotBucket,
      ttlSeconds: 600,
    );
  }

  /// Downscale, re-encode and drop metadata. Re-encoding through the `image`
  /// package is what removes EXIF/GPS tags from the original camera file.
  static Uint8List prepareSpotPhoto(
    Uint8List bytes, {
    int maxDimension = _spotPhotoMaxDimension,
    int quality = _spotPhotoQuality,
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const MeetupActionException('meetupActionFailed');
    }
    var image = img.bakeOrientation(decoded);
    if (image.width > maxDimension || image.height > maxDimension) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxDimension)
          : img.copyResize(image, height: maxDimension);
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  Future<Map<String, dynamic>> _rpc(
    String function,
    Map<String, dynamic> params,
  ) async {
    try {
      final result = await _supabase
          .rpc(function, params: params)
          .timeout(const Duration(seconds: 25));
      if (result is Map) {
        if (result.containsKey('value')) {
          return {'value': result['value']};
        }
        return Map<String, dynamic>.from(result);
      }
      return {'value': result};
    } on MeetupActionException {
      rethrow;
    } on PostgrestException catch (error) {
      throw MeetupActionException(_keyForServerError(error.message));
    } on AuthException {
      throw const MeetupActionException('meetupActionFailed');
    } catch (_) {
      throw const MeetupActionException('meetupOffline');
    }
  }
}

String _keyForServerError(String message) {
  const mappings = <String, String>{
    'meetup_wave_rate_limited': 'meetupWaveRateLimited',
    'meetup_beacon_rate_limited': 'meetupBeaconRateLimited',
    'meetup_spot_limit': 'meetupSpotMeLimit',
    'meetup_spot_rate_limited': 'meetupSpotMeRateLimited',
    'meetup_spot_content_required': 'meetupSpotMeContentRequired',
    'meetup_counter_limit': 'meetupCounterLimit',
    'meetup_waiting_for_other': 'meetupWaitingForOther',
    'meetup_already_active': 'meetupAlreadyActive',
    'meetup_not_proposed': 'meetupInviteExpired',
    'meetup_not_active': 'meetupInviteExpired',
    'meetup_not_found': 'meetupInviteExpired',
    'meetup_place_change_pending': 'meetupChangePlacePendingError',
    'meetup_place_change_unavailable': 'meetupChangePlaceUnavailable',
    'meetup_no_place_change': 'meetupChangePlaceNoPending',
    'meetup_not_requester': 'meetupChangePlaceUnavailable',
    'meetup_not_proposer': 'meetupChangePlaceUnavailable',
    // The plural form is listed first so the singular check below never
    // swallows an invalid-landmarks failure from the insert helper.
    'meetup_invalid_landmarks': 'meetupActionFailed',
    'meetup_invalid_landmark': 'meetupProposalChanged',
  };
  for (final entry in mappings.entries) {
    if (message.contains(entry.key)) return entry.value;
  }
  return 'meetupActionFailed';
}
