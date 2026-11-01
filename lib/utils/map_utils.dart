// lib/utils/map_utils.dart
import 'package:url_launcher/url_launcher.dart';

/// Builds the Google Maps URL that opens a named place. When a Google place id
/// is known the URL lands on that place's own card; without one it falls back
/// to a name search anchored at the coordinates.
Uri googleMapsPlaceUri({
  required String label,
  String? placeId,
  double? latitude,
  double? longitude,
}) {
  final id = placeId?.trim() ?? '';
  if (id.isNotEmpty) {
    return Uri.parse(
      'https://www.google.com/maps/search/?api=1'
      '&query=${Uri.encodeComponent(label)}'
      '&query_place_id=${Uri.encodeComponent(id)}',
    );
  }
  final query = (latitude != null && longitude != null)
      ? '$label $latitude,$longitude'
      : label;
  return Uri.parse(
    'https://www.google.com/maps/search/?api=1'
    '&query=${Uri.encodeComponent(query)}',
  );
}

/// Opens Google Maps on the given place, preferring the exact place card.
Future<bool> openGoogleMapsPlace({
  required String label,
  String? placeId,
  double? latitude,
  double? longitude,
}) async {
  if (label.trim().isEmpty && (placeId?.trim().isEmpty ?? true)) return false;
  return _launchExternal(
    googleMapsPlaceUri(
      label: label.trim(),
      placeId: placeId,
      latitude: latitude,
      longitude: longitude,
    ),
  );
}

/// Opens Google Maps with the given location address
/// Returns true if successful, false otherwise
Future<bool> openGoogleMaps(String address) async {
  if (address.isEmpty) return false;

  // URL encode the address for Google Maps
  final encodedAddress = Uri.encodeComponent(address);

  // Try Google Maps app first (works on mobile)
  final googleMapsUrl = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$encodedAddress',
  );

  // Check if we can launch the URL
  if (await canLaunchUrl(googleMapsUrl)) {
    await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
    return true;
  }

  // If canLaunchUrl returns false (e.g., due to Android restrictions),
  // try launching directly as a fallback
  try {
    await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
    return true;
  } catch (_) {
    // If direct launch also fails, continue to fallback
  }

  // If Google Maps URL fails, try a fallback
  final fallbackUrl = Uri.parse('https://maps.google.com/?q=$encodedAddress');
  if (await canLaunchUrl(fallbackUrl)) {
    await launchUrl(fallbackUrl, mode: LaunchMode.externalApplication);
    return true;
  }
  return false;
}

Future<bool> _launchExternal(Uri uri) async {
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    } catch (_) {
      return false;
    }
  } catch (_) {
    return false;
  }
}
