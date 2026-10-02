import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:matchme/utils/offline_utils.dart';

final referralServiceProvider = Provider((ref) => ReferralService(ref));

class ReferralService {
  final Ref ref;
  final SupabaseClient _supabase = Supabase.instance.client;
  static const String _webDeviceIdPrefsKey = 'referral_web_device_id';
  static const Uuid _uuid = Uuid();

  ReferralService(this.ref);

  /// Gets or creates the referral code using local cache-first strategy.
  /// Since referral codes are immutable (created once, never change),
  /// we store them locally for performance and offline support.
  /// Database is only queried as a fallback if local storage is empty.
  Future<String?> getCachedReferralCode(String userId) async {
    final localDb = ref.read(localDbProvider);
    final cachedCode = await localDb.getCachedReferralCode(userId);
    if (cachedCode != null && cachedCode.isNotEmpty) {
      return cachedCode;
    }

    final localProfile = await localDb.getLocalProfile(userId);
    final profileCode = localProfile?['referral_code']?.toString().trim();
    if (profileCode != null && profileCode.isNotEmpty) {
      await localDb.saveCachedReferralCode(userId, profileCode);
      return profileCode;
    }

    return null;
  }

  Future<String?> ensureReferralCodeAvailable(
    String userId, {
    bool? isProfileComplete,
  }) async {
    try {
      final localDb = ref.read(localDbProvider);
      final cachedCode = await getCachedReferralCode(userId);
      if (cachedCode != null && cachedCode.isNotEmpty) {
        return cachedCode;
      }

      // Skip Supabase calls when paused (offline)
      if (shouldSkipSupabaseCalls()) {
        return null;
      }

      final localProfile = await localDb.getLocalProfile(userId);
      final localCompletionValue = localProfile?['is_profile_complete'];
      final localIsProfileComplete = localCompletionValue is bool
          ? localCompletionValue
          : null;
      final shouldCreateCode = isProfileComplete ?? localIsProfileComplete;

      if (shouldCreateCode == false) {
        return null;
      }

      if (shouldCreateCode == null) {
        final userRow = await _supabase
            .from('users')
            .select('referral_code, is_profile_complete')
            .eq('id', userId)
            .maybeSingle();

        if (userRow == null) {
          return null;
        }

        final dbCode = userRow['referral_code']?.toString().trim();
        if (dbCode != null && dbCode.isNotEmpty) {
          await localDb.saveCachedReferralCode(userId, dbCode);
          if (localProfile != null) {
            final updatedProfile = Map<String, dynamic>.from(localProfile);
            updatedProfile['referral_code'] = dbCode;
            await localDb.saveLocalProfile(userId, updatedProfile);
          }
          ref.invalidate(userProfileProvider(userId));
          return dbCode;
        }

        if (userRow['is_profile_complete'] != true) {
          return null;
        }
      }

      return await getOrCreateReferralCode(userId);
    } catch (e) {
      print('Error ensuring referral code availability: $e');
      return null;
    }
  }

  Future<String?> getOrCreateReferralCode(String userId) async {
    try {
      print('[Referral] Starting getOrCreateReferralCode');

      // Step 1: Try local cache first (fast, offline-safe)
      final localDb = ref.read(localDbProvider);
      final cachedCode = await getCachedReferralCode(userId);

      if (cachedCode != null && cachedCode.isNotEmpty) {
        print('[Referral] ✓ Found code in local cache');
        return cachedCode;
      }

      // Step 2: Query database as fallback
      final userRow = await _supabase
          .from('users')
          .select('id, referral_code')
          .eq('id', userId)
          .maybeSingle();

      if (userRow == null) {
        print('[Referral] ERROR: User not found');
        return null;
      }

      final dbCode = userRow['referral_code'] as String?;
      if (dbCode != null && dbCode.isNotEmpty) {
        print('[Referral] ✓ Found existing code in database');
        await localDb.saveCachedReferralCode(userId, dbCode);
        final localProfile = await localDb.getLocalProfile(userId);
        if (localProfile != null) {
          final updatedProfile = Map<String, dynamic>.from(localProfile);
          updatedProfile['referral_code'] = dbCode;
          await localDb.saveLocalProfile(userId, updatedProfile);
        }
        return dbCode;
      }

      // Step 3: Generate code server-side via RPC (collision-proof, atomic)
      print(
        '[Referral] No existing code found, calling generate_referral_code RPC...',
      );
      final code = await _supabase.rpc(
        'generate_referral_code',
        params: {'p_user_id': userId},
      );

      if (code == null || code.toString().isEmpty) {
        print('[Referral] ✗ RPC returned empty code');
        return null;
      }

      final codeStr = code.toString();
      print('[Referral] ✓ Server generated referral code');

      // Cache locally
      await localDb.saveCachedReferralCode(userId, codeStr);
      final localProfile = await localDb.getLocalProfile(userId);
      if (localProfile != null) {
        final updatedProfile = Map<String, dynamic>.from(localProfile);
        updatedProfile['referral_code'] = codeStr;
        await localDb.saveLocalProfile(userId, updatedProfile);
      }

      ref.invalidate(userProfileProvider(userId));
      print('[Referral] ✓ Successfully created and cached code: $codeStr');
      return codeStr;
    } catch (e, st) {
      print('[Referral] ✗ ERROR: $e');
      print('[Referral] Stack trace: $st');
      return null;
    }
  }

  /// DEPRECATED: Use getOrCreateReferralCode() instead.
  /// Generates a unique referral code for the user if they don't have one.
  /// Kept for backwards compatibility — delegates to server RPC.
  Future<String?> generateReferralCodeIfNeeded(
    String userId,
    String? existingCode,
  ) async {
    if (existingCode != null && existingCode.isNotEmpty) {
      return existingCode;
    }
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final code = await _supabase.rpc(
        'generate_referral_code',
        params: {'p_user_id': userId},
      );
      if (code == null) return null;
      final codeStr = code.toString();
      if (codeStr.isEmpty) return null;

      final localDb = ref.read(localDbProvider);
      final profile = await localDb.getLocalProfile(userId);
      if (profile != null) {
        final updatedProfile = Map<String, dynamic>.from(profile);
        updatedProfile['referral_code'] = codeStr;
        await localDb.saveLocalProfile(userId, updatedProfile);
      }
      ref.invalidate(userProfileProvider(userId));
      return codeStr;
    } catch (e) {
      print('Error generating referral code: $e');
      return null;
    }
  }

  /// Checks for a pending referral code via fingerprint (Edge Function).
  /// Returns the code if found and claimed, null otherwise.
  Future<String?> checkPendingReferralFromFingerprint() async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final res = await _supabase.functions.invoke('check-referral');

      if (res.status == 200 && res.data != null) {
        final data = res.data as Map<String, dynamic>;
        if (data['found'] == true) {
          final code = data['code'] as String;
          print('Found pending referral from fingerprint: $code');
          return code;
        }
      }
    } catch (e) {
      if (!isExpectedOfflineFailure(e)) {
        print('Error checking fingerprint referral: $e');
      }
    }
    return null;
  }

  /// Saves a pending referral code from a deep link.
  Future<void> handleIncomingReferralCode(String code) async {
    print('Received referral code: $code');
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
        final v = (existing == null || existing.trim().isEmpty)
            ? null
            : existing.trim();
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
      print('Error getting device info: $e');
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

    if (shouldSkipSupabaseCalls()) return;

    try {
      final deviceId = await _getDeviceId();

      // Call the secure Postgres function
      final res = await _supabase.rpc(
        'claim_referral',
        params: {'p_referral_code': code, 'p_device_id': deviceId},
      );

      if (res is Map) {
        // Handle JSONB response
        final success = res['success'] == true;
        final error = res['error'];

        if (success) {
          print('Referral claimed successfully via secure RPC.');
          await localDb.clearPendingReferralCode();
        } else {
          print('Referral claim failed: $error');
          // If it's a permanent error (like "not new" or "already referred"), clear the code so we don't retry loop.
          // If it's network error, we might want to keep it.
          // For now, clear to avoid annoying the user.
          await localDb.clearPendingReferralCode();
        }
      }
    } catch (e) {
      print('Error calling claim_referral RPC: $e');
    }
  }

  /// Completes the referral and grants rewards atomically via server RPC.
  /// Should be called when profile is completed.
  Future<void> completeReferral(String userId) async {
    if (shouldSkipSupabaseCalls()) return;

    try {
      final res = await _supabase.rpc(
        'complete_referral',
        params: {'p_user_id': userId},
      );

      if (res is Map) {
        final success = res['success'] == true;
        if (success) {
          final rewardAmount = res['reward_amount'] ?? 0;
          print('Referral completed. Rewards granted: $rewardAmount credits.');
          ref.invalidate(userProfileProvider(userId));
        } else {
          final reason = res['reason'] ?? 'unknown';
          if (reason != 'no_pending_referral') {
            print('Referral completion failed: $reason');
          }
        }
      }
    } catch (e) {
      print('Error completing referral via RPC: $e');
    }
  }
}
