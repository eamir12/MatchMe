import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

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

  static const String _defaultAppName = String.fromEnvironment('APP_NAME', defaultValue: 'MatchMe');
  static const String _defaultVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'unknown');
  static const String _defaultBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'unknown');

  static Future<AppInfo> getAppInfo() async {
    // Web cannot use platform channels.
    if (kIsWeb) {
      return const AppInfo(appName: _defaultAppName, version: _defaultVersion, buildNumber: _defaultBuild);
    }

    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('getAppInfo');
      final appName = (map?['appName'] as String?)?.trim();
      final version = (map?['version'] as String?)?.trim();
      final buildNumber = (map?['buildNumber'] as String?)?.trim();

      return AppInfo(
        appName: (appName != null && appName.isNotEmpty) ? appName : _defaultAppName,
        version: (version != null && version.isNotEmpty) ? version : _defaultVersion,
        buildNumber: (buildNumber != null && buildNumber.isNotEmpty) ? buildNumber : _defaultBuild,
      );
    } catch (_) {
      return const AppInfo(appName: _defaultAppName, version: _defaultVersion, buildNumber: _defaultBuild);
    }
  }
}
