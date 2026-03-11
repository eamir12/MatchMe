// lib/services/session_service.dart
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/app_info_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class SessionService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const String _prefsFcmTokenKey = 'fcm_token';
  static const String _prefsSessionIdPrefix = 'user_session_id:';
  static const Uuid _uuid = Uuid();

  static String _sessionIdPrefsKey(String userId, String platform, {String? deviceId}) {
    final uid = userId.trim();
    final p = platform.trim();
    final did = deviceId?.trim();
    if (did != null && did.isNotEmpty) {
      return '$_prefsSessionIdPrefix$uid:$p:$did';
    }
    return '$_prefsSessionIdPrefix$uid:$p';
  }

  static Future<String?> _getStoredSessionId(String userId, String platform, {String? deviceId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
      final v = prefs.getString(key);
      final trimmed = v?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearStoredSessionId(String userId, String platform, {String? deviceId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
      await prefs.remove(key);
    } catch (_) {
    }
  }

  static Future<void> _storeSessionId(String userId, String platform, String sessionId, {String? deviceId}) async {
    final uid = userId.trim();
    final p = platform.trim();
    final sid = sessionId.trim();
    if (uid.isEmpty || p.isEmpty || sid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(uid, p, deviceId: deviceId);
      await prefs.setString(key, sid);
    } catch (_) {
    }
  }

  static Future<String?> _getStoredFcmToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsFcmTokenKey);
      final trimmed = v?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _storeFcmToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsFcmTokenKey, trimmed);
    } catch (_) {
    }
  }

  static Future<void> clearLocalFcmToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsFcmTokenKey);
    } catch (_) {
    }
  }

  static Future<void> deleteFcmToken() async {
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
    }
  }

  static Future<void> revokeCurrentSession({
    required String userId,
    required String platform,
    String? deviceId,
  }) async {
    final uid = userId.trim();
    final p = platform.trim();
    if (uid.isEmpty || p.isEmpty) return;

    final sessionId = await _getStoredSessionId(uid, p, deviceId: deviceId);
    if (sessionId == null || sessionId.isEmpty) return;

    try {
      await Supabase.instance.client
          .from('user_session')
          .update({'revoked': true})
          .eq('id', sessionId)
          .eq('user_id', uid);
    } catch (_) {
    }
  }

  static Future<String?> _getDeviceIdFast() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        final v = info.id.trim();
        return v.isEmpty ? null : v;
      }
      if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        final v = (info.identifierForVendor ?? '').trim();
        return v.isEmpty ? null : v;
      }
    } catch (_) {
    }
    return null;
  }

  static Future<void> clearFcmStateOnLogout({
    String? userId,
    String? platform,
  }) async {
    final uid = userId?.trim();
    final p = platform?.trim();
    if (uid != null && uid.isNotEmpty && p != null && p.isNotEmpty) {
      final deviceId = await _getDeviceIdFast();
      await revokeCurrentSession(userId: uid, platform: p, deviceId: deviceId);
      await _clearStoredSessionId(uid, p, deviceId: deviceId);
    }
    await deleteFcmToken();
    await clearLocalFcmToken();
  }

  static Future<String?> _fetchPublicIp() async {
    final start = DateTime.now();
    try {
      final r = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 5));
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        debugPrint('[BGSESSION] _fetchPublicIp: success ip=${data['ip']} elapsed=${elapsed}ms');
        return data['ip'] as String?;
      } else {
        debugPrint('[BGSESSION] _fetchPublicIp: non-200 status=${r.statusCode} elapsed=${elapsed}ms');
      }
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      debugPrint('[BGSESSION] _fetchPublicIp: failed: $e elapsed=${elapsed}ms');
    }
    return null;
  }

  static String _tokenHash(String token) => sha256.convert(utf8.encode(token)).toString();

  static Future<Map<String, dynamic>> collectSessionInfo({
    String? platformOverride,
    String? fcmTokenOverride,
  }) async {
    final totalStart = DateTime.now();
    final appInfo = await AppInfoService.getAppInfo();

    String? deviceModel = 'unknown';
    String? deviceId = '';

    try {
      final deviceStart = DateTime.now();
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
      debugPrint('[BGSESSION] collectSessionInfo: device info collected (elapsed=${DateTime.now().difference(deviceStart).inMilliseconds}ms)');
    } catch (e) {
      debugPrint('[BGSESSION] collectSessionInfo: device info collection failed: $e');
    }

    final ip = await _fetchPublicIp();
    debugPrint('[BGSESSION] collectSessionInfo: public IP fetched (ip=$ip elapsed=${DateTime.now().difference(totalStart).inMilliseconds}ms)');

    final session = Supabase.instance.client.auth.currentSession;
    final token = session?.accessToken ?? '';
    final tokenHash = token.isNotEmpty ? _tokenHash(token) : null;

    final platformText = platformOverride ?? _detectPlatform();

    final userAgent = '${appInfo.appName}/${appInfo.version} (${deviceModel ?? 'unknown'})';

    final metadata = {
      'app_name': appInfo.appName,
      'app_version': appInfo.version,
      'build_number': appInfo.buildNumber,
      'platform': platformText,
      'device_model': deviceModel ?? 'unknown',
    };
    final overrideTrimmed = fcmTokenOverride?.trim();
    if (overrideTrimmed != null && overrideTrimmed.isNotEmpty) {
      await _storeFcmToken(overrideTrimmed);
    }

    final fcmToken = overrideTrimmed ?? await _getStoredFcmToken();
    if (fcmToken != null && fcmToken.isNotEmpty) {
      metadata['fcm_token'] = fcmToken;
      metadata['fcm_token_updated_at'] = DateTime.now().toIso8601String();
    }

    debugPrint('[BGSESSION] collectSessionInfo: total elapsed=${DateTime.now().difference(totalStart).inMilliseconds}ms');

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

  static Future<String?> _inferCountryCodeBestEffort(String userId) async {
    final uid = userId.trim();
    if (uid.isEmpty) return null;

    Future<String?> fromCoordsHttp(double lat, double lon) async {
      try {
        final uri = Uri.https(
          'nominatim.openstreetmap.org',
          '/reverse',
          <String, String>{
            'format': 'jsonv2',
            'lat': lat.toString(),
            'lon': lon.toString(),
            'zoom': '3',
            'addressdetails': '1',
          },
        );
        final resp = await http.get(
          uri,
          headers: const <String, String>{'User-Agent': 'matchme.app'},
        ).timeout(const Duration(seconds: 6));
        if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
        final decoded = jsonDecode(resp.body);
        if (decoded is! Map) return null;
        final address = decoded['address'];
        if (address is! Map) return null;
        final code = (address['country_code'] ?? '').toString().trim().toUpperCase();
        return code.length == 2 ? code : null;
      } catch (_) {
        return null;
      }
    }

    Future<String?> fromCoords(double lat, double lon) async {
      if (kIsWeb) {
        return await fromCoordsHttp(lat, lon);
      }
      try {
        final placemarks = await placemarkFromCoordinates(lat, lon).timeout(const Duration(seconds: 4));
        if (placemarks.isEmpty) return null;
        final code = (placemarks.first.isoCountryCode ?? '').trim().toUpperCase();
        if (code.length == 2) return code;
        return await fromCoordsHttp(lat, lon);
      } catch (_) {
        return await fromCoordsHttp(lat, lon);
      }
    }

    try {
      final db = await LocalDbService.instance;
      final cached = await db.getCurrentLocation(uid);
      if (cached != null) {
        final lat = (cached['latitude'] as num?)?.toDouble();
        final lon = (cached['longitude'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          final code = await fromCoords(lat, lon);
          if (code != null) return code;
        }
      }
    } catch (_) {}

    try {
      final rows = await Supabase.instance.client
          .from('user_locations')
          .select('latitude, longitude')
          .eq('user_id', uid)
          .order('updated_at', ascending: false)
          .limit(1);

      final list = (rows as List).cast<Map<String, dynamic>>();
      if (list.isNotEmpty) {
        final lat = (list.first['latitude'] as num?)?.toDouble();
        final lon = (list.first['longitude'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          final code = await fromCoords(lat, lon);
          if (code != null) return code;
        }
      }
    } catch (_) {}

    try {
      final permission = await Geolocator.checkPermission();
      final granted =
          permission == LocationPermission.always || permission == LocationPermission.whileInUse;
      if (!granted) return null;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 4),
        ),
      );
      return await fromCoords(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
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

  static Future<void> registerSession(
    String userId, {
    String? platform,
    String? fcmToken,
  }) async {
    try {
      String? url;
      try {
        final dynamic c = Supabase.instance.client;
        url = (c.supabaseUrl as String?)?.trim();
      } catch (_) {}
      debugPrint('[BGSESSION] registerSession: start userId=$userId url=$url platformOverride=$platform hasFcmTokenOverride=${(fcmToken ?? '').trim().isNotEmpty}');

      final info = await collectSessionInfo(
        platformOverride: platform,
        fcmTokenOverride: fcmToken,
      );
      final params = <String, dynamic>{'p_user_id': userId};

      // Map the collected values to RPC param names expected by the function
      if (info['p_platform'] != null) params['p_platform'] = info['p_platform'];
      if (info['p_device_id'] != null) params['p_device_id'] = info['p_device_id'];
      if (info['p_device_model'] != null) params['p_device_model'] = info['p_device_model'];
      if (info['p_user_agent'] != null) params['p_user_agent'] = info['p_user_agent'];
      if (info['p_ip'] != null) params['p_ip'] = info['p_ip'];
      if (info['p_token_hash'] != null) params['p_token_hash'] = info['p_token_hash'];
      if (info['p_metadata'] != null) params['p_metadata'] = info['p_metadata'];
      final country = await _inferCountryCodeBestEffort(userId);
      if (country != null && country.isNotEmpty) {
        params['p_country'] = country;
      }

      final platformText = (params['p_platform'] as String?)?.trim();
      if (platformText != null && platformText.isNotEmpty) {
        final deviceId = (info['p_device_id'] as String?)?.trim();
        params['p_id'] = await _getOrCreateSessionId(userId, platformText, deviceId: deviceId);
      }

      final session = Supabase.instance.client.auth.currentSession;
      if (session?.accessToken == null || session!.accessToken.isEmpty) {
        debugPrint('[BGSESSION] registerSession: WARNING - No valid auth token available for RPC call');
      }
      final authedUserId = Supabase.instance.client.auth.currentUser?.id;
      debugPrint('[BGSESSION] registerSession: auth currentUser=${authedUserId ?? 'null'} hasSession=${session != null}');

      final rpcStart = DateTime.now();
      final result = await Supabase.instance.client.rpc('upsert_user_session', params: params);
      debugPrint('[BGSESSION] registerSession: upsert_user_session completed (elapsed=${DateTime.now().difference(rpcStart).inMilliseconds}ms)');
      final platformKey = (params['p_platform'] as String?)?.trim();
      if (platformKey != null && platformKey.isNotEmpty) {
        final sessionId = (result as dynamic)?.toString().trim();
        if (sessionId != null && sessionId.isNotEmpty && _looksLikeUuid(sessionId)) {
          final deviceId = (params['p_device_id'] as String?)?.trim();
          await _storeSessionId(userId, platformKey, sessionId, deviceId: deviceId);
        }
      }

      try {
        final exists = await Supabase.instance.client
            .from('user_session')
            .select('id')
            .eq('user_id', userId)
            .limit(1);
        debugPrint('[BGSESSION] registerSession: user_session select ok hasRow=${(exists as List).isNotEmpty}');
      } catch (e) {
        debugPrint('[BGSESSION] registerSession: user_session select failed: $e');
      }
    } catch (e) {
      final errorMsg = e.toString();
      debugPrint('[BGSESSION] registerSession failed: $e');
      if (e is PostgrestException) {
        debugPrint('[BGSESSION] registerSession PostgrestException: code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}');
      }
      if (errorMsg.toLowerCase().contains('invalid jwt') ||
          errorMsg.toLowerCase().contains('unauthorized') ||
          errorMsg.toLowerCase().contains('401') ||
          errorMsg.toLowerCase().contains('403')) {
        debugPrint('⚠️ [BGSESSION] registerSession failed due to auth error - session JWT may be invalid');
      }
      // Best effort: log but don't rethrow to allow app to continue
    }
  }

  static Future<String> _getOrCreateSessionId(String userId, String platform, {String? deviceId}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
    final existing = prefs.getString(key)?.trim();
    if (existing != null && _looksLikeUuid(existing)) return existing;
    final generated = _uuid.v4();
    try {
      await prefs.setString(key, generated);
    } catch (_) {}
    return generated;
  }

  static bool _looksLikeUuid(String v) {
    final s = v.trim();
    if (s.length != 36) return false;
    final ok = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return ok.hasMatch(s);
  }
}
