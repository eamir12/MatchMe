// lib/services/verification_service.dart
// Service for handling user verification via photo upload

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/storage_helper.dart';

class VerificationService {
  final SupabaseClient _supabase = Supabase.instance.client;

  /// Prefix of the on-device cache key holding the last verification status
  /// payload that was read from the server.
  static const String _statusCachePrefix = 'verification_status_cache_';

  Future<String> submitVerificationPhoto(
    String userId,
    Uint8List photoBytes, {
    String? gestureCode,
    String? gesturePrompt,
  }) async {
    print('🔄 VERIFICATION: Starting verification photo submission');

    try {
      // Upload photo to verification bucket
      var fileName = '$userId/verification.jpg';
      print('📁 VERIFICATION: Using filename: $fileName');

      // Validate file size
      final maxSize = await (() async {
        try {
          return await appConfigService.getInt(
            'profile.max_file_size_bytes',
            defaultValue: 5242880,
          );
        } catch (e) {
          return 5242880;
        }
      })();
      if (photoBytes.length > maxSize) {
        final maxMb = (maxSize / (1024 * 1024)).toStringAsFixed(0);
        print(
          '❌ VERIFICATION: File too large: ${photoBytes.length} bytes (max: $maxSize)',
        );
        throw Exception('File too large. Maximum size is ${maxMb}MB.');
      }
      print(
        '✅ VERIFICATION: File size validation passed: ${photoBytes.length} bytes',
      );

      // Upload bytes using uploadBinary to verification-photos bucket
      print(
        '📤 VERIFICATION: Attempting upload to verification-photos bucket...',
      );
      try {
        // First try to delete any existing verification photo for this user
        print('🗑️ VERIFICATION: Removing any existing verification photo...');
        try {
          await _supabase.storage.from('verification-photos').remove([
            fileName,
          ]);
          print('✅ VERIFICATION: Existing photo removed (or didn\'t exist)');
        } catch (deleteError) {
          // Ignore delete errors - file might not exist
          print(
            'ℹ️ VERIFICATION: No existing photo to remove (this is normal for first upload)',
          );
        }

        // Now upload the new photo
        await _supabase.storage
            .from('verification-photos')
            .uploadBinary(fileName, photoBytes);
        StorageHelper.evictImageCache(fileName, bucket: 'verification-photos');
        unawaited(
          StorageHelper.prefetchImageSource(
            fileName,
            bucket: 'verification-photos',
          ),
        );
        print(
          '? VERIFICATION: Upload to verification-photos bucket successful',
        );
      } catch (uploadError) {
        print(
          '❌ VERIFICATION: Upload to verification-photos bucket failed: $uploadError',
        );
        print('🔍 VERIFICATION: Error type: ${uploadError.runtimeType}');
        print('🔍 VERIFICATION: Error toString: ${uploadError.toString()}');

        // Check if it's a StorageException and get more details
        if (uploadError is StorageException) {
          print('🔍 VERIFICATION: StorageException details:');
          print('   - Message: ${uploadError.message}');
          print('   - Status Code: ${uploadError.statusCode}');
          print('   - Error: ${uploadError.error}');
        }

        rethrow; // Re-throw to be caught by outer try-catch
      }

      print('🤖 VERIFICATION: Triggering AI face comparison...');
      await _compareVerificationPhotos(
        userId,
        verificationPhotoPath: fileName,
        gestureCode: gestureCode,
        gesturePrompt: gesturePrompt,
      );

      print(
        '🎉 VERIFICATION: Verification photo submission completed successfully',
      );
      return fileName;
    } catch (e) {
      print('❌ VERIFICATION: Failed to submit verification photo: $e');
      print('🔍 VERIFICATION: Error type: ${e.runtimeType}');
      print('🔍 VERIFICATION: Error toString: ${e.toString()}');
      print('🔍 VERIFICATION: Stack trace: ${StackTrace.current}');
      throw Exception('Failed to submit verification photo: $e');
    }
  }

  Future<void> _compareVerificationPhotos(
    String userId, {
    required String verificationPhotoPath,
    String? gestureCode,
    String? gesturePrompt,
  }) async {
    print('🤖 VERIFICATION: Starting AI comparison');

    try {
      print(
        '📡 VERIFICATION: Invoking compare-verification-photos edge function...',
      );
      final body = <String, dynamic>{
        'userId': userId,
        'verificationPhotoPath': verificationPhotoPath,
      };
      if (gestureCode != null) {
        body['gestureCode'] = gestureCode;
      }
      if (gesturePrompt != null) {
        body['gesturePrompt'] = gesturePrompt;
      }
      final response = await _supabase.functions.invoke(
        'compare-verification-photos',
        body: body,
      );

      print(
        '📡 VERIFICATION: Edge function response status: ${response.status}',
      );

      if (response.status != 200) {
        print(
          '❌ VERIFICATION: Edge function returned non-200 status: ${response.status}',
        );
        print('🔍 VERIFICATION: Response data: ${response.data}');
        throw Exception('AI comparison failed: ${response.status}');
      }

      print('🎉 VERIFICATION: AI comparison processing completed');
    } catch (e) {
      print('❌ VERIFICATION: Error in AI comparison: $e');
      print('🔍 VERIFICATION: Error type: ${e.runtimeType}');
      print('🔍 VERIFICATION: Stack trace: ${StackTrace.current}');
      rethrow;
    }
  }

  /// Get verification status for a user
  Future<Map<String, dynamic>?> getVerificationStatus(String userId) async {
    try {
      final response = await _supabase
          .from('users')
          .select(
            'is_verified, verification_status, verification_submitted_at, verification_reviewed_at, verification_similarity_score, verification_auto_rejected, verification_ai_analysis, verification_reference_generated_at, verification_photo_retention_until, verification_photo_path',
          )
          .eq('id', userId)
          .maybeSingle();

      if (response != null) {
        await cacheVerificationStatus(userId, response);
        unawaited(_prefetchVerificationMedia(userId, response));
      }

      return response;
    } catch (e) {
      print('Error getting verification status: $e');
      return null;
    }
  }

  /// Downloads the verification selfie and the primary profile photo that the
  /// rejection comparison renders, so both are available offline even if the
  /// verification screen was never opened while online.
  Future<void> _prefetchVerificationMedia(
    String userId,
    Map<String, dynamic> statusData,
  ) async {
    try {
      final verificationPath = statusData['verification_photo_path']
          ?.toString()
          .trim();
      if (verificationPath != null && verificationPath.isNotEmpty) {
        unawaited(
          StorageHelper.prefetchImageSource(
            verificationPath,
            bucket: 'verification-photos',
          ),
        );
      }
      final localDb = await LocalDbService.instance;
      final profile = await localDb.getLocalProfile(userId);
      final photos = profile?['photos'];
      if (photos is List && photos.isNotEmpty) {
        final primary = photos.first.toString().trim();
        if (primary.isNotEmpty) {
          unawaited(StorageHelper.prefetchImageSource(primary));
        }
      }
    } catch (_) {}
  }

  /// Returns the last verification status payload that was read from the
  /// server, straight from the on-device cache.
  ///
  /// The verification screen paints from this cache the moment it opens, so a
  /// rejection shows its AI analysis and the verification photo right away
  /// instead of only after the network round-trip completes.
  Future<Map<String, dynamic>?> getCachedVerificationStatus(
    String userId,
  ) async {
    LocalDbService? localDb;
    try {
      if (LocalDbService.isInitialized) {
        localDb = LocalDbService.shared;
        final cached = await localDb.getVerificationStatus(userId);
        if (cached != null) return cached;
      }
    } catch (e) {
      // Hive not ready/available (e.g. very early startup); the legacy
      // plaintext fallback below still preserves first-paint behavior.
      print('Error reading encrypted verification status: $e');
    }

    // One-time migration: older builds stored this payload in plaintext
    // SharedPreferences. Move it into the encrypted box and delete the
    // plaintext copy so rejection/AI details do not linger on disk.
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacyKey = '$_statusCachePrefix$userId';
      final raw = prefs.getString(legacyKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      if (localDb != null) {
        await localDb.saveVerificationStatus(userId, data);
        await prefs.remove(legacyKey);
      }
      return data;
    } catch (e) {
      print('Error reading cached verification status: $e');
      return null;
    }
  }

  /// Persists the verification status payload so the next screen entry can
  /// render it immediately.
  Future<void> cacheVerificationStatus(
    String userId,
    Map<String, dynamic>? data,
  ) async {
    if (data == null || data.isEmpty) return;
    try {
      if (!LocalDbService.isInitialized) {
        // First-paint reads must not block on Hive; persist as soon as the
        // encrypted boxes finish opening.
        unawaited(
          LocalDbService.instance
              .then((db) => db.saveVerificationStatus(userId, data))
              .catchError((Object error) {
                print('Error caching verification status: $error');
              }),
        );
        return;
      }
      final localDb = LocalDbService.shared;
      await localDb.saveVerificationStatus(userId, data);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_statusCachePrefix$userId');
    } catch (e) {
      print('Error caching verification status: $e');
    }
  }

  /// Check if user is verified
  Future<bool> isUserVerified(String userId) async {
    try {
      final status = await getVerificationStatus(userId);
      return status?['is_verified'] == true;
    } catch (e) {
      print('Error checking verification status: $e');
      return false;
    }
  }

  /// Get signed URL for verification photo (for admin review)
  Future<String?> getVerificationPhotoUrl(String photoPath) async {
    try {
      return await StorageHelper.getSignedUrlFromBucket(
        photoPath,
        'verification-photos',
      );
    } catch (e) {
      print('Error getting verification photo URL: $e');
      return null;
    }
  }

  /// Get pending verifications for admin review
  Future<List<Map<String, dynamic>>> getPendingVerifications() async {
    try {
      final response = await _supabase
          .from('users')
          .select(
            'id, name, verification_photo_path, verification_submitted_at',
          )
          .eq('verification_status', 'pending')
          .order('verification_submitted_at', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      print('Error getting pending verifications: $e');
      return [];
    }
  }

  /// Delete verification photo (cleanup after rejection or when user re-submits)
  Future<void> deleteVerificationPhoto(String photoPath) async {
    try {
      // Normalize path for verification-photos bucket
      String? normalize(String input) {
        if (input.isEmpty) return null;
        try {
          if (input.startsWith('http://') || input.startsWith('https://')) {
            final uri = Uri.parse(input);
            final segments = uri.pathSegments;
            final idx = segments.indexOf('verification-photos');
            if (idx >= 0 && idx < segments.length - 1) {
              return segments.sublist(idx + 1).join('/');
            }
            return null;
          }
        } catch (_) {}

        var candidate = input.startsWith('/') ? input.substring(1) : input;
        if (candidate.startsWith('verification-photos/')) {
          candidate = candidate.substring('verification-photos/'.length);
        }
        return candidate;
      }

      final normalized = normalize(photoPath);
      if (normalized == null || normalized.isEmpty) return;

      await _supabase.storage.from('verification-photos').remove([normalized]);
      StorageHelper.evictImageCache(normalized, bucket: 'verification-photos');
      print(
        '? VERIFICATION: Deleted verification photo from verification-photos bucket: $normalized',
      );
    } catch (e) {
      print('Error deleting verification photo: $e');
    }
  }

  /// Fetch privacy notice text (optionally localized) from the `translations` table.
  /// Prefers the supplied locale and falls back to 'en' if not found. Returns null
  /// when no DB translation is available (caller should fall back to built-in string).
  Future<String?> getPrivacyNotice(String locale) async {
    try {
      return await publicReferenceDataService.fetchTranslationValue(
        'verificationPrivacyNotice',
        locale,
      );
    } catch (e) {
      print(
        '⚠️ VERIFICATION: Unable to fetch privacy notice from translations table: $e',
      );
    }
    return null;
  }

  /// Request manual human review for a rejected verification photo
  Future<void> requestManualReview() async {
    try {
      await _supabase.rpc('request_verification_manual_review');
      print('✅ VERIFICATION: Requested manual review successfully');
    } catch (e) {
      print('❌ VERIFICATION: Failed to request manual review: $e');
      rethrow;
    }
  }
}
