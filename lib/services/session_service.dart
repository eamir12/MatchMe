// lib/services/session_service.dart
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class SessionService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  static Future<String?> _fetchPublicIp() async {
    try {
      final r = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        return data['ip'] as String?;
      }
    } catch (_) {}
    return null;
  }

  static String _tokenHash(String token) => sha256.convert(utf8.encode(token)).toString();

  static Future<Map<String, dynamic>> collectSessionInfo({String? platformOverride}) async {
    final pkg = await PackageInfo.fromPlatform();

    String? deviceModel = 'unknown';
    String? deviceId = '';

    try {
      if (kIsWeb) {
        deviceModel = 'web';
      } else {
        if (Platform.isAndroid) {
          final info = await _deviceInfo.androidInfo;
          deviceModel = info.model;
          deviceId = info.id;
        } else if (Platform.isIOS) {
          final info = await _deviceInfo.iosInfo;
          deviceModel = info.utsname.machine;
          deviceId = info.identifierForVendor;
        } else if (Platform.isMacOS) {
          final info = await _deviceInfo.macOsInfo;
          deviceModel = info.model;
        } else if (Platform.isWindows) {
          final info = await _deviceInfo.windowsInfo;
          deviceModel = info.computerName;
        } else if (Platform.isLinux) {
          final info = await _deviceInfo.linuxInfo;
          deviceModel = info.name;
        }
      }
    } catch (_) {
      // best effort
    }

    final ip = await _fetchPublicIp();
    final session = Supabase.instance.client.auth.currentSession;
    final token = session?.accessToken ?? '';
    final tokenHash = token.isNotEmpty ? _tokenHash(token) : null;

    final platformText = platformOverride ?? _detectPlatform();

    final userAgent = '${pkg.appName}/${pkg.version} (${deviceModel ?? 'unknown'})';

    final metadata = {
      'app_name': pkg.appName,
      'app_version': pkg.version,
      'build_number': pkg.buildNumber,
      'platform': platformText,
      'device_model': deviceModel ?? 'unknown',
    };

    return {
      'p_platform': platformText,
      'p_device_id': (deviceId != null && deviceId.isNotEmpty) ? deviceId : null,
      'p_device_model': deviceModel,
      'p_user_agent': userAgent,
      'p_ip': ip,
      'p_token_hash': tokenHash,
      'p_metadata': metadata,
    };
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  static Future<void> registerSession(String userId, {String? platform}) async {
    try {
      final info = await collectSessionInfo(platformOverride: platform);
      final params = <String, dynamic>{'p_user_id': userId};

      // Map the collected values to RPC param names expected by the function
      if (info['p_platform'] != null) params['p_platform'] = info['p_platform'];
      if (info['p_device_id'] != null) params['p_device_id'] = info['p_device_id'];
      if (info['p_device_model'] != null) params['p_device_model'] = info['p_device_model'];
      if (info['p_user_agent'] != null) params['p_user_agent'] = info['p_user_agent'];
      if (info['p_ip'] != null) params['p_ip'] = info['p_ip'];
      if (info['p_token_hash'] != null) params['p_token_hash'] = info['p_token_hash'];
      if (info['p_metadata'] != null) params['p_metadata'] = info['p_metadata'];

      await Supabase.instance.client.rpc('upsert_user_session', params: params);
    } catch (e) {
      // Best effort: ignore errors but log
      try {
        // ignore: avoid_print
        print('registerSession failed: $e');
      } catch (_) {}
    }
  }
}
