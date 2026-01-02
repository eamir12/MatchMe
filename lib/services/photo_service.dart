// lib/services/photo_service.dart
// Utility service to handle photo upload + download to/from Supabase storage.
//
// This service delegates to ProfileEditRequestService for robust upload handling.

import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/profile_request_service.dart';

class PhotoService {
  final Ref ref;
  PhotoService(this.ref);

  Future<String?> uploadPhotoBytes(String path, Uint8List bytes, {bool public = true}) async {
    final uploader = ref.read(profileEditRequestServiceProvider);
    final url = await uploader.uploadBytesToStorage(path, bytes, public: public);
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
}

final photoServiceProvider = Provider((ref) => PhotoService(ref));
