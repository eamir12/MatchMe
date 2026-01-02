// lib/providers/unit_provider.dart

import 'dart:ui' as ui;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:matchme/providers/user_preferences_provider.dart';

part 'unit_provider.g.dart';

/// Provider for determining if imperial units should be used based on location
@riverpod
class UnitSystem extends _$UnitSystem {
  @override
  Future<bool> build() async {
    final unitSystem = ref.watch(userUnitSystemProvider);
    if (unitSystem == UnitSystemPreference.metric) return false;
    if (unitSystem == UnitSystemPreference.imperial) return true;

    // Primary: use the DEVICE region (this aligns with the device's typical distance units).
    // Note: localizationProvider stores app UI language and may not include a countryCode.
    final deviceLocale = ui.PlatformDispatcher.instance.locale;
    final deviceCountry = deviceLocale.countryCode ?? '';
    if (deviceCountry.isNotEmpty) {
      final deviceImperial = usesImperialUnitsByCountry(deviceCountry);
      debugPrint('UnitSystem: Using device locale. Locale: ${deviceLocale.languageCode}_$deviceCountry, Imperial: $deviceImperial');
      return deviceImperial;
    }

    // Fallback: try to get country from stored/current location (best-effort).
    final storedPosition = ref.watch(currentLocationProvider);
    if (storedPosition != null) {
      debugPrint('UnitSystem: Using stored location for units');
      final countryCode = await getCountryCodeFromPosition(storedPosition);
      if (countryCode != null) {
        return usesImperialUnitsByCountry(countryCode);
      }
    }

    final countryCode = await getCountryCodeFromLocation();
    if (countryCode != null) {
      return usesImperialUnitsByCountry(countryCode);
    }

    // Final fallback: app locale (may not include region)
    final appLocale = ref.watch(localizationProvider).currentLocale;
    final appCountry = appLocale.countryCode ?? '';
    final appImperial = usesImperialUnitsByCountry(appCountry);
    debugPrint('UnitSystem: Using app locale fallback. Locale: ${appLocale.languageCode}_$appCountry, Imperial: $appImperial');
    return appImperial;
  }
}