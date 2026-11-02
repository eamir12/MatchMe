// lib/models/match_model.dart
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/match_map_view.dart';

final supabase = Supabase.instance.client;

class MatchLocation {
  final int occurrence;
  final double? user1Lat;
  final double? user1Lng;
  final double? user2Lat;
  final double? user2Lng;
  // Coarse viewport for privacy option 3: truncated center + capped zoom
  final double? mapCenterLat;
  final double? mapCenterLng;
  final double? mapZoom;
  final String? matchedIntent;
  final DateTime? createdAt;
  final DateTime? expiredAt;
  final String? matchId;

  const MatchLocation({
    required this.occurrence,
    this.user1Lat,
    this.user1Lng,
    this.user2Lat,
    this.user2Lng,
    this.mapCenterLat,
    this.mapCenterLng,
    this.mapZoom,
    this.matchedIntent,
    this.createdAt,
    this.expiredAt,
    this.matchId,
  });

  bool get hasValidCoords =>
      user1Lat != null &&
      user1Lng != null &&
      user2Lat != null &&
      user2Lng != null;

  bool get hasCoarseCenter => mapCenterLat != null && mapCenterLng != null;

  bool get hasDisplayableLocation => hasValidCoords || hasCoarseCenter;

  /// Privacy-coarse viewport the minimap and full-screen map should render.
  ///
  /// Prefers the stored 2-decimal center; for legacy rows that only carry
  /// exact coordinates it derives the same coarse point client-side, so a
  /// precise pin is never drawn. The zoom guarantees the frame contains the
  /// real match area (rounding cell + each user's side of the pair).
  /// Returns null when there is nothing displayable (old matches).
  MatchMapView? displayView({
    double viewportHeightPx = kMatchMapNominalViewportHeightPx,
  }) {
    double? cLat = mapCenterLat;
    double? cLng = mapCenterLng;
    if (cLat == null || cLng == null) {
      if (!hasValidCoords) return null;
      cLat = roundCoarseCoordinate((user1Lat! + user2Lat!) / 2);
      cLng = roundCoarseCoordinate((user1Lng! + user2Lng!) / 2);
    }
    final pairDistanceMeters = hasValidCoords
        ? haversineMeters(user1Lat!, user1Lng!, user2Lat!, user2Lng!)
        : null;
    return buildMatchMapView(
      centerLat: cLat,
      centerLng: cLng,
      pairHalfMeters: matchMapPairHalfMeters(
        storedZoom: mapZoom,
        pairDistanceMeters: pairDistanceMeters,
      ),
      viewportHeightPx: viewportHeightPx,
    );
  }

  factory MatchLocation.fromJson(Map<String, dynamic> json) {
    double? parseCoord(dynamic v) => v == null
        ? null
        : (v is num ? v.toDouble() : double.tryParse(v.toString()));
    return MatchLocation(
      occurrence: (json['occurrence'] is int)
          ? json['occurrence'] as int
          : int.tryParse(json['occurrence']?.toString() ?? '1') ?? 1,
      user1Lat: parseCoord(json['user1_lat'] ?? json['user1Lat']),
      user1Lng: parseCoord(json['user1_lng'] ?? json['user1Lng']),
      user2Lat: parseCoord(json['user2_lat'] ?? json['user2Lat']),
      user2Lng: parseCoord(json['user2_lng'] ?? json['user2Lng']),
      mapCenterLat: parseCoord(
        json['map_center_lat'] ?? json['mapCenterLat'] ?? json['center_lat'],
      ),
      mapCenterLng: parseCoord(
        json['map_center_lng'] ?? json['mapCenterLng'] ?? json['center_lng'],
      ),
      mapZoom: parseCoord(json['map_zoom'] ?? json['mapZoom'] ?? json['zoom']),
      matchedIntent:
          json['matched_intent']?.toString() ??
          json['matchedIntent']?.toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : (json['createdAt'] != null
                ? DateTime.tryParse(json['createdAt'].toString())
                : null),
      expiredAt: json['expired_at'] != null
          ? DateTime.tryParse(json['expired_at'].toString())
          : null,
      matchId: json['match_id']?.toString() ?? json['matchId']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'occurrence': occurrence,
    if (user1Lat != null) 'user1_lat': user1Lat,
    if (user1Lng != null) 'user1_lng': user1Lng,
    if (user2Lat != null) 'user2_lat': user2Lat,
    if (user2Lng != null) 'user2_lng': user2Lng,
    if (mapCenterLat != null) 'map_center_lat': mapCenterLat,
    if (mapCenterLng != null) 'map_center_lng': mapCenterLng,
    if (mapZoom != null) 'map_zoom': mapZoom,
    if (matchedIntent != null) 'matched_intent': matchedIntent,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    if (expiredAt != null) 'expired_at': expiredAt!.toIso8601String(),
    if (matchId != null) 'match_id': matchId,
  };
}

class MatchModel {
  final String id;
  final String userAId;
  final String userBId;
  final String matchedIntent;
  final String matchType;
  final DateTime createdAt;
  final int? chatStartWindowSeconds;
  final int chatStartExtensionSeconds;
  final int chatStartExtensionCount;
  final DateTime? expiresAt;
  final bool hasExtended;
  final String? eventId;

  // Event details for event matches
  final String? eventName;
  final String? eventLink;

  // Proximity location + rematch tracking
  // Legacy exact fields (kept for compat, now null with privacy option 3)
  final int matchOccurrence;
  final double? user1Latitude;
  final double? user1Longitude;
  final double? user2Latitude;
  final double? user2Longitude;
  // Coarse viewport for option 3
  final double? mapCenterLat;
  final double? mapCenterLng;
  final double? mapZoom;
  final List<MatchLocation> previousLocations;
  final bool isRetroactive;

  String otherUserId = ''; // <-- This is the only "other" ID we store

  String getMatchReason() {
    return matchedIntent;
  }

  /// Total window including extensions, for expiry calculation.
  Duration get effectiveChatWindow => Duration(
    seconds:
        (chatStartWindowSeconds ?? const Duration(hours: 24).inSeconds) +
        chatStartExtensionSeconds,
  );

  /// Computed expiry; uses server-provided expires_at when available,
  /// otherwise derives from createdAt + effective window.
  DateTime get effectiveExpiresAt =>
      expiresAt ?? createdAt.toUtc().add(effectiveChatWindow);

  /// Remaining time before expiry (negative if already expired).
  Duration remainingFrom(DateTime now) =>
      effectiveExpiresAt.difference(now.toUtc());

  /// Whether the chat-start countdown is still running: the window has not
  /// elapsed and no chat has been opened yet. Once a chat exists there is
  /// nothing left to expire, which is why the row hides its timer — and why
  /// "Expiring soon" has nothing to order.
  bool hasRunningTimer({required bool chatStarted, required DateTime now}) =>
      !chatStarted && remainingFrom(now) > Duration.zero;

  /// When something last happened in this match: its newest message, or the
  /// match itself while the chat has no message yet. [lastMessageAtByMatch] is
  /// the client-side per-match message times — the server's `last_activity_at`
  /// is still just the match's own created_at.
  DateTime activityAt(Map<String, DateTime> lastMessageAtByMatch) {
    final messageAt = lastMessageAtByMatch[id];
    if (messageAt == null) return createdAt;
    return messageAt.isAfter(createdAt) ? messageAt : createdAt;
  }

  MatchModel({
    required this.id,
    required this.userAId,
    required this.userBId,
    required this.matchedIntent,
    required this.matchType,
    required this.createdAt,
    required this.otherUserId,
    this.chatStartWindowSeconds,
    this.chatStartExtensionSeconds = 0,
    this.chatStartExtensionCount = 0,
    this.expiresAt,
    this.hasExtended = false,
    this.eventId,
    this.eventName,
    this.eventLink,
    this.matchOccurrence = 1,
    this.user1Latitude,
    this.user1Longitude,
    this.user2Latitude,
    this.user2Longitude,
    this.mapCenterLat,
    this.mapCenterLng,
    this.mapZoom,
    this.previousLocations = const [],
    this.isRetroactive = false,
  });

  /// All locations relevant for this match: previous expiries + current.
  /// Option 3: coarse center is displayable. For privacy we prefer coarse over exact.
  List<MatchLocation> get allMatchLocations {
    final current = MatchLocation(
      occurrence: matchOccurrence,
      user1Lat: user1Latitude,
      user1Lng: user1Longitude,
      user2Lat: user2Latitude,
      user2Lng: user2Longitude,
      mapCenterLat: mapCenterLat,
      mapCenterLng: mapCenterLng,
      mapZoom: mapZoom,
      matchedIntent: matchedIntent,
      createdAt: createdAt,
      matchId: id,
    );
    final hasAnyDisplayable =
        current.hasDisplayableLocation ||
        previousLocations.any((l) => l.hasDisplayableLocation);
    if (!hasAnyDisplayable && isProximityMatch) {
      // Fallback generic when no coarse/exact stored (old matches) -> no map
      return [];
    }
    // If coarse is present, we don't need generic fallback generation
    if (previousLocations.isEmpty) {
      if (hasAnyDisplayable || matchOccurrence == 1) {
        // For coarse, even if current has only coarse, return it
        if (current.hasDisplayableLocation) return [current];
        // Old matches with no displayable data -> empty (handled above)
        return hasAnyDisplayable ? [current] : [];
      }
      return [];
    }
    final alreadyHasCurrent = previousLocations.any(
      (l) => l.occurrence == matchOccurrence,
    );
    if (alreadyHasCurrent) return List<MatchLocation>.from(previousLocations);
    final list = [...previousLocations, current];
    return list;
  }

  bool get isRematch => matchOccurrence > 1;

  bool get hasProximityLocation =>
      (user1Latitude != null &&
          user1Longitude != null &&
          user2Latitude != null &&
          user2Longitude != null) ||
      (mapCenterLat != null && mapCenterLng != null) ||
      previousLocations.any((l) => l.hasDisplayableLocation);

  bool get hasCoarseLocation => mapCenterLat != null && mapCenterLng != null;

  bool get isProximityMatch =>
      matchType == 'proximity' ||
      matchType == 'co_motion' ||
      matchType == 'manual_test';

  // Factory for data coming from the RPC function ('get_match_details')
  factory MatchModel.fromJsonRpc(
    Map<String, dynamic> json,
    String currentUserId,
  ) {
    if (currentUserId.isEmpty) {
      return MatchModel(
        id: json['match_id'] ?? '',
        userAId: json['user1_id'] ?? '',
        userBId: json['user2_id'] ?? '',
        matchedIntent: 'Error',
        matchType: 'error',
        createdAt: DateTime.now(),
        otherUserId: 'ERROR',
        eventId: null,
      );
    }

    final String matchId = json['match_id'] ?? json['id'] ?? '';
    final String userAId = json['user1_id'] ?? '';
    final String userBId = json['user2_id'] ?? '';
    final dynamic rawWindow = json['chat_start_window_seconds'];
    final int? chatStartWindowSeconds = rawWindow is int
        ? rawWindow
        : int.tryParse(rawWindow?.toString() ?? '');
    final dynamic rawExt = json['chat_start_extension_seconds'];
    final int chatStartExtensionSeconds = rawExt is int
        ? rawExt
        : int.tryParse(rawExt?.toString() ?? '') ?? 0;
    final dynamic rawExtCount = json['chat_start_extension_count'];
    final int chatStartExtensionCount = rawExtCount is int
        ? rawExtCount
        : int.tryParse(rawExtCount?.toString() ?? '') ?? 0;
    final dynamic rawExpires = json['expires_at'];
    final DateTime? expiresAt = rawExpires != null
        ? DateTime.tryParse(rawExpires.toString())
        : null;
    final dynamic rawHasExtended = json['has_extended'];
    final bool hasExtended =
        rawHasExtended == true ||
        rawHasExtended?.toString().toLowerCase() == 'true';

    // Determine who the "other" user is
    final bool isAOther = (userAId != currentUserId);
    final String determinedOtherId = isAOther ? userAId : userBId;

    // Proximity location + rematch fields
    final dynamic rawOcc =
        json['match_occurrence'] ??
        json['matchOccurrence'] ??
        json['occurrence'];
    final int matchOccurrence = rawOcc is int
        ? rawOcc
        : int.tryParse(rawOcc?.toString() ?? '1') ?? 1;
    double? parseCoord(dynamic v) {
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final double? u1Lat = parseCoord(
      json['user1_latitude'] ?? json['user1_lat'],
    );
    final double? u1Lng = parseCoord(
      json['user1_longitude'] ?? json['user1_lng'],
    );
    final double? u2Lat = parseCoord(
      json['user2_latitude'] ?? json['user2_lat'],
    );
    final double? u2Lng = parseCoord(
      json['user2_longitude'] ?? json['user2_lng'],
    );
    final double? cLat = parseCoord(
      json['map_center_lat'] ?? json['mapCenterLat'] ?? json['center_lat'],
    );
    final double? cLng = parseCoord(
      json['map_center_lng'] ?? json['mapCenterLng'] ?? json['center_lng'],
    );
    final double? cZoom = parseCoord(
      json['map_zoom'] ?? json['mapZoom'] ?? json['zoom'],
    );

    List<MatchLocation> prev = [];
    final dynamic rawPrev =
        json['previous_locations'] ??
        json['previousLocations'] ??
        json['locations_history'];
    if (rawPrev is List) {
      prev = rawPrev
          .whereType<Map>()
          .map((e) => MatchLocation.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      // Also handle list of dynamic maps
      if (prev.isEmpty) {
        try {
          prev = rawPrev
              .map(
                (e) =>
                    MatchLocation.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
        } catch (_) {}
      }
    } else if (rawPrev is String && rawPrev.trim().isNotEmpty) {
      try {
        final decoded = _decodeJsonMaybe(rawPrev);
        if (decoded is List) {
          prev = decoded
              .whereType<Map>()
              .map((e) => MatchLocation.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      } catch (_) {}
    }
    final dynamic rawAll = json['all_locations'] ?? json['allLocations'];
    if (prev.isEmpty && rawAll is List && rawAll.isNotEmpty) {
      try {
        final List<MatchLocation> all = rawAll
            .map(
              (e) =>
                  MatchLocation.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        // Derive previous as all without current occurrence
        prev = all.where((l) => l.occurrence != matchOccurrence).toList();
        if (prev.length == all.length && all.length > 1) {
          // Fallback: treat all but last as previous
          prev = all.sublist(0, all.length - 1);
        }
      } catch (_) {}
    }

    return MatchModel(
      id: matchId,
      userAId: userAId,
      userBId: userBId,
      matchedIntent: json['matched_intent'] ?? 'Unknown',
      matchType: json['match_type'] ?? 'unknown',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
      otherUserId: determinedOtherId, // <-- Pass the ID
      chatStartWindowSeconds: chatStartWindowSeconds,
      chatStartExtensionSeconds: chatStartExtensionSeconds,
      chatStartExtensionCount: chatStartExtensionCount,
      expiresAt: expiresAt,
      hasExtended: hasExtended,
      eventId: json['event_id'],
      eventName: json['event_name'],
      eventLink: json['event_link'],
      matchOccurrence: matchOccurrence.clamp(1, 3),
      user1Latitude: u1Lat,
      user1Longitude: u1Lng,
      user2Latitude: u2Lat,
      user2Longitude: u2Lng,
      mapCenterLat: cLat,
      mapCenterLng: cLng,
      mapZoom: cZoom,
      previousLocations: prev,
      isRetroactive:
          (json['is_retroactive'] ?? json['isRetroactive'] ?? false) is bool
          ? (json['is_retroactive'] ?? json['isRetroactive'] ?? false) as bool
          : (json['is_retroactive'] ?? json['isRetroactive'] ?? false)
                    .toString()
                    .toLowerCase() ==
                'true',
    );
  }

  static dynamic _decodeJsonMaybe(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
} // End class MatchModel
