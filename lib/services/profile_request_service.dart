// lib/services/profile_request_service.dart
// Robust upload helpers and request submission service.
//
// Notes:
// - Tries several upload methods supported by different Supabase Flutter SDK versions.
// - Ensures uploads go to the 'profile-photos' bucket and returns the object path
//   (so callers store the path and we can generate signed URLs on demand).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';

final supabaseClient = Supabase.instance.client;

/// Service to submit profile-edit requests; supports attachments upload.
class ProfileEditRequestService {
  final Ref ref;
  ProfileEditRequestService(this.ref);

  /// Upload raw bytes to storage bucket and return the object path (e.g. "userId/12345.jpg").
  /// - path: relative path in bucket (e.g. 'userId/12345_doc.jpg')
  /// - This function returns the object path on success, or null on failure.
  /// - Callers should persist the returned object path (NOT a signed URL).
  Future<String?> uploadBytesToStorage(String path, Uint8List bytes, {bool public = false}) async {
    // Security: Validate file size (max 5MB)
    const maxSize = 5 * 1024 * 1024; // 5MB
    if (bytes.length > maxSize) {
      throw Exception('File too large. Maximum size is 5MB.');
    }

    // Security: Validate file type by checking magic bytes
    if (!_isValidImage(bytes)) {
      throw Exception('Invalid file type. Only JPEG, PNG, GIF images are allowed.');
    }

    // Use the canonical profile photos bucket used across the app.
    final bucket = 'profile-photos';

    // Ensure no leading slash on path
    if (path.startsWith('/')) {
      path = path.replaceFirst('/', '');
    }

    // Upload bytes using uploadBinary (Uint8List compatible)
    try {
      await supabaseClient.storage.from(bucket).uploadBinary(path, bytes);
    } catch (e) {
      // Upload failed
      debugPrint('Photo upload failed for path $path: $e');
      return null;
    }

    // Return the object path so caller stores "userId/filename.ext"
    return path;
  }

  /// Validate if bytes represent a valid image (JPEG, PNG, GIF)
  bool _isValidImage(Uint8List bytes) {
    if (bytes.length < 4) return false;

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;

    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;

    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) return true;

    return false;
  }

  /// Submit a profile-edit request without attachments.
  Future<bool> submitRequest(String userId, List<String> requestedFields, String message) async {
    final requestData = {
      'user_id': userId,
      'requested_fields': requestedFields,
      'message': message,
      'status': 'pending',
    };

    // Check connectivity
    final connectivityAsync = ref.read(connectivityProvider);
    final isOnline = connectivityAsync.value ?? false;

    if (isOnline) {
      try {
        await supabaseClient.from('profile_edit_requests').insert(requestData);
        return true;
      } catch (e) {
        // If online but request fails, store locally for later sync
        await _storeRequestLocally(requestData);
        return true; // Return true since we stored it locally
      }
    } else {
      // Store locally when offline
      await _storeRequestLocally(requestData);
      return true;
    }
  }

  /// Submit with explicit attachments list (each attachment is a map with name/url/size)
  Future<bool> submitRequestWithAttachments(String userId, List<String> requestedFields, String message, List<Map<String, dynamic>> attachments) async {
    final requestData = {
      'user_id': userId,
      'requested_fields': requestedFields,
      'message': message,
      'status': 'pending',
      'attachments': attachments,
    };

    // Check connectivity
    final connectivityAsync = ref.read(connectivityProvider);
    final isOnline = connectivityAsync.value ?? false;

    if (isOnline) {
      try {
        await supabaseClient.from('profile_edit_requests').insert(requestData);
        return true;
      } catch (e) {
        // If online but request fails, store locally for later sync
        await _storeRequestLocally(requestData);
        return true; // Return true since we stored it locally
      }
    } else {
      // Store locally when offline
      await _storeRequestLocally(requestData);
      return true;
    }
  }

  /// Store profile edit request locally in the outbox for later sync
  Future<void> _storeRequestLocally(Map<String, dynamic> requestData) async {
    try {
      final localDb = ref.read(localDbProvider);
      // Add type to identify this as a profile edit request
      final outboxData = {
        'type': 'profile_edit_requests',
        ...requestData,
      };
      await localDb.saveMessageToOutbox(outboxData);
    } catch (e) {
      debugPrint('Failed to store profile edit request locally: $e');
    }
  }
}

final profileEditRequestServiceProvider = Provider((ref) => ProfileEditRequestService(ref));
