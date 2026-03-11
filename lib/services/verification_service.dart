// lib/services/verification_service.dart
// Service for handling user verification via photo upload

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/storage_helper.dart';

class VerificationService {
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<String> submitVerificationPhoto(
    String userId,
    Uint8List photoBytes, {
    String? gestureCode,
    String? gesturePrompt,
  }) async {
    debugPrint(
      '🔄 VERIFICATION: Starting verification photo submission for user $userId',
    );

    try {
      // Upload photo to verification bucket
      var fileName = '$userId/verification.jpg';
      debugPrint('📁 VERIFICATION: Using filename: $fileName');

      // Validate file size (max 5MB)
      const maxSize = 5 * 1024 * 1024; // 5MB
      if (photoBytes.length > maxSize) {
        debugPrint(
          '❌ VERIFICATION: File too large: ${photoBytes.length} bytes (max: $maxSize)',
        );
        throw Exception('File too large. Maximum size is 5MB.');
      }
      debugPrint(
        '✅ VERIFICATION: File size validation passed: ${photoBytes.length} bytes',
      );

      // Upload bytes using uploadBinary to verification-photos bucket
      debugPrint(
        '📤 VERIFICATION: Attempting upload to verification-photos bucket...',
      );
      try {
        // First try to delete any existing verification photo for this user
        debugPrint(
          '🗑️ VERIFICATION: Removing any existing verification photo...',
        );
        try {
          await _supabase.storage.from('verification-photos').remove([
            fileName,
          ]);
          debugPrint(
            '✅ VERIFICATION: Existing photo removed (or didn\'t exist)',
          );
        } catch (deleteError) {
          // Ignore delete errors - file might not exist
          debugPrint(
            'ℹ️ VERIFICATION: No existing photo to remove (this is normal for first upload)',
          );
        }

        // Now upload the new photo
        await _supabase.storage
            .from('verification-photos')
            .uploadBinary(fileName, photoBytes);
        debugPrint(
          '✅ VERIFICATION: Upload to verification-photos bucket successful',
        );
      } catch (uploadError) {
        debugPrint(
          '❌ VERIFICATION: Upload to verification-photos bucket failed: $uploadError',
        );
        debugPrint('🔍 VERIFICATION: Error type: ${uploadError.runtimeType}');
        debugPrint(
          '🔍 VERIFICATION: Error toString: ${uploadError.toString()}',
        );

        // Check if it's a StorageException and get more details
        if (uploadError is StorageException) {
          debugPrint('🔍 VERIFICATION: StorageException details:');
          debugPrint('   - Message: ${uploadError.message}');
          debugPrint('   - Status Code: ${uploadError.statusCode}');
          debugPrint('   - Error: ${uploadError.error}');
        }

        rethrow; // Re-throw to be caught by outer try-catch
      }

      debugPrint('🤖 VERIFICATION: Triggering AI face comparison...');
      await _compareVerificationPhotos(
        userId,
        verificationPhotoPath: fileName,
        gestureCode: gestureCode,
        gesturePrompt: gesturePrompt,
      );

      debugPrint(
        '🎉 VERIFICATION: Verification photo submission completed successfully',
      );
      return fileName;
    } catch (e) {
      debugPrint('❌ VERIFICATION: Failed to submit verification photo: $e');
      debugPrint('🔍 VERIFICATION: Error type: ${e.runtimeType}');
      debugPrint('🔍 VERIFICATION: Error toString: ${e.toString()}');
      debugPrint('🔍 VERIFICATION: Stack trace: ${StackTrace.current}');
      throw Exception('Failed to submit verification photo: $e');
    }
  }

  Future<void> _compareVerificationPhotos(
    String userId, {
    required String verificationPhotoPath,
    String? gestureCode,
    String? gesturePrompt,
  }) async {
    debugPrint('🤖 VERIFICATION: Starting AI comparison for user $userId');

    try {
      debugPrint(
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

      debugPrint(
        '📡 VERIFICATION: Edge function response status: ${response.status}',
      );

      if (response.status != 200) {
        debugPrint(
          '❌ VERIFICATION: Edge function returned non-200 status: ${response.status}',
        );
        debugPrint('🔍 VERIFICATION: Response data: ${response.data}');
        throw Exception('AI comparison failed: ${response.status}');
      }

      debugPrint('🎉 VERIFICATION: AI comparison processing completed');
    } catch (e) {
      debugPrint('❌ VERIFICATION: Error in AI comparison: $e');
      debugPrint('🔍 VERIFICATION: Error type: ${e.runtimeType}');
      debugPrint('🔍 VERIFICATION: Stack trace: ${StackTrace.current}');
      rethrow;
    }
  }

  /// Get verification status for a user
  Future<Map<String, dynamic>?> getVerificationStatus(String userId) async {
    try {
      final response =
          await _supabase
              .from('users')
              .select(
                'is_verified, verification_status, verification_submitted_at, verification_reviewed_at, verification_similarity_score, verification_auto_rejected, verification_ai_analysis',
              )
              .eq('id', userId)
              .maybeSingle();

      return response;
    } catch (e) {
      debugPrint('Error getting verification status: $e');
      return null;
    }
  }

  /// Check if user is verified
  Future<bool> isUserVerified(String userId) async {
    try {
      final status = await getVerificationStatus(userId);
      return status?['is_verified'] == true;
    } catch (e) {
      debugPrint('Error checking verification status: $e');
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
      debugPrint('Error getting verification photo URL: $e');
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
      debugPrint('Error getting pending verifications: $e');
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
      debugPrint(
        '✅ VERIFICATION: Deleted verification photo from verification-photos bucket: $normalized',
      );
    } catch (e) {
      debugPrint('Error deleting verification photo: $e');
    }
  }

  /// Fetch privacy notice text (optionally localized) from the `translations` table.
  /// Prefers the supplied locale and falls back to 'en' if not found. Returns null
  /// when no DB translation is available (caller should fall back to built-in string).
  Future<String?> getPrivacyNotice(String locale) async {
    try {
      // Try locale-specific entry first
      final res = await _supabase
          .from('translations')
          .select('value')
          .eq('key', 'verificationPrivacyNotice')
          .eq('locale', locale)
          .maybeSingle();

      if (res != null && res['value'] != null) {
        final v = res['value'];
        if (v is String && v.isNotEmpty) return v;
      }

      // Fallback to English
      if (locale != 'en') {
        final resEn = await _supabase
            .from('translations')
            .select('value')
            .eq('key', 'verificationPrivacyNotice')
            .eq('locale', 'en')
            .maybeSingle();
        if (resEn != null && resEn['value'] != null) {
          final v = resEn['value'];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (e) {
      debugPrint('⚠️ VERIFICATION: Unable to fetch privacy notice from translations table: $e');
    }
    return null;
  }
}
