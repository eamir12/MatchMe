// lib/services/match_extension_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class MatchExtensionService {
  MatchExtensionService._();
  static final MatchExtensionService instance = MatchExtensionService._();

  final SupabaseClient _supabase = Supabase.instance.client;

  /// Calls the SECURITY DEFINER RPC `extend_match_chat_window(p_match_id uuid)`.
  /// Returns the JSON object returned by the RPC (expires_at, extension_seconds, etc.)
  /// Throws a [PostgrestException] with message codes:
  ///   - already_extended
  ///   - chat_already_started
  ///   - match_expired
  ///   - max_extensions_reached
  ///   - forbidden / match_not_found / unauthenticated
  Future<Map<String, dynamic>> extendMatch(String matchId) async {
    final dynamic result = await _supabase.rpc(
      'extend_match_chat_window',
      params: {'p_match_id': matchId},
    );
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    // Some Supabase versions return jsonb as Map<String,dynamic> directly
    return <String, dynamic>{'result': result};
  }

  Future<Map<String, dynamic>> getExtensionStatus(String matchId) async {
    final dynamic result = await _supabase.rpc(
      'get_match_extension_status',
      params: {'p_match_id': matchId},
    );
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    return <String, dynamic>{};
  }
}
