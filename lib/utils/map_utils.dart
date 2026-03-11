// lib/utils/map_utils.dart
import 'package:url_launcher/url_launcher.dart';

/// Opens Google Maps with the given location address
/// Returns true if successful, false otherwise
Future<bool> openGoogleMaps(String address) async {
  if (address.isEmpty) return false;
  
  // URL encode the address for Google Maps
  final encodedAddress = Uri.encodeComponent(address);
  
  try {
    // Try Google Maps app first (works on mobile)
    final googleMapsUrl = Uri.parse('https://www.google.com/maps/search/?api=1&query=$encodedAddress');

    // Check if we can launch the URL
    if (await canLaunchUrl(googleMapsUrl)) {
      await launchUrl(
        googleMapsUrl,
        mode: LaunchMode.externalApplication,
      );
      return true;
    }

    // If canLaunchUrl returns false (e.g., due to Android restrictions),
    // try launching directly as a fallback
    try {
      await launchUrl(
        googleMapsUrl,
        mode: LaunchMode.externalApplication,
      );
      return true;
    } catch (_) {
      // If direct launch also fails, continue to fallback
    }

    return false;
  } catch (e) {
    // If Google Maps URL fails, try a fallback
    try {
      final fallbackUrl = Uri.parse('https://maps.google.com/?q=$encodedAddress');
      if (await canLaunchUrl(fallbackUrl)) {
        await launchUrl(
          fallbackUrl,
          mode: LaunchMode.externalApplication,
        );
        return true;
      }
    } catch (_) {
      // Ignore fallback errors
    }
    return false;
  }
}

