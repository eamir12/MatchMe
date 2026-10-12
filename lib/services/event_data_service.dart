// lib/services/event_data_service.dart
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// We no longer need ML Kit here
// import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

final supabase = Supabase.instance.client;
const uuid = Uuid();

// Define the structure for extracted data
class ExtractedEventData {
  final String name;
  final String? venue;
  final DateTime? date;
  final String? dateString;

  ExtractedEventData({
    required this.name,
    this.venue,
    this.date,
    this.dateString,
  });

  factory ExtractedEventData.empty() => ExtractedEventData(name: '');
}

final eventDataServiceProvider = Provider((ref) => EventDataService());

class EventDataService {
  final String _bucketId = 'event-uploads';

  // --- NEW: File Upload & Process Logic ---
  Future<ExtractedEventData?> uploadAndProcessFile() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) throw Exception("User not logged in");

    try {
      // file_picker 12.x: pickFile returns PlatformFile? (null = cancelled).
      // Web loads bytes by default; mobile returns a temp file path.
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      );

      // If the user cancelled the file picker, return null so callers can
      // treat that as a non-error cancellation and simply close any UI.
      if (file == null) {
        return null; // User cancelled
      }
      final fileExt = file.extension?.toLowerCase() ?? 'file';
      final fileName = '${uuid.v4()}.$fileExt';
      final filePath = '$userId/$fileName';
      final mimeType = _getMimeType(fileExt);

      // 1. UPLOAD the file (with improved error handling/logging)
      try {
        if (kIsWeb) {
          await supabase.storage
              .from(_bucketId)
              .uploadBinary(
                filePath,
                await file.readAsBytes(),
                fileOptions: FileOptions(contentType: mimeType),
              );
        } else {
          if (file.path == null) {
            throw Exception("File path is null on mobile.");
          }
          await supabase.storage
              .from(_bucketId)
              .upload(
                filePath,
                File(file.path!),
                fileOptions: FileOptions(contentType: mimeType),
              );
        }
      } catch (e) {
        // Surface helpful diagnostic info for storage policy / auth failures
        print(
          '[EVENT_UPLOAD] Upload failed for $filePath (bucket=$_bucketId): $e',
        );
        // If it's a StorageException from Supabase, rethrow with clearer message
        if (e is StorageException) {
          final msg = 'Storage upload failed: ${e.message}';
          throw Exception(msg);
        }
        rethrow;
      }

      // 2. CALL the function and wait for the JSON response
      final response = await supabase.functions.invoke(
        'process-event-file',
        body: {'filePath': filePath, 'bucketId': _bucketId},
      );

      if (response.data != null) {
        final body = response.data;
        DateTime? parsedDate;
        if (body['date'] != null) {
          parsedDate = DateTime.tryParse(body['date']);
        }
        return ExtractedEventData(
          name: body['title'] ?? 'Event from File',
          venue: body['location'],
          date: parsedDate,
          dateString: body['dateString'],
        );
      } else {
        throw Exception("Function returned no data.");
      }
    } catch (e) {
      // If the file picker threw an exception that indicates a user cancel action,
      // treat it as a cancellation and return null instead of surfacing an error.
      final msg = e.toString().toLowerCase();
      if (msg.contains('cancel') ||
          msg.contains('abort') ||
          msg.contains('user canceled') ||
          msg.contains('user cancelled')) {
        return null;
      }
      rethrow;
    }
  }
  // --- END NEW ---

  /// Process a file from a local file path (used for shared files from Android)
  Future<ExtractedEventData> uploadAndProcessLocalFile(String localPath) async {
    if (kIsWeb) {
      throw Exception('Local file upload is not supported on web.');
    }

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) throw Exception("User not logged in");

    final fileOnDisk = File(localPath);
    if (!await fileOnDisk.exists()) {
      throw Exception('File not found.');
    }

    final dot = localPath.lastIndexOf('.');
    final fileExt = (dot >= 0 && dot < localPath.length - 1)
        ? localPath.substring(dot + 1).toLowerCase()
        : 'file';

    final fileName = '${uuid.v4()}.$fileExt';
    final filePath = '$userId/$fileName';
    final mimeType = _getMimeType(fileExt);

    try {
      await supabase.storage
          .from(_bucketId)
          .upload(
            filePath,
            fileOnDisk,
            fileOptions: FileOptions(contentType: mimeType),
          );
    } catch (e) {
      print(
        '[EVENT_UPLOAD] Upload failed for $filePath (bucket=$_bucketId): $e',
      );
      if (e is StorageException) {
        final msg = 'Storage upload failed: ${e.message}';
        throw Exception(msg);
      }
      rethrow;
    }

    final response = await supabase.functions.invoke(
      'process-event-file',
      body: {'filePath': filePath, 'bucketId': _bucketId},
    );

    if (response.data != null) {
      final body = response.data;
      DateTime? parsedDate;
      if (body['date'] != null) {
        parsedDate = DateTime.tryParse(body['date']);
      }
      return ExtractedEventData(
        name: body['title'] ?? 'Event from File',
        venue: body['location'],
        date: parsedDate,
        dateString: body['dateString'],
      );
    }

    throw Exception("Function returned no data.");
  }

  // Helper to get MIME type from extension
  String _getMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }

  // --- URL Parsing Logic - Using CORS proxy (no AI, no quotas) ---
  Future<ExtractedEventData> extractFromUrl(String url) async {
    if (!url.startsWith('http')) return ExtractedEventData.empty();

    try {
      // Use Supabase Edge Function as CORS proxy (no AI, just HTML fetching)
      final response = await supabase.functions.invoke(
        'get-event-metadata',
        body: {'url': url},
      );

      if (response.data != null) {
        final data = response.data as Map<String, dynamic>;

        DateTime? parsedDate;
        if (data['date'] != null) {
          parsedDate = DateTime.tryParse(data['date']);
        }

        if (data['title'] != null && (data['title'] as String).isNotEmpty) {
          return ExtractedEventData(
            name: data['title'],
            venue: data['location'],
            date: parsedDate,
            dateString: data['dateString'],
          );
        }
      }
    } catch (e) {
      // Don't rethrow - return empty so manual input still works
    }

    // Return empty if extraction failed
    return ExtractedEventData.empty();
  }

  // We no longer need the client-side OCR method
  // Future<ExtractedEventData> extractFromImage() async { ... }
}
