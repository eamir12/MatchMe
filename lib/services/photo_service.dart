// lib/services/photo_service.dart
// Utility service to handle photo upload + download to/from Supabase storage.
//
// This service delegates to ProfileEditRequestService for robust upload handling.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/profile_request_service.dart';

class LocalPhotoPresenceResult {
  final bool supported;
  final bool containsFace;
  final bool containsBody;
  final bool uncertain;
  final double faceConfidence;
  final double bodyConfidence;

  const LocalPhotoPresenceResult({
    required this.supported,
    required this.containsFace,
    required this.containsBody,
    required this.uncertain,
    required this.faceConfidence,
    required this.bodyConfidence,
  });

  bool get hasPersonSignals => containsFace || containsBody;

  factory LocalPhotoPresenceResult.unsupported() {
    return const LocalPhotoPresenceResult(
      supported: false,
      containsFace: false,
      containsBody: false,
      uncertain: true,
      faceConfidence: 0,
      bodyConfidence: 0,
    );
  }

  factory LocalPhotoPresenceResult.fromMap(Map<Object?, Object?> map) {
    double toDouble(Object? value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    return LocalPhotoPresenceResult(
      supported: map['supported'] == true,
      containsFace: map['containsFace'] == true,
      containsBody: map['containsBody'] == true,
      uncertain: map['uncertain'] != false,
      faceConfidence: toDouble(map['faceConfidence']),
      bodyConfidence: toDouble(map['bodyConfidence']),
    );
  }
}

class PhotoService {
  static const MethodChannel _photoModerationChannel = MethodChannel(
    'matchme/photo_moderation',
  );

  final Ref ref;
  PhotoService(this.ref);

  Future<String?> uploadPhotoBytes(
    String path,
    Uint8List bytes, {
    bool public = true,
  }) async {
    final uploader = ref.read(profileEditRequestServiceProvider);
    final url = await uploader.uploadBytesToStorage(
      path,
      bytes,
      public: public,
    );
    return url;
  }

  /// Download remote image to bytes
  Future<Uint8List?> downloadImageBytes(String url) async {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return resp.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  Future<LocalPhotoPresenceResult> analyzeLocalProfilePhotoPresence(
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty) {
      return LocalPhotoPresenceResult.unsupported();
    }
    if (kIsWeb || Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return LocalPhotoPresenceResult.unsupported();
    }

    try {
      final result = await _photoModerationChannel
          .invokeMapMethod<Object?, Object?>('analyzeProfilePhotoPresence', {
            'bytes': bytes,
          });
      if (result == null) {
        return LocalPhotoPresenceResult.unsupported();
      }
      return LocalPhotoPresenceResult.fromMap(result);
    } catch (_) {
      return LocalPhotoPresenceResult.unsupported();
    }
  }
}

final photoServiceProvider = Provider((ref) => PhotoService(ref));
