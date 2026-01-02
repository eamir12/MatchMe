// lib/models/match_model.dart
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class MatchModel {
  final String id;
  final String userAId;
  final String userBId;
  final String matchedIntent;
  final String matchType;
  final DateTime createdAt;
  final String? eventId;
  
  // Event details for event matches
  final String? eventName;
  final String? eventLink;

  String otherUserId = ''; // <-- This is the only "other" ID we store

  String getMatchReason() {
    return matchedIntent;
  }

  MatchModel({
    required this.id,
    required this.userAId,
    required this.userBId,
    required this.matchedIntent,
    required this.matchType,
    required this.createdAt,
    required this.otherUserId,
    this.eventId,
    this.eventName,
    this.eventLink,
  });

  // Factory for data coming from the RPC function ('get_match_details')
  factory MatchModel.fromJsonRpc(Map<String, dynamic> json, String currentUserId) {
    if (currentUserId.isEmpty) {
       return MatchModel(
         id: json['match_id'] ?? '', userAId: json['user1_id'] ?? '', userBId: json['user2_id'] ?? '',
         matchedIntent: 'Error', matchType: 'error', createdAt: DateTime.now(),
         otherUserId: 'ERROR', eventId: null
       );
    }

    final String matchId = json['match_id'] ?? '';
    final String userAId = json['user1_id'] ?? '';
    final String userBId = json['user2_id'] ?? '';

    // Determine who the "other" user is
    final bool isAOther = (userAId != currentUserId);
    final String determinedOtherId = isAOther ? userAId : userBId;

    // We no longer read 'user_a_details' or 'user_b_details'
    // The name will be fetched by the UI using the 'determinedOtherId'

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
      eventId: json['event_id'],
      eventName: json['event_name'],
      eventLink: json['event_link'],
    );
  }
} // End class MatchModel
