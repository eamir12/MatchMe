// lib/services/profile_request_service.dart
// Robust upload helpers and request submission service.
//
// Notes:
// - Tries several upload methods supported by different Supabase Flutter SDK versions.
// - Ensures uploads go to the 'profile-photos' bucket and returns the object path
//   (so callers store the path and we can generate signed URLs on demand).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';

final supabaseClient = Supabase.instance.client;

class ProfileEditAttachmentException implements Exception {
  final String key;
  final Map<String, String>? params;
  const ProfileEditAttachmentException(this.key, {this.params});
}

/// Service to submit profile-edit requests; supports attachments upload.
class ProfileEditRequestService {
  final Ref ref;
  ProfileEditRequestService(this.ref);

  /// Upload raw bytes to storage bucket and return the object path (e.g. "userId/12345.jpg").
  /// - path: relative path in bucket (e.g. 'userId/12345_doc.jpg')
  /// - This function returns the object path on success, or null on failure.
  /// - Callers should persist the returned object path (NOT a signed URL).
  Future<String?> uploadBytesToStorage(
    String path,
    Uint8List bytes, {
    bool public = false,
    String bucket = 'profile-photos',
  }) async {
    final ext = _extensionFromPath(path);
    final allowedTypesText = bucket == 'profile-edit-attachments'
        ? 'jpg, jpeg, png, pdf, doc, docx, xls, xlsx, ppt, pptx'
        : 'jpg, jpeg, png, gif';
    final isAllowed = bucket == 'profile-edit-attachments'
        ? _isAllowedAttachmentExtension(ext)
        : _isAllowedImageExtension(ext);
    if (!isAllowed) {
      throw ProfileEditAttachmentException(
        'profileEditAttachmentInvalidType',
        params: {'types': allowedTypesText},
      );
    }

    if (!_matchesMagicForExtension(ext, bytes)) {
      throw ProfileEditAttachmentException(
        'profileEditAttachmentInvalidType',
        params: {'types': allowedTypesText},
      );
    }

    // Ensure no leading slash on path
    if (path.startsWith('/')) {
      path = path.replaceFirst('/', '');
    }

    // Compress images for the profile-photos bucket
    if (bucket == 'profile-photos') {
      bytes = await _compressImage(bytes);
    }

    // Upload bytes using uploadBinary (Uint8List compatible)
    try {
      final contentType = _contentTypeForExtension(ext);
      await supabaseClient.storage
          .from(bucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              contentType: contentType ?? 'application/octet-stream',
            ),
          )
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      // Upload failed
      print('Photo upload failed for path $path: $e');
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
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }

    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }

    return false;
  }

  static String _extensionFromPath(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot <= 0 || lastDot >= path.length - 1) return '';
    return path.substring(lastDot + 1).toLowerCase().trim();
  }

  static bool _isAllowedImageExtension(String ext) {
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' => true,
      _ => false,
    };
  }

  static bool _isAllowedAttachmentExtension(String ext) {
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' => true,
      'pdf' => true,
      'doc' || 'xls' || 'ppt' => true,
      'docx' || 'xlsx' || 'pptx' => true,
      _ => false,
    };
  }

  bool _matchesMagicForExtension(String ext, Uint8List bytes) {
    if (bytes.isEmpty) return false;
    if (ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'gif') {
      return _isValidImage(bytes);
    }
    if (ext == 'pdf') {
      if (bytes.length < 4) return false;
      return bytes[0] == 0x25 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x44 &&
          bytes[3] == 0x46;
    }
    if (ext == 'doc' || ext == 'xls' || ext == 'ppt') {
      if (bytes.length < 8) return false;
      return bytes[0] == 0xD0 &&
          bytes[1] == 0xCF &&
          bytes[2] == 0x11 &&
          bytes[3] == 0xE0 &&
          bytes[4] == 0xA1 &&
          bytes[5] == 0xB1 &&
          bytes[6] == 0x1A &&
          bytes[7] == 0xE1;
    }
    if (ext == 'docx' || ext == 'xlsx' || ext == 'pptx') {
      if (bytes.length < 4) return false;
      final isZip =
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
          (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
      return isZip;
    }
    return false;
  }

  static String? _contentTypeForExtension(String ext) {
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' =>
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      _ => null,
    };
  }

  Future<Uint8List> _compressImage(Uint8List original) async {
    try {
      return await compute(_compressImageSync, original);
    } catch (e) {
      debugPrint('Image compression failed: $e');
      return original;
    }
  }

  /// Submit a profile-edit request without attachments.
  Future<bool> submitRequest(
    String userId,
    List<String> requestedFields,
    String message,
  ) async {
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
        if (e.toString().contains('profile_edit_request_already_pending')) {
          return false;
        }
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
  Future<bool> submitRequestWithAttachments(
    String userId,
    List<String> requestedFields,
    String message,
    List<Map<String, dynamic>> attachments,
  ) async {
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
        if (e.toString().contains('profile_edit_request_already_pending')) {
          return false;
        }
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
      final outboxData = {'type': 'profile_edit_requests', ...requestData};
      await localDb.saveMessageToOutbox(outboxData);
    } catch (e) {
      print('Failed to store profile edit request locally: $e');
    }
  }
}

Uint8List _compressImageSync(Uint8List original) {
  try {
    final image = img.decodeImage(original);
    if (image == null) return original;

    img.Image target = image;
    if (target.width > 1200 || target.height > 1200) {
      if (target.width >= target.height) {
        target = img.copyResize(target, width: 1200);
      } else {
        target = img.copyResize(target, height: 1200);
      }
    }

    return Uint8List.fromList(img.encodeJpg(target, quality: 85));
  } catch (e) {
    debugPrint('Image compression failed: $e');
    return original;
  }
}

final profileEditRequestServiceProvider = Provider(
  (ref) => ProfileEditRequestService(ref),
);
