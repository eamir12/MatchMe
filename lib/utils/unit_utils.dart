// lib/utils/unit_utils.dart

import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:flutter/foundation.dart';

/// Determines if the given country code uses imperial units (feet, miles) or metric (meters, kilometers).
bool usesImperialUnitsByCountry(String countryCode) {
  // Countries that primarily use imperial units
  const imperialCountries = {
    'US', // United States
    'LR', // Liberia
    'MM', // Myanmar
  };

  return imperialCountries.contains(countryCode);
}

/// Determines if coordinates are within a country that uses imperial units
/// This is a fallback when geocoding fails
bool coordinatesInImperialCountry(double latitude, double longitude) {
  // United States (approximate bounding box)
  if (longitude >= -125 && longitude <= -67 && latitude >= 24 && latitude <= 49) {
    return true;
  }
  
  // Liberia
  if (longitude >= -11 && longitude <= -7 && latitude >= 4 && latitude <= 9) {
    return true;
  }
  
  // Myanmar
  if (longitude >= 92 && longitude <= 101 && latitude >= 9 && latitude <= 29) {
    return true;
  }
  
  return false; // Default to metric
}

/// Converts meters to feet
double metersToFeet(double meters) => meters * 3.28084;

/// Converts meters to miles
double metersToMiles(double meters) => meters / 1609.344;

/// Gets the country code from a specific position (useful for using stored login location)
Future<String?> getCountryCodeFromPosition(Position position) async {
  try {
    debugPrint('Using stored position: ${position.latitude}, ${position.longitude}');

    // Try reverse geocoding first
    try {
      debugPrint('Reverse geocoding stored position...');
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final countryCode = placemarks.first.isoCountryCode;
        debugPrint('Country code from stored position: $countryCode');
        return countryCode;
      } else {
        debugPrint('No placemarks found for stored position');
      }
    } catch (geocodingError) {
      debugPrint('Geocoding failed for stored position: $geocodingError, falling back to coordinate detection');
    }

    // Fallback: use coordinate-based detection
    final imperialFromCoords = coordinatesInImperialCountry(position.latitude, position.longitude);
    debugPrint('Using coordinate-based detection for stored position: Imperial=$imperialFromCoords');
    
    // Return a pseudo country code for imperial countries, null for metric
    return imperialFromCoords ? 'US' : null; // US as representative imperial country
    
  } catch (e) {
    debugPrint('Error getting country from stored position: $e');
    return null;
  }
}

/// Gets the country code from the user's current location
Future<String?> getCountryCodeFromLocation() async {
  try {
    // Check location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    debugPrint('Location permission: $permission');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      debugPrint('Location permission after request: $permission');
      if (permission == LocationPermission.denied) {
        debugPrint('Location permission denied');
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('Location permission denied forever');
      return null;
    }

    // Get current position
    debugPrint('Getting current position...');
    Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
      ),
    );
    debugPrint('Position obtained: ${position.latitude}, ${position.longitude}');

    // Try reverse geocoding first
    try {
      debugPrint('Reverse geocoding...');
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final countryCode = placemarks.first.isoCountryCode;
        debugPrint('Country code from location: $countryCode');
        return countryCode;
      } else {
        debugPrint('No placemarks found');
      }
    } catch (geocodingError) {
      debugPrint('Geocoding failed: $geocodingError, falling back to coordinate detection');
    }

    // Fallback: use coordinate-based detection
    final imperialFromCoords = coordinatesInImperialCountry(position.latitude, position.longitude);
    debugPrint('Using coordinate-based detection: Imperial=$imperialFromCoords');
    
    // Return a pseudo country code for imperial countries, null for metric
    return imperialFromCoords ? 'US' : null; // US as representative imperial country
    
  } catch (e) {
    debugPrint('Error getting country from location: $e');
    return null;
  }
}

/// Gets the appropriate unit string for distance
String getDistanceUnit(LocalizationState l10n) {
  return usesImperialUnitsByCountry(l10n.currentLocale.countryCode ?? '') ? l10n.getString('unitFeet') : l10n.getString('unitMeters');
}

/// Formats a distance value with the appropriate unit for the locale
/// Input value is expected to be in meters
String formatDistance(double metersValue, LocalizationState l10n) {
  return formatDistanceWithImperial(metersValue, usesImperialUnitsByCountry(l10n.currentLocale.countryCode ?? ''), l10n);
}

/// Formats a distance value with the specified unit system
/// Input value is expected to be in meters
String formatDistanceWithImperial(double metersValue, bool useImperial, LocalizationState l10n) {
  if (useImperial) {
    // Use feet for small distances and miles for larger ones.
    final feet = metersToFeet(metersValue);
    if (feet >= 5280) {
      final miles = metersToMiles(metersValue);
      final milesStr = miles.toStringAsFixed(miles < 10 ? 1 : 0);
      return '$milesStr ${l10n.getString('unitMiles')}';
    }
    final roundedFeet = ((feet / 5).round()) * 5;
    return '$roundedFeet ${l10n.getString('unitFeet')}';
  } else {
    // Use meters for small distances and kilometers for larger ones.
    if (metersValue >= 1000) {
      final km = metersValue / 1000.0;
      final kmStr = km.toStringAsFixed(km < 10 ? 1 : 0);
      return '$kmStr ${l10n.getString('unitKilometers')}';
    }
    return '${metersValue.round()} ${l10n.getString('unitMeters')}';
  }
}