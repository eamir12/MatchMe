import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

final referralServiceProvider = Provider((ref) => ReferralService(ref));

class ReferralService {
  final Ref ref;
  final SupabaseClient _supabase = Supabase.instance.client;
  static const String _webDeviceIdPrefsKey = 'referral_web_device_id';
  static const Uuid _uuid = Uuid();

  ReferralService(this.ref);

  /// Generates a unique referral code for the user if they don't have one.
  Future<String?> generateReferralCodeIfNeeded(String userId, String? existingCode) async {
    if (existingCode != null && existingCode.isNotEmpty) {
      return existingCode;
    }

    try {
      // Generate a simple code: 4 random letters + 4 random digits
      final code = _generateRandomCode();

      // Update user profile
      await _supabase.from('users').update({
        'referral_code': code,
      }).eq('id', userId);

      // Update Local DB to reflect changes immediately
      final localDb = ref.read(localDbProvider);
      final profile = await localDb.getLocalProfile(userId);
      if (profile != null) {
        final updatedProfile = Map<String, dynamic>.from(profile);
        updatedProfile['referral_code'] = code;
        await localDb.saveLocalProfile(userId, updatedProfile);
      }

      // Invalidate profile to refresh local state
      ref.invalidate(userProfileProvider(userId));

      return code;
    } catch (e) {
      debugPrint('Error generating referral code: $e');
      return null;
    }
  }

  String _generateRandomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const numbers = '0123456789';
    final rnd = Random();
    final charPart = List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
    final numPart = List.generate(4, (_) => numbers[rnd.nextInt(numbers.length)]).join();
    return '$charPart$numPart';
  }

  /// Checks for a pending referral code via fingerprint (Edge Function).
  /// Returns the code if found and claimed, null otherwise.
  Future<String?> checkPendingReferralFromFingerprint() async {
    try {
      final res = await _supabase.functions.invoke('check-referral');
      
      if (res.status == 200 && res.data != null) {
        final data = res.data as Map<String, dynamic>;
        if (data['found'] == true) {
          final code = data['code'] as String;
          debugPrint('Found pending referral from fingerprint: $code');
          return code;
        }
      }
    } catch (e) {
      debugPrint('Error checking fingerprint referral: $e');
    }
    return null;
  }

  /// Saves a pending referral code from a deep link.
  Future<void> handleIncomingReferralCode(String code) async {
    debugPrint('Received referral code: $code');
    final localDb = ref.read(localDbProvider);
    await localDb.savePendingReferralCode(code);
  }

  /// Generates a unique device ID based on hardware properties.
  Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    String deviceId = 'unknown';

    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final existing = prefs.getString(_webDeviceIdPrefsKey);
        final v = (existing == null || existing.trim().isEmpty) ? null : existing.trim();
        final id = v ?? _uuid.v4();
        if (v == null) {
          await prefs.setString(_webDeviceIdPrefsKey, id);
        }
        return 'web_$id';
      }
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Use a combination of reliable IDs to create a fingerprint
        deviceId = 'android_${androidInfo.id}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = 'ios_${iosInfo.identifierForVendor}';
      }
    } catch (e) {
      debugPrint('Error getting device info: $e');
    }
    return deviceId;
  }

  Future<String> debugGetDeviceId() {
    return _getDeviceId();
  }

  /// Processes the pending referral for a new user.
  /// Should be called after signup/login.
  Future<void> processPendingReferral(String userId) async {
    final localDb = ref.read(localDbProvider);
    final code = await localDb.getPendingReferralCode();

    if (code == null || code.isEmpty) return;

    try {
      final deviceId = await _getDeviceId();
      
      // Call the secure Postgres function
      final res = await _supabase.rpc('claim_referral', params: {
        'p_referral_code': code,
        'p_device_id': deviceId,
      });

      if (res is Map) { // Handle JSONB response
         final success = res['success'] == true;
         final error = res['error'];
         
         if (success) {
           debugPrint('Referral claimed successfully via secure RPC.');
           await localDb.clearPendingReferralCode();
         } else {
           debugPrint('Referral claim failed: $error');
           // If it's a permanent error (like "not new" or "already referred"), clear the code so we don't retry loop.
           // If it's network error, we might want to keep it.
           // For now, clear to avoid annoying the user.
           await localDb.clearPendingReferralCode(); 
         }
      }
    } catch (e) {
      debugPrint('Error calling claim_referral RPC: $e');
    }
  }

  /// Completes the referral and grants rewards.
  /// Should be called when profile is completed.
  Future<void> completeReferral(String userId) async {
    try {
      // Find pending referral
      final referralRes = await _supabase
          .from('referrals')
          .select('id, referrer_id')
          .eq('referee_id', userId)
          .eq('status', 'pending')
          .maybeSingle();

      if (referralRes == null) return;

      final referralId = referralRes['id'] as String;
      final referrerId = referralRes['referrer_id'] as String;

      // Mark as completed
      await _supabase.from('referrals').update({
        'status': 'completed',
        'completed_at': DateTime.now().toIso8601String(),
      }).eq('id', referralId);

      // Grant rewards
      final appConfig = AppConfigService();
      final rewardAmount = await appConfig.getInt('referral.reward_amount', defaultValue: 10);
      
      // Increment referrer credits
      await _incrementCredits(referrerId, rewardAmount);
      
      // Increment referee credits
      await _incrementCredits(userId, rewardAmount);

      debugPrint('Referral $referralId completed. Rewards granted: $rewardAmount credits.');

    } catch (e) {
      debugPrint('Error completing referral: $e');
    }
  }

  Future<void> _incrementCredits(String userId, int amount) async {
    // This is not atomic without a stored procedure, but sufficient for this demo.
    try {
      final res = await _supabase.from('users').select('credits').eq('id', userId).single();
      final currentCredits = (res['credits'] ?? 0) as int;
      await _supabase.from('users').update({
        'credits': currentCredits + amount,
      }).eq('id', userId);
      
      // If it is the current user:
      final currentUser = _supabase.auth.currentUser;
      if (currentUser?.id == userId) {
        ref.invalidate(userProfileProvider(userId));
      }
    } catch (e) {
      debugPrint('Error incrementing credits for $userId: $e');
    }
  }
}
