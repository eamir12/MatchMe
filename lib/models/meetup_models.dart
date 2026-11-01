// Models for the in-person meet-up flow.
//
// A meet-up is scoped to a match. It stores public meeting points (or a
// venue zone for event matches), short-lived signals, and ephemeral Spot me
// cards. It never stores a user's coordinates.

enum MeetupStatus { proposed, active, ended }

enum MeetupOrigin { proximity, event }

enum MeetupSignalType { wave, beacon }

/// Gesture tokens carried in `meetup_signals.payload.gesture` for wave-type
/// signals. The server whitelists exactly these values.
const String kMeetupGestureWave = 'wave';
const String kMeetupGestureHandsUp = 'hands_up';
const String kMeetupGestureJumping = 'jumping';
const String kMeetupGestureArmsWide = 'arms_wide';

const List<String> kMeetupGestureTokens = <String>[
  kMeetupGestureWave,
  kMeetupGestureHandsUp,
  kMeetupGestureJumping,
  kMeetupGestureArmsWide,
];

String meetupSignalGesture(MeetupSignal signal) {
  final raw = signal.payload['gesture']?.toString().trim() ?? '';
  return kMeetupGestureTokens.contains(raw) ? raw : kMeetupGestureWave;
}

/// The rows that survive sending one of your own tools: the row it replaces is
/// dropped and the new one is last. The server deletes the sender's live rows of
/// that type before it inserts, so this mirrors what the other device sees.
List<MeetupSignal> replaceOwnMeetupSignal({
  required List<MeetupSignal> signals,
  required String? userId,
  required MeetupSignalType type,
  required MeetupSignal signal,
}) {
  return [
    ...signals.where((item) => !(item.senderId == userId && item.type == type)),
    signal,
  ];
}

/// Stable outfit color tokens. Only the token is stored; each client renders
/// it in its own language. Unknown legacy values are shown verbatim.
const String kMeetupColorNone = 'none';

const List<String> kMeetupColorTokens = <String>[
  'black',
  'white',
  'gray',
  'beige',
  'brown',
  'navy',
  'blue',
  'light_blue',
  'green',
  'olive',
  'red',
  'burgundy',
  'pink',
  'yellow',
  'orange',
  'purple',
  'gold',
  'silver',
  'multicolor',
];

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final name = raw?.toString();
  if (name == null || name.isEmpty) return fallback;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

class MeetupSession {
  final String id;
  final String matchId;
  final String createdBy;
  final MeetupStatus status;
  final MeetupOrigin origin;
  final String proposedBy;
  final int proposalRound;
  final String? venueZone;
  final String? chosenLandmarkId;
  final String? pendingLandmarkId;
  final String? pendingChangeBy;
  final DateTime? pendingChangeAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? activeAt;
  final DateTime expiresAt;
  final DateTime? endedAt;
  final String? endedBy;
  final String? endReason;

  const MeetupSession({
    required this.id,
    required this.matchId,
    required this.createdBy,
    required this.status,
    required this.origin,
    required this.proposedBy,
    required this.proposalRound,
    required this.createdAt,
    required this.updatedAt,
    required this.expiresAt,
    this.venueZone,
    this.chosenLandmarkId,
    this.pendingLandmarkId,
    this.pendingChangeBy,
    this.pendingChangeAt,
    this.activeAt,
    this.endedAt,
    this.endedBy,
    this.endReason,
  });

  bool get isOpen =>
      status == MeetupStatus.proposed || status == MeetupStatus.active;

  bool get isActive => status == MeetupStatus.active;

  bool get isEvent => origin == MeetupOrigin.event;

  bool get hasPendingPlaceChange => pendingLandmarkId != null;

  bool get isExpired =>
      isOpen && DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  Duration get timeRemaining {
    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  factory MeetupSession.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(Object? value) =>
        DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    DateTime? parseNullableDate(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString())?.toUtc();

    return MeetupSession(
      id: json['id'].toString(),
      matchId: json['match_id'].toString(),
      createdBy: json['created_by'].toString(),
      status: _enumByName(
        MeetupStatus.values,
        json['status'],
        MeetupStatus.proposed,
      ),
      origin: _enumByName(
        MeetupOrigin.values,
        json['origin'],
        MeetupOrigin.proximity,
      ),
      proposedBy: json['proposed_by'].toString(),
      proposalRound: (json['proposal_round'] as num?)?.toInt() ?? 1,
      venueZone: json['venue_zone']?.toString(),
      chosenLandmarkId: json['chosen_landmark_id']?.toString(),
      pendingLandmarkId: json['pending_landmark_id']?.toString(),
      pendingChangeBy: json['pending_change_by']?.toString(),
      pendingChangeAt: parseNullableDate(json['pending_change_at']),
      createdAt: parseDate(json['created_at']),
      updatedAt: parseDate(json['updated_at']),
      activeAt: parseNullableDate(json['active_at']),
      expiresAt: parseDate(json['expires_at']),
      endedAt: parseNullableDate(json['ended_at']),
      endedBy: json['ended_by']?.toString(),
      endReason: json['end_reason']?.toString(),
    );
  }

  /// Round-trips with [fromJson] (same snake_case keys). Used by the local
  /// snapshot cache, not by the database.
  Map<String, dynamic> toJson() => {
    'id': id,
    'match_id': matchId,
    'created_by': createdBy,
    'status': status.name,
    'origin': origin.name,
    'proposed_by': proposedBy,
    'proposal_round': proposalRound,
    'venue_zone': venueZone,
    'chosen_landmark_id': chosenLandmarkId,
    'pending_landmark_id': pendingLandmarkId,
    'pending_change_by': pendingChangeBy,
    'pending_change_at': pendingChangeAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'active_at': activeAt?.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'ended_by': endedBy,
    'end_reason': endReason,
  };
}

class MeetupLandmark {
  final String id;
  final String sessionId;
  final String proposerId;
  final int round;
  final String label;
  final String category;
  final double? latitude;
  final double? longitude;
  final int? distanceMeters;
  final String? placeId;
  final DateTime createdAt;

  const MeetupLandmark({
    required this.id,
    required this.sessionId,
    required this.proposerId,
    required this.round,
    required this.label,
    required this.category,
    required this.createdAt,
    this.latitude,
    this.longitude,
    this.distanceMeters,
    this.placeId,
  });

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get hasPlaceId => placeId != null && placeId!.isNotEmpty;

  factory MeetupLandmark.fromJson(Map<String, dynamic> json) {
    double? parseDouble(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

    final placeId = json['place_id']?.toString().trim();

    return MeetupLandmark(
      id: json['id'].toString(),
      sessionId: json['session_id'].toString(),
      proposerId: json['proposer_id'].toString(),
      round: (json['round'] as num?)?.toInt() ?? 1,
      label: json['label']?.toString() ?? '',
      category: json['category']?.toString() ?? 'landmark',
      latitude: parseDouble(json['latitude']),
      longitude: parseDouble(json['longitude']),
      distanceMeters: (json['distance_m'] as num?)?.toInt(),
      placeId: (placeId == null || placeId.isEmpty) ? null : placeId,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'proposer_id': proposerId,
    'round': round,
    'label': label,
    'category': category,
    'latitude': latitude,
    'longitude': longitude,
    'distance_m': distanceMeters,
    'place_id': placeId,
    'created_at': createdAt.toIso8601String(),
  };
}

class MeetupSignal {
  final String id;

  /// Null for match-scoped signals, which exist without a meet-up session.
  final String? sessionId;
  final String senderId;
  final MeetupSignalType type;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final DateTime expiresAt;

  const MeetupSignal({
    required this.id,
    required this.sessionId,
    required this.senderId,
    required this.type,
    required this.payload,
    required this.createdAt,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  Duration get timeRemaining {
    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  factory MeetupSignal.fromJson(Map<String, dynamic> json) {
    return MeetupSignal(
      id: json['id'].toString(),
      sessionId: json['session_id']?.toString(),
      senderId: json['sender_id'].toString(),
      type: _enumByName(
        MeetupSignalType.values,
        json['type'],
        MeetupSignalType.wave,
      ),
      payload: json['payload'] is Map
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : const <String, dynamic>{},
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt:
          DateTime.tryParse(json['expires_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'sender_id': senderId,
    'type': type.name,
    'payload': payload,
    'created_at': createdAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
  };
}

class MeetupSpotCard {
  final String id;

  /// Null for match-scoped cards, which exist without a meet-up session.
  final String? sessionId;
  final String senderId;
  final String kind;
  final String storagePath;
  final Map<String, dynamic> outfit;
  final String? note;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? hiddenAt;
  final DateTime? deletedAt;

  const MeetupSpotCard({
    required this.id,
    required this.sessionId,
    required this.senderId,
    required this.kind,
    required this.storagePath,
    required this.outfit,
    required this.createdAt,
    required this.expiresAt,
    this.note,
    this.hiddenAt,
    this.deletedAt,
  });

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  bool get isDeleted => deletedAt != null;

  factory MeetupSpotCard.fromJson(Map<String, dynamic> json) {
    DateTime? parseNullableDate(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString())?.toUtc();

    return MeetupSpotCard(
      id: json['id'].toString(),
      sessionId: json['session_id']?.toString(),
      senderId: json['sender_id'].toString(),
      kind: json['kind']?.toString() ?? 'self',
      storagePath: json['storage_path']?.toString() ?? '',
      outfit: json['outfit'] is Map
          ? Map<String, dynamic>.from(json['outfit'] as Map)
          : const <String, dynamic>{},
      note: json['note']?.toString(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt:
          DateTime.tryParse(json['expires_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      hiddenAt: parseNullableDate(json['hidden_at']),
      deletedAt: parseNullableDate(json['deleted_at']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'sender_id': senderId,
    'kind': kind,
    'storage_path': storagePath,
    'outfit': outfit,
    'note': note,
    'created_at': createdAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    'hidden_at': hiddenAt?.toIso8601String(),
    'deleted_at': deletedAt?.toIso8601String(),
  };
}

/// A candidate public meeting point produced on-device from a one-shot
/// location lookup, or a name-only custom place. This object is never
/// persisted locally.
class MeetupPlaceSuggestion {
  final String label;
  final String category;
  final double? latitude;
  final double? longitude;
  final int? distanceMeters;

  /// Google Places id, when the suggestion came from the Google provider.
  /// Used for a maps link that opens the named place card instead of a pin.
  final String? placeId;

  const MeetupPlaceSuggestion({
    required this.label,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    this.placeId,
  });

  /// Name-only place. Sends no coordinates, so the server stores none.
  const MeetupPlaceSuggestion.custom({required this.label})
    : category = 'custom',
      latitude = null,
      longitude = null,
      distanceMeters = null,
      placeId = null;

  bool get isCustom => category == 'custom';

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get hasPlaceId => placeId != null && placeId!.isNotEmpty;

  int? get walkingMinutes {
    final meters = distanceMeters;
    if (meters == null) return null;
    return meters <= 0 ? 1 : (meters / 80).ceil().clamp(1, 999);
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'category': category,
    if (latitude != null) 'lat': latitude,
    if (longitude != null) 'lng': longitude,
    if (distanceMeters != null) 'distance_m': distanceMeters,
    if (placeId != null && placeId!.isNotEmpty) 'place_id': placeId,
  };
}

class MeetupZoneOption {
  final String labelKey;
  final bool isCustom;

  const MeetupZoneOption(this.labelKey, {this.isCustom = false});
}

const List<MeetupZoneOption> kMeetupVenueZones = [
  MeetupZoneOption('meetupEventZoneMainEntrance'),
  MeetupZoneOption('meetupEventZoneBoxOffice'),
  MeetupZoneOption('meetupEventZoneBar'),
  MeetupZoneOption('meetupEventZoneCloakroom'),
  MeetupZoneOption('meetupEventZoneSeating'),
  MeetupZoneOption('meetupEventZoneCustom', isCustom: true),
];
