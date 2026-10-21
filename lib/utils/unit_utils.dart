// lib/utils/unit_utils.dart

import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/windows_location_channel.dart';
import 'package:flutter/foundation.dart';
import '../web_imports.dart' as html;

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
  if (longitude >= -125 &&
      longitude <= -67 &&
      latitude >= 24 &&
      latitude <= 49) {
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
    // Try reverse geocoding first
    try {
      List<Placemark> placemarks = await Geocoding().placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        return placemarks.first.isoCountryCode;
      }
    } catch (_) {
      // Fall back to coordinate detection
    }

    // Fallback: use coordinate-based detection
    final imperialFromCoords = coordinatesInImperialCountry(
      position.latitude,
      position.longitude,
    );

    // Return a pseudo country code for imperial countries, null for metric
    return imperialFromCoords
        ? 'US'
        : null; // US as representative imperial country
  } catch (e) {
    return null;
  }
}

/// Gets the country code from the user's current location
Future<String?> getCountryCodeFromLocation() async {
  try {
    // Check location permissions
    LocationPermission permission = await WindowsLocationChannel.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await WindowsLocationChannel.requestPermission();
      if (permission == LocationPermission.denied) {
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return null;
    }

    // Get current position
    Position? position;
    if (kIsWeb) {
      final completer = Completer<Position?>();
      try {
        html.window.navigator.geolocation.getCurrentPosition(
          (pos) {
            if (completer.isCompleted) return;
            final coords = pos.coords;
            final lat = coords.latitude;
            final lon = coords.longitude;
            if (lat == null || lon == null) {
              completer.complete(null);
              return;
            }

            final timestamp = pos.timestamp == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(pos.timestamp!);

            completer.complete(
              Position(
                latitude: lat,
                longitude: lon,
                timestamp: timestamp,
                accuracy: coords.accuracy ?? double.infinity,
                altitude: coords.altitude ?? 0.0,
                altitudeAccuracy: coords.altitudeAccuracy ?? 0.0,
                heading: coords.heading ?? 0.0,
                headingAccuracy: coords.headingAccuracy ?? 0.0,
                speed: coords.speed ?? 0.0,
                speedAccuracy: coords.speedAccuracy ?? 0.0,
              ),
            );
          },
          (code, message) {
            if (completer.isCompleted) return;
            completer.complete(null);
          },
          const html.WebGeolocationOptions(
            enableHighAccuracy: false,
            maximumAge: 0,
            timeout: 15000,
          ),
        );
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }

      position = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          if (!completer.isCompleted) completer.complete(null);
          return null;
        },
      );
    } else {
      position = await WindowsLocationChannel.getPosition(
        accuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 5),
      );
      if (position == null) return null;
    }
    if (position == null) return null;

    // Try reverse geocoding first
    try {
      List<Placemark> placemarks = await Geocoding().placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        return placemarks.first.isoCountryCode;
      }
    } catch (_) {
      // Fall back to coordinate detection
    }

    // Fallback: use coordinate-based detection
    final imperialFromCoords = coordinatesInImperialCountry(
      position.latitude,
      position.longitude,
    );

    // Return a pseudo country code for imperial countries, null for metric
    return imperialFromCoords
        ? 'US'
        : null; // US as representative imperial country
  } catch (e) {
    return null;
  }
}

/// Gets the appropriate unit string for distance
String getDistanceUnit(LocalizationState l10n) {
  return usesImperialUnitsByCountry(l10n.currentLocale.countryCode ?? '')
      ? l10n.getString('unitFeet')
      : l10n.getString('unitMeters');
}

/// Formats a distance value with the appropriate unit for the locale
/// Input value is expected to be in meters
String formatDistance(double metersValue, LocalizationState l10n) {
  return formatDistanceWithImperial(
    metersValue,
    usesImperialUnitsByCountry(l10n.currentLocale.countryCode ?? ''),
    l10n,
  );
}

/// Formats a distance value with the specified unit system
/// Input value is expected to be in meters
String formatDistanceWithImperial(
  double metersValue,
  bool useImperial,
  LocalizationState l10n,
) {
  if (useImperial) {
    // Use feet for small distances and miles for larger ones.
    final feet = metersToFeet(metersValue);
    if (feet >= 5280) {
      final miles = metersToMiles(metersValue);
      final milesStr = miles.toStringAsFixed(miles < 10 ? 1 : 0);
      return l10n.getPluralString(
        'distanceInMiles',
        miles,
        displayValue: milesStr,
      );
    }
    final roundedFeet = ((feet / 5).round()) * 5;
    return l10n.getPluralString(
      'distanceInFeet',
      roundedFeet,
      displayValue: roundedFeet.toString(),
    );
  } else {
    // Use meters for small distances and kilometers for larger ones.
    if (metersValue >= 1000) {
      final km = metersValue / 1000.0;
      final kmStr = km == km.roundToDouble()
          ? km.toStringAsFixed(0)
          : km.toStringAsFixed(km < 10 ? 1 : 0);
      return l10n.getPluralString(
        'distanceInKilometers',
        km,
        displayValue: kmStr,
      );
    }
    final meters = metersValue.round();
    return l10n.getPluralString(
      'distanceInMeters',
      meters,
      displayValue: meters.toString(),
    );
  }
}

/// Formats a height in feet and inches, e.g. "5 feet 7 inches".
///
/// Each unit is translated on its own so it picks the right plural form —
/// "1 foot", not "1 feet" — and the two are put together by a translation so
/// every language keeps its own word order.
String formatHeightFeetInches(LocalizationState l10n, int heightCm) {
  final totalInches = (heightCm / 2.54).round();
  final feet = totalInches ~/ 12;
  final inches = totalInches % 12;
  return l10n.getString(
    'profileHeightFeetInches',
    params: {
      'feet': l10n.getPluralString('profileHeightFeetValue', feet),
      'inches': l10n.getPluralString('profileHeightInchesValue', inches),
    },
  );
}
