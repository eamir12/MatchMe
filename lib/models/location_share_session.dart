import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

enum ShareStatus { sharing, paused, stopped, unknown }

enum BroadcastMode { flutter, native, none }

class _ClearSentinel {
  const _ClearSentinel();
}

class LocationShareSession {
  final String matchId;
  final String myUserId;
  final String otherUserId;
  final String otherUserName;
  final String? otherUserPhoto;
  final String? myUserPhoto;
  ShareStatus myStatus;
  ShareStatus otherStatus;
  LatLng? myPosition;
  LatLng? otherPosition;
  DateTime? otherPositionTimestamp;
  final DateTime startedAt;
  final DateTime? expiresAt;
  final Duration updateInterval;
  final Uint8List? sessionKey;
  BroadcastMode broadcastMode;

  LocationShareSession({
    required this.matchId,
    required this.myUserId,
    required this.otherUserId,
    required this.otherUserName,
    this.otherUserPhoto,
    this.myUserPhoto,
    this.myStatus = ShareStatus.sharing,
    this.otherStatus = ShareStatus.unknown,
    this.myPosition,
    this.otherPosition,
    this.otherPositionTimestamp,
    DateTime? startedAt,
    this.expiresAt,
    this.updateInterval = const Duration(seconds: 5),
    this.sessionKey,
    this.broadcastMode = BroadcastMode.none,
  }) : startedAt = startedAt ?? DateTime.now();

  bool get isActive =>
      myStatus == ShareStatus.sharing || myStatus == ShareStatus.paused;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  bool get bothSharing =>
      myStatus == ShareStatus.sharing && otherStatus == ShareStatus.sharing;

  Duration? get timeRemaining {
    if (expiresAt == null) return null;
    final remaining = expiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  static const _clear = _ClearSentinel();

  LocationShareSession copyWith({
    ShareStatus? myStatus,
    ShareStatus? otherStatus,
    LatLng? myPosition,
    Object? otherPosition = _clear,
    Object? otherPositionTimestamp = _clear,
    Object? expiresAt = _clear,
    Uint8List? sessionKey,
    String? otherUserPhoto,
    String? myUserPhoto,
    BroadcastMode? broadcastMode,
  }) {
    return LocationShareSession(
      matchId: matchId,
      myUserId: myUserId,
      otherUserId: otherUserId,
      otherUserName: otherUserName,
      otherUserPhoto: otherUserPhoto ?? this.otherUserPhoto,
      myUserPhoto: myUserPhoto ?? this.myUserPhoto,
      myStatus: myStatus ?? this.myStatus,
      otherStatus: otherStatus ?? this.otherStatus,
      myPosition: myPosition ?? this.myPosition,
      otherPosition: otherPosition is _ClearSentinel
          ? this.otherPosition
          : otherPosition as LatLng?,
      otherPositionTimestamp: otherPositionTimestamp is _ClearSentinel
          ? this.otherPositionTimestamp
          : otherPositionTimestamp as DateTime?,
      startedAt: startedAt,
      expiresAt: expiresAt is _ClearSentinel
          ? this.expiresAt
          : expiresAt as DateTime?,
      updateInterval: updateInterval,
      sessionKey: sessionKey ?? this.sessionKey,
      broadcastMode: broadcastMode ?? this.broadcastMode,
    );
  }
}
