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

  ExtractedEventData({required this.name, this.venue, this.date, this.dateString});

  factory ExtractedEventData.empty() => ExtractedEventData(name: '');
}

final eventDataServiceProvider = Provider((ref) => EventDataService());

class EventDataService {
  final String _bucketId = 'event-uploads';

  // --- NEW: File Upload & Process Logic ---
  Future<ExtractedEventData> uploadAndProcessFile() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) throw Exception("User not logged in");

    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'], 
        allowMultiple: false,
        withData: kIsWeb,
      );

      if (result == null) {
        return ExtractedEventData.empty(); // User cancelled
      }

      final file = result.files.single;
      final fileExt = file.extension?.toLowerCase() ?? 'file';
      final fileName = '${uuid.v4()}.$fileExt';
      final filePath = '$userId/$fileName';
      final mimeType = _getMimeType(fileExt);

      // 1. UPLOAD the file
      if (kIsWeb) {
        if (file.bytes == null) throw Exception("File bytes are null on web.");
        await supabase.storage
          .from(_bucketId)
          .uploadBinary(
            filePath,
            file.bytes!,
            fileOptions: FileOptions(contentType: mimeType),
          );
      } else {
        if (file.path == null) throw Exception("File path is null on mobile.");
        await supabase.storage
          .from(_bucketId)
          .upload(
            filePath,
            File(file.path!),
            fileOptions: FileOptions(contentType: mimeType),
          );
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
      rethrow;
    }
  }
  // --- END NEW ---

  // Helper to get MIME type from extension
  String _getMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf': return 'application/pdf';
      case 'png': return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      default: return 'application/octet-stream'; 
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
