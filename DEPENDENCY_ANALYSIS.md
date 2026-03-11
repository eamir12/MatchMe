# Flutter Dependency Analysis Report

**Generated:** February 19, 2026  
**Flutter Version:** 3.41.1 (stable channel)  
**Dart SDK:** 3.11.0

## Executive Summary

Your Flutter installation is up-to-date with the latest stable release (3.41.1, released 6 days ago). All **direct dependencies** in your `pubspec.yaml` are already at their latest compatible versions. However, there are several **transitive dependencies** (dependencies of your dependencies) that have newer versions available.

## Current Status

### ✅ Direct Dependencies - All Up-to-Date

All your direct main and dev dependencies are at their latest versions:

| Package | Current Version | Status |
|---------|----------------|--------|
| flutter_riverpod | ^3.1.0 | ✅ Latest |
| supabase_flutter | ^2.12.0 | ✅ Latest |
| firebase_core | ^4.4.0 | ✅ Latest |
| firebase_messaging | ^16.1.1 | ✅ Latest |
| firebase_analytics | ^12.0.0 | ✅ Latest |
| geolocator | ^14.0.2 | ✅ Latest |
| geocoding | ^4.0.0 | ✅ Latest |
| battery_plus | ^7.0.0 | ✅ Latest |
| hive | ^2.2.3 | ✅ Latest |
| hive_flutter | ^1.1.0 | ✅ Latest |
| flutter_local_notifications | ^20.0.0 | ✅ Latest |
| camera | ^0.11.4 | ✅ Latest |
| image_picker | ^1.2.0 | ✅ Latest |
| file_picker | ^10.3.8 | ✅ Latest |
| extended_image | ^10.0.1 | ✅ Latest |
| syncfusion_flutter_datepicker | ^32.2.5 | ✅ Latest |
| purchases_flutter | ^9.12.0 | ✅ Latest |
| purchases_ui_flutter | ^9.12.0 | ✅ Latest |
| webview_flutter | ^4.10.0 | ✅ Latest |
| permission_handler | ^12.0.1 | ✅ Latest |
| google_sign_in | ^7.2.0 | ✅ Latest |
| googleapis | ^16.0.0 | ✅ Latest |
| aad_oauth | ^1.0.1 | ✅ Latest |
| flutter_map | ^8.2.2 | ✅ Latest |
| All other dependencies | - | ✅ Latest |

### ⚠️ Transitive Dependencies with Updates Available

These are dependencies pulled in by your direct dependencies. They cannot be updated independently because they are constrained by their parent packages' version requirements.

#### Detailed Explanation for Each Outdated Transitive Dependency

| Package | Current → Latest | Constrained By | Reason Cannot Update |
|---------|------------------|----------------|---------------------|
| **_fe_analyzer_shared** | 92.0.0 → 95.0.0 | `analyzer 9.0.0` | The analyzer package v9.0.0 requires exactly _fe_analyzer_shared 92.0.0. Updating would require analyzer v10+ which has breaking changes. |
| **analyzer** | 9.0.0 → 10.1.0 | `build_runner`, `riverpod_generator`, `source_gen`, `mockito`, `dart_style` | Major version jump (9→10) with breaking changes. All code generation packages depend on analyzer ^9.0.0. |
| **analyzer_buffer** | 0.3.0 → 0.3.1 | `riverpod_generator 4.0.3`, `riverpod_analyzer_utils` | Minor update but constrained by riverpod_generator's dependency resolution. |
| **app_links** | 6.4.1 → 7.0.0 | `supabase_flutter 2.12.0` | Major version jump with breaking API changes. supabase_flutter pins to app_links ^6.4.1. |
| **camera_android_camerax** | 0.6.30 → 0.7.0+1 | `camera 0.11.4` | The camera package specifies this exact platform implementation version for Android. |
| **camera_avfoundation** | 0.9.23+2 → 0.10.0+2 | `camera 0.11.4` | The camera package specifies this exact platform implementation version for iOS. |
| **dart_style** | 3.1.3 → 3.1.5 | `build_runner 2.11.1`, `source_gen 4.2.0`, `mockito 5.6.3` | Minor patch update constrained by build_runner's pubspec resolution. |
| **flutter_secure_storage** | 9.2.4 → 10.0.0 | `aad_oauth 1.0.1` | **Major version jump with breaking changes.** aad_oauth depends on flutter_secure_storage ^9.0.0. |
| **flutter_secure_storage_linux** | 1.2.3 → 3.0.0 | `flutter_secure_storage 9.2.4` | Platform implementation constrained by parent flutter_secure_storage. |
| **flutter_secure_storage_macos** | 3.1.3 → 4.0.0 | `flutter_secure_storage 9.2.4` | Platform implementation constrained by parent flutter_secure_storage. |
| **flutter_secure_storage_platform_interface** | 1.1.2 → 2.0.1 | `flutter_secure_storage 9.2.4` | Platform interface constrained by parent flutter_secure_storage. |
| **flutter_secure_storage_web** | 1.2.1 → 2.1.0 | `flutter_secure_storage 9.2.4` | Platform implementation constrained by parent flutter_secure_storage. |
| **flutter_secure_storage_windows** | 3.1.2 → 4.1.0 | `flutter_secure_storage 9.2.4` | Platform implementation constrained by parent flutter_secure_storage. |
| **geocoding_android** | 4.0.1 → 5.0.0 | `geocoding 4.0.0` | Major version jump. The geocoding package pins to geocoding_android ^4.0.1. |
| **geocoding_platform_interface** | 3.2.0 → 5.0.0 | `geocoding 4.0.0`, `geocoding_android`, `geocoding_ios` | Major version jump constrained by geocoding package ecosystem. |
| **googleapis_auth** | 2.0.0 → 2.1.0 | `extension_google_sign_in_as_googleapis_auth 3.0.0`, `googleapis 16.0.0` | Minor update but constrained by googleapis and extension package. |
| **js** | 0.6.7 → 0.7.2 | `aad_oauth`, `flutter_secure_storage_web`, `extended_image_library` | **Package is DISCONTINUED.** Being replaced by `dart:js_interop` in Flutter 3.41+. |
| **meta** | 1.17.0 → 1.18.1 | Flutter SDK | **Bundled with Flutter/Dart SDK.** Version is tied to SDK version, cannot update independently. |
| **mgrs_dart** | 2.0.0 → 3.0.0 | `proj4dart 2.1.0` | Major version jump. proj4dart depends on mgrs_dart ^2.0.0. |
| **proj4dart** | 2.1.0 → 3.0.0 | `flutter_map 8.2.2` | Major version jump with breaking changes. flutter_map pins to proj4dart ^2.1.0. |
| **timezone** | 0.10.1 → 0.11.0 | `flutter_local_notifications 20.1.0` | Minor update constrained by flutter_local_notifications' pubspec. |
| **unicode** | 0.3.1 → 1.1.9 | `mgrs_dart 2.0.0` | Major version jump (0.3→1.1). mgrs_dart pins to unicode ^0.3.1. |

### 🚨 Discontinued Package

| Package | Status | Impact | Solution |
|---------|--------|--------|----------|
| `js` | Discontinued | Used by web plugins | Being replaced by `dart:js_interop` in Flutter 3.41+ |

The `js` package (version 0.6.7) has been discontinued. This is a transitive dependency used by several web-related packages. The Flutter team is migrating to `dart:js_interop` which is included in Dart 3.11+. This transition is handled automatically by Flutter's web plugins.

## Code Fix Applied

During analysis, a syntax error was discovered and fixed in [`lib/services/verification_service.dart`](lib/services/verification_service.dart:121):

**Issue:** Invalid switch expression syntax inside a map literal (lines 123-134)

**Fixed:** Replaced the problematic switch expression with a cleaner approach using conditional map entries:

```dart
// Before (invalid syntax):
body: {
  'userId': userId,
  'verificationPhotoPath': verificationPhotoPath,
  (switch (gestureCode) {
    final code? => MapEntry('gestureCode', code),
    _ => null,
  })?,
  ...
}

// After (correct syntax):
final body = <String, dynamic>{
  'userId': userId,
  'verificationPhotoPath': verificationPhotoPath,
};
if (gestureCode != null) {
  body['gestureCode'] = gestureCode;
}
if (gesturePrompt != null) {
  body['gesturePrompt'] = gesturePrompt;
}
```

## Recommendations

### Immediate Actions (None Required)

Your project is in excellent shape:
- ✅ Flutter 3.41.1 is the latest stable release
- ✅ All direct dependencies are at latest versions
- ✅ `flutter analyze` passes with no issues
- ✅ SDK constraint `>=3.11.0 <4.0.0` is correct

### Future Considerations

1. **Hive Database**: The `hive` and `hive_flutter` packages (version 2.x) are stable but the ecosystem is less active. Consider monitoring for updates or evaluating alternatives like `isar` for future major versions.

2. **Discontinued `js` package**: This is being handled by the Flutter ecosystem's migration to `dart:js_interop`. No action needed now, but ensure web plugins are kept updated.

3. **Transitive Updates**: The following transitive dependencies have major version updates available but are constrained by their parent packages:
   - `flutter_secure_storage` v10 - requires `aad_oauth` to update
   - `geocoding_android` v5 - requires `geocoding` package to update
   - `camera_android_camerax` v0.7 - requires `camera` package to update

### Update Strategy

To stay current, run these commands periodically:

```bash
# Check for outdated packages
flutter pub outdated

# Upgrade within version constraints
flutter pub upgrade

# Major version upgrades (careful - may have breaking changes)
flutter pub upgrade --major-versions
```

## Dependency Version Summary

### SDK Constraints
- **Dart SDK:** `>=3.11.0 <4.0.0` ✅
- **Flutter SDK:** `>=3.38.4` ✅ (You have 3.41.1)

### Key Dependency Groups

| Category | Packages | Status |
|----------|----------|--------|
| State Management | flutter_riverpod, riverpod_annotation, riverpod_generator | ✅ Latest (v3/v4) |
| Backend | supabase_flutter | ✅ Latest (v2.12) |
| Firebase | firebase_core, firebase_messaging, firebase_analytics | ✅ Latest (v4/v16/v12) |
| Location | geolocator, geocoding | ✅ Latest (v14/v4) |
| Local Storage | hive, hive_flutter, shared_preferences | ✅ Latest |
| UI Components | camera, image_picker, extended_image, syncfusion | ✅ Latest |
| Payments | purchases_flutter, purchases_ui_flutter | ✅ Latest (v9.12) |
| Authentication | google_sign_in, aad_oauth | ✅ Latest |
| Maps | flutter_map, latlong2 | ✅ Latest |

## Conclusion

Your project is running on the **latest and greatest** versions available. No immediate updates are required. The transitive dependency updates will be automatically applied when their parent packages release new versions.

**Last Flutter upgrade check:** February 19, 2026  
**Next recommended check:** March 2026 or when notified of security updates
