import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppInfo {
  final String appName;
  final String version;
  final String buildNumber;

  const AppInfo({
    required this.appName,
    required this.version,
    required this.buildNumber,
  });

  Map<String, dynamic> toJson() => {
    'app_name': appName,
    'app_version': version,
    'build_number': buildNumber,
  };
}

class AppInfoService {
  static const MethodChannel _channel = MethodChannel('matchme/app_info');

  static const String _defaultAppName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'MatchMe',
  );
  static const String _defaultVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: 'unknown',
  );
  static const String _defaultBuild = String.fromEnvironment(
    'APP_BUILD',
    defaultValue: 'unknown',
  );

  static Future<AppInfo> getAppInfo() async {
    // Web cannot use platform channels.
    if (kIsWeb) {
      return const AppInfo(
        appName: _defaultAppName,
        version: _defaultVersion,
        buildNumber: _defaultBuild,
      );
    }

    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('getAppInfo');
      final appName = (map?['appName'] as String?)?.trim();
      final version = (map?['version'] as String?)?.trim();
      final buildNumber = (map?['buildNumber'] as String?)?.trim();

      return AppInfo(
        appName: (appName != null && appName.isNotEmpty)
            ? appName
            : _defaultAppName,
        version: (version != null && version.isNotEmpty)
            ? version
            : _defaultVersion,
        buildNumber: (buildNumber != null && buildNumber.isNotEmpty)
            ? buildNumber
            : _defaultBuild,
      );
    } catch (_) {
      // Windows/macOS/Linux have no `matchme/app_info` channel; read the same
      // version/build from the platform bundle instead of reporting unknown.
      return _fromPackageInfo();
    }
  }

  static Future<AppInfo> _fromPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final appName = info.appName.trim();
      final version = info.version.trim();
      final buildNumber = info.buildNumber.trim();
      return AppInfo(
        appName: appName.isNotEmpty ? appName : _defaultAppName,
        version: version.isNotEmpty ? version : _defaultVersion,
        buildNumber: buildNumber.isNotEmpty ? buildNumber : _defaultBuild,
      );
    } catch (_) {
      return const AppInfo(
        appName: _defaultAppName,
        version: _defaultVersion,
        buildNumber: _defaultBuild,
      );
    }
  }

  static Future<bool> hasApsEnvironmentEntitlement() async {
    if (kIsWeb) return false;

    try {
      final value = await _channel.invokeMethod<bool>(
        'hasApsEnvironmentEntitlement',
      );
      return value ?? false;
    } catch (_) {
      return true;
    }
  }

  /// Snapshot of the iOS push configuration, for diagnosing "no notifications
  /// arrive". Returns an empty map on platforms without the concept.
  ///
  /// Keys (iOS only):
  /// * `hasApsEnvironment` — the app was signed with the push entitlement.
  /// * `apsEnvironment` — `development` / `production`.
  /// * `apnsTokenRegistered` — APNs handed us a device token.
  /// * `apnsRegistrationError` — why registration failed, when it did.
  static Future<Map<String, dynamic>> getPushDiagnostics() async {
    if (kIsWeb) return const {};

    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getPushDiagnostics',
      );
      return map ?? const {};
    } catch (_) {
      return const {};
    }
  }
}
