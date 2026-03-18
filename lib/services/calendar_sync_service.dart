import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/main.dart' show navigatorKey;
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:aad_oauth/aad_oauth.dart';
import 'package:aad_oauth/model/config.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/outlook_web_auth.dart'
    if (dart.library.io) 'package:matchme/services/outlook_web_auth_stub.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CalendarSyncException implements Exception {
  final String message;
  final String? userMessage;
  final bool isAuthError;
  final bool isNetworkError;

  CalendarSyncException(
    this.message, {
    this.userMessage,
    this.isAuthError = false,
    this.isNetworkError = false,
  });

  @override
  String toString() => userMessage ?? message;
}

class CalendarSyncService {
  final DeviceCalendar _deviceCalendar = DeviceCalendar.instance;
  final WebCalendarService _webService = WebCalendarService();
  AadOAuth? _outlookOAuth;
  String? _outlookAccessToken;
  DateTime? _outlookTokenExpiry;
  String? _googleImportAccessToken;
  DateTime? _googleImportTokenExpiry;
  String? _googleImportUserEmail;
  bool _didLoadGoogleImportTokenCache = false;
  static const String _outlookTokenKey = 'outlook_access_token';
  static const String _outlookTokenExpiryKey = 'outlook_token_expiry';
  static const String _googleImportTokenKey = 'google_import_access_token';
  static const String _googleImportTokenExpiryKey =
      'google_import_access_token_expiry';
  static const String _googleImportUserEmailKey = 'google_import_user_email';
  static const List<String> _outlookMsalScopes = [
    'User.Read',
    'Calendars.Read',
    'offline_access',
  ];
  String? _outlookWebClientId;
  String? _outlookWebTenant;
  String? _outlookWebRedirectUri;
  bool _outlookWebRedirectInProgress = false;

  CalendarSyncService();

  WebCalendarService get webService => _webService;

  void _trace(String message) {
    debugPrint(message);
    developer.log(message, name: 'CalendarSyncService');
  }

  bool _hasAuthProvider(User? user, String provider) {
    final p = provider.toLowerCase().trim();
    bool matches(String? raw) {
      if (raw == null) return false;
      final v = raw.toLowerCase().trim();
      if (v.isEmpty) return false;
      return v == p || v.contains(p) || p.contains(v);
    }

    final meta = user?.appMetadata;
    final direct = meta?['provider']?.toString().toLowerCase().trim();
    if (matches(direct)) return true;
    final providers = meta?['providers'];
    if (providers is List) {
      for (final item in providers) {
        if (matches(item.toString())) return true;
      }
    }
    return false;
  }

  Map<String, dynamic>? _googleProviderSessionPayload() {
    final session = Supabase.instance.client.auth.currentSession;
    final user = Supabase.instance.client.auth.currentUser;
    final token = session?.providerToken;
    if (token == null || token.isEmpty || !_hasAuthProvider(user, 'google')) {
      return null;
    }
    final exp = session?.expiresAt;
    final expiry = exp != null
        ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true).toLocal()
        : DateTime.now().add(const Duration(minutes: 55));
    return {'token': token, 'expiry': expiry, 'userEmail': user?.email};
  }

  Map<String, dynamic>? _azureProviderSessionPayload() {
    final session = Supabase.instance.client.auth.currentSession;
    final user = Supabase.instance.client.auth.currentUser;
    final token = session?.providerToken;
    if (token == null ||
        token.isEmpty ||
        !(_hasAuthProvider(user, 'azure') ||
            _hasAuthProvider(user, 'microsoft') ||
            _hasAuthProvider(user, 'azuread'))) {
      return null;
    }
    final exp = session?.expiresAt;
    final expiry = exp != null
        ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true).toLocal()
        : DateTime.now().add(const Duration(minutes: 55));
    return {'token': token, 'expiry': expiry, 'userEmail': user?.email};
  }

  Future<void> _startSupabaseOAuth({
    required OAuthProvider provider,
    required String scopes,
  }) async {
    const mobileRedirectTo = 'com.example.matchme://login-callback';
    final redirectTo = kIsWeb
        ? '${Uri.base.origin}/auth/callback'
        : mobileRedirectTo;
    await Supabase.instance.client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectTo,
      scopes: scopes,
    );
  }

  Future<void> _restoreSessionIfChanged({
    required Session? originalSession,
    required String? originalUserId,
  }) async {
    if (originalSession == null || originalUserId == null) {
      return;
    }
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == originalUserId) {
      return;
    }
    final refreshToken = originalSession.refreshToken;
    if (refreshToken == null || refreshToken.trim().isEmpty) {
      return;
    }
    try {
      await Supabase.instance.client.auth.setSession(refreshToken);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _waitForProviderPayload({
    required Map<String, dynamic>? Function() readPayload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var payload = readPayload();
    if (payload != null) return payload;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 350));
      payload = readPayload();
      if (payload != null) return payload;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _ensureGoogleProviderSessionPayload() async {
    final existing = _googleProviderSessionPayload();
    if (existing != null) return existing;
    final originalSession = Supabase.instance.client.auth.currentSession;
    final originalUserId = Supabase.instance.client.auth.currentUser?.id;
    try {
      await _startSupabaseOAuth(
        provider: OAuthProvider.google,
        scopes:
            'openid email profile https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events.readonly',
      );
    } catch (_) {}
    final payload = await _waitForProviderPayload(
      readPayload: _googleProviderSessionPayload,
    );
    await _restoreSessionIfChanged(
      originalSession: originalSession,
      originalUserId: originalUserId,
    );
    return payload;
  }

  Future<Map<String, dynamic>?> _ensureAzureProviderSessionPayload() async {
    final existing = _azureProviderSessionPayload();
    if (existing != null) return existing;
    final originalSession = Supabase.instance.client.auth.currentSession;
    final originalUserId = Supabase.instance.client.auth.currentUser?.id;
    try {
      await _startSupabaseOAuth(
        provider: OAuthProvider.azure,
        scopes: 'openid email profile offline_access User.Read Calendars.Read',
      );
    } catch (_) {}
    final payload = await _waitForProviderPayload(
      readPayload: _azureProviderSessionPayload,
    );
    await _restoreSessionIfChanged(
      originalSession: originalSession,
      originalUserId: originalUserId,
    );
    return payload;
  }

  bool _isGoogleImportTokenExpired() {
    if (_googleImportAccessToken == null ||
        _googleImportAccessToken!.trim().isEmpty) {
      return true;
    }
    final expiry = _googleImportTokenExpiry;
    if (expiry == null) return true;
    return DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 1)));
  }

  Future<void> _loadGoogleImportTokenFromCache() async {
    if (_didLoadGoogleImportTokenCache) return;
    _didLoadGoogleImportTokenCache = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_googleImportTokenKey);
      final expiryRaw = prefs.getString(_googleImportTokenExpiryKey);
      final email = prefs.getString(_googleImportUserEmailKey);
      final expiry = expiryRaw != null ? DateTime.tryParse(expiryRaw) : null;
      if (token == null || token.trim().isEmpty || expiry == null) return;
      _googleImportAccessToken = token;
      _googleImportTokenExpiry = expiry;
      _googleImportUserEmail = email;
    } catch (_) {}
  }

  Future<void> _saveGoogleImportTokenToCache({
    required String token,
    required DateTime expiry,
    String? userEmail,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_googleImportTokenKey, token);
      await prefs.setString(
        _googleImportTokenExpiryKey,
        expiry.toIso8601String(),
      );
      if (userEmail != null && userEmail.trim().isNotEmpty) {
        await prefs.setString(_googleImportUserEmailKey, userEmail.trim());
      } else {
        await prefs.remove(_googleImportUserEmailKey);
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _getGoogleImportSessionPayload() async {
    await _loadGoogleImportTokenFromCache();
    if (!_isGoogleImportTokenExpired()) {
      return {
        'token': _googleImportAccessToken!,
        'expiry': _googleImportTokenExpiry!,
        'userEmail': _googleImportUserEmail,
      };
    }
    final currentPayload = _googleProviderSessionPayload();
    if (currentPayload != null) {
      final token = currentPayload['token'] as String;
      final expiry = currentPayload['expiry'] as DateTime;
      final userEmail = currentPayload['userEmail'] as String?;
      _googleImportAccessToken = token;
      _googleImportTokenExpiry = expiry;
      _googleImportUserEmail = userEmail;
      await _saveGoogleImportTokenToCache(
        token: token,
        expiry: expiry,
        userEmail: userEmail,
      );
      return currentPayload;
    }
    final oauthPayload = await _ensureGoogleProviderSessionPayload();
    if (oauthPayload == null) return null;
    final token = oauthPayload['token'] as String;
    final expiry = oauthPayload['expiry'] as DateTime;
    final userEmail = oauthPayload['userEmail'] as String?;
    _googleImportAccessToken = token;
    _googleImportTokenExpiry = expiry;
    _googleImportUserEmail = userEmail;
    await _saveGoogleImportTokenToCache(
      token: token,
      expiry: expiry,
      userEmail: userEmail,
    );
    return oauthPayload;
  }

  void dispose() {
    _webService.dispose();
  }

  /// Check if Outlook app is installed on the device
  Future<bool> isOutlookInstalled() async {
    if (kIsWeb) return false;

    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        const platform = MethodChannel('com.example.matchme/app_check');

        // First, scan for any Microsoft/Outlook packages to find the actual package name
        try {
          final packages = await platform.invokeMethod<List<Object?>>(
            'findOutlookPackages',
          );
          if (packages != null && packages.isNotEmpty) {
            final packageList = packages.cast<String>();

            // Filter to only Outlook-specific packages
            final outlookPackages = packageList
                .where((pkg) => pkg.toLowerCase().contains('outlook'))
                .toList();

            if (outlookPackages.isNotEmpty) {
              // Check if any of these packages are actually installed
              for (final packageName in outlookPackages) {
                try {
                  final isInstalled = await platform.invokeMethod<bool>(
                    'isAppInstalled',
                    {'packageName': packageName},
                  );
                  if (isInstalled == true) {
                    return true;
                  }
                } catch (_) {
                  continue;
                }
              }
            }
          } else {}
        } catch (_) {
          await Future<void>.value();
        }

        // Fallback: Try known package names
        final possiblePackages = [
          'com.microsoft.office.outlook', // Main Outlook app
          'com.microsoft.outlook', // Alternative package name
          'com.outlook.Z7', // Old Outlook package
        ];

        for (final packageName in possiblePackages) {
          try {
            final isInstalled = await platform.invokeMethod<bool>(
              'isAppInstalled',
              {'packageName': packageName},
            );
            if (isInstalled == true) {
              return true;
            }
          } catch (_) {
            continue;
          }
        }

        return false;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // On iOS, we can try to open the URL scheme
        // This is a simplified check - actual implementation would need url_launcher
        return false; // For now, return false on iOS
      }
    } catch (_) {
      await Future<void>.value();
    }
    return false;
  }

  /// Open Outlook app settings (Android only)
  Future<void> openOutlookSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      const platform = MethodChannel('com.example.matchme/app_check');
      // Try to launch Outlook app first
      try {
        final launched = await platform.invokeMethod<bool>('launchOutlookApp');
        if (launched == true) {
          return;
        }
      } catch (_) {
        await Future<void>.value();
      }

      // Fallback: Open Android app settings
      await platform.invokeMethod('openAppSettings', {
        'packageName': 'com.microsoft.office.outlook',
      });
    } catch (_) {
      return;
    }
  }

  Future<void> openCalendarPermissionSettings() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const platform = MethodChannel('com.example.matchme/app_check');
        final opened = await platform.invokeMethod<bool>(
          'openCalendarPermissionSettings',
          {'packageName': 'com.example.matchme'},
        );
        if (opened == true) {
          return;
        }
      } catch (_) {
        await Future<void>.value();
      }
    }
    await openAppSettings();
  }

  Config _buildOutlookConfigWithValues({
    required String tenant,
    required String clientId,
    required String redirectUri,
  }) {
    return Config(
      tenant: tenant,
      clientId: clientId,
      scope: 'User.Read Calendars.Read offline_access',
      redirectUri: redirectUri,
      navigatorKey: navigatorKey,
      webUseRedirect: false,
    );
  }

  Config _buildOutlookConfig() {
    var tenant = const String.fromEnvironment(
      'OUTLOOK_TENANT_ID',
      defaultValue: '',
    ).trim();
    var clientId = const String.fromEnvironment(
      'OUTLOOK_CLIENT_ID',
      defaultValue: '',
    ).trim();
    var redirectUri = const String.fromEnvironment(
      'OUTLOOK_REDIRECT_URI',
      defaultValue: '',
    ).trim();

    if (tenant.isEmpty) tenant = (dotenv.env['OUTLOOK_TENANT_ID'] ?? '').trim();
    if (clientId.isEmpty) {
      clientId = (dotenv.env['OUTLOOK_CLIENT_ID'] ?? '').trim();
    }
    if (redirectUri.isEmpty) {
      redirectUri = (dotenv.env['OUTLOOK_REDIRECT_URI'] ?? '').trim();
    }

    if (tenant.isEmpty || clientId.isEmpty || redirectUri.isEmpty) {
      throw CalendarSyncException(
        'Outlook OAuth configuration is missing',
        userMessage: 'calendarSyncOutlookNotConfigured',
      );
    }

    return _buildOutlookConfigWithValues(
      tenant: tenant,
      clientId: clientId,
      redirectUri: redirectUri,
    );
  }

  List<Config> _buildOutlookWebConfigCandidates() {
    final primary = _buildOutlookConfig();
    var fallbackClientId = const String.fromEnvironment(
      'OUTLOOK_CLIENT_ID_FALLBACK',
      defaultValue: '',
    ).trim();
    if (fallbackClientId.isEmpty) {
      fallbackClientId = (dotenv.env['OUTLOOK_CLIENT_ID_FALLBACK'] ?? '')
          .trim();
    }

    final tenants = <String>[
      primary.tenant,
      if (primary.tenant.toLowerCase() != 'common') 'common',
      if (primary.tenant.toLowerCase() != 'organizations') 'organizations',
      if (primary.tenant.toLowerCase() != 'consumers') 'consumers',
    ];

    final seen = <String>{};
    final candidates = <Config>[];

    void addCandidate(String tenant, String clientId) {
      final key =
          '${tenant.trim().toLowerCase()}|${clientId.trim().toLowerCase()}';
      if (!seen.add(key)) return;
      candidates.add(
        _buildOutlookConfigWithValues(
          tenant: tenant.trim(),
          clientId: clientId.trim(),
          redirectUri: primary.redirectUri,
        ),
      );
    }

    for (final tenant in tenants) {
      addCandidate(tenant, primary.clientId);
    }
    if (fallbackClientId.isNotEmpty &&
        fallbackClientId.toLowerCase() != primary.clientId.toLowerCase()) {
      for (final tenant in tenants) {
        addCandidate(tenant, fallbackClientId);
      }
    }

    return candidates;
  }

  DateTime _fallbackOutlookExpiry() {
    return DateTime.now().add(const Duration(minutes: 55));
  }

  DateTime? _extractJwtExpiry(String token) {
    try {
      final segments = token.split('.');
      if (segments.length < 2) return null;
      final payload = segments[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = json.decode(decoded);
      if (map is! Map<String, dynamic>) return null;
      final exp = map['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        exp.toInt() * 1000,
        isUtc: true,
      ).toLocal();
    } catch (_) {
      return null;
    }
  }

  DateTime _resolveOutlookTokenExpiry(String token) {
    return _extractJwtExpiry(token) ?? _fallbackOutlookExpiry();
  }

  Future<int> _outlookTimeoutSeconds() async {
    return appConfigService.getInt(
      'calendar.api_timeout_seconds',
      defaultValue: 30,
    );
  }

  Map<String, String> _outlookHeaders(String token) {
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Prefer': 'outlook.timezone="UTC", odata.maxpagesize=250',
    };
  }

  Uri _buildOutlookCalendarsUri() {
    return Uri.parse('https://graph.microsoft.com/v1.0/me/calendars?\$top=250');
  }

  Uri _buildOutlookCalendarViewUri({
    required String calendarId,
    required String startIso,
    required String endIso,
  }) {
    final encodedCalendarId = Uri.encodeComponent(calendarId);
    return Uri.parse(
      'https://graph.microsoft.com/v1.0/me/calendars/$encodedCalendarId/calendarView',
    ).replace(
      queryParameters: {
        'startDateTime': startIso,
        'endDateTime': endIso,
        '\$orderby': 'start/dateTime',
        '\$top': '250',
      },
    );
  }

  Future<void> _ensureOutlookOAuth({bool allowNonWeb = false}) async {
    if (kIsWeb) {
      if (!OutlookWebAuth.instance.isInitialized) {
        final config = _buildOutlookConfigWithValues(
          tenant: _outlookWebTenant ?? _buildOutlookConfig().tenant,
          clientId: _outlookWebClientId ?? _buildOutlookConfig().clientId,
          redirectUri:
              _outlookWebRedirectUri ?? _buildOutlookConfig().redirectUri,
        );
        await OutlookWebAuth.instance.initialize(
          clientId: config.clientId,
          tenantId: config.tenant,
          redirectUri: config.redirectUri,
        );
      }
      final redirectToken = await OutlookWebAuth.instance
          .handleRedirectCallback();
      if (redirectToken != null && redirectToken.trim().isNotEmpty) {
        _outlookAccessToken = redirectToken;
        _outlookTokenExpiry = _resolveOutlookTokenExpiry(redirectToken);
        await _saveOutlookTokenToCache(
          _outlookAccessToken!,
          _outlookTokenExpiry!,
        );
        _outlookWebRedirectInProgress = false;
      }
    } else {
      if (!allowNonWeb) {
        throw CalendarSyncException(
          'Outlook OAuth requires mobile platform',
          userMessage: 'calendarSyncOutlookMobileOnly',
        );
      }
      _outlookOAuth ??= AadOAuth(_buildOutlookConfig());
    }
  }

  Future<void> _loadOutlookTokenFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _outlookAccessToken = prefs.getString(_outlookTokenKey);
      final expiryString = prefs.getString(_outlookTokenExpiryKey);
      if (expiryString != null) {
        _outlookTokenExpiry = DateTime.tryParse(expiryString);
      }
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  Future<void> _saveOutlookTokenToCache(String token, DateTime expiry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outlookTokenKey, token);
      await prefs.setString(_outlookTokenExpiryKey, expiry.toIso8601String());
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  Future<void> _clearOutlookTokenCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_outlookTokenKey);
      await prefs.remove(_outlookTokenExpiryKey);
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  bool _isOutlookTokenExpired() {
    if (_outlookTokenExpiry == null) return true;
    // Consider token expired 5 minutes before actual expiry (using default, async load not practical here)
    const bufferMinutes =
        5; // Default from config: calendar.token_refresh_buffer_minutes
    return DateTime.now().isAfter(
      _outlookTokenExpiry!.subtract(Duration(minutes: bufferMinutes)),
    );
  }

  Future<String?> _refreshOutlookToken({bool allowNonWeb = false}) async {
    try {
      await _clearOutlookTokenCache();
      _outlookAccessToken = null;
      _outlookTokenExpiry = null;
      return await _signInOutlook(
        allowNonWeb: allowNonWeb,
        forceConsent: false,
      );
    } catch (e) {
      return null;
    }
  }

  Future<String?> _signInOutlook({
    bool allowNonWeb = false,
    bool forceConsent = false,
  }) async {
    try {
      await _ensureOutlookOAuth(allowNonWeb: allowNonWeb);

      if (kIsWeb) {
        final token = await _signInOutlookWebWithFallback(
          forceConsent: forceConsent,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = _resolveOutlookTokenExpiry(token);
          await _saveOutlookTokenToCache(
            _outlookAccessToken!,
            _outlookTokenExpiry!,
          );
          _outlookWebRedirectInProgress = false;
          return token;
        }
        return null;
      } else {
        final result = await _outlookOAuth!.login();
        return result.fold(
          (l) {
            return null;
          },
          (r) {
            final accessToken = r.accessToken;
            if (accessToken == null || accessToken.trim().isEmpty) {
              return null;
            }
            _outlookAccessToken = accessToken;
            _outlookTokenExpiry = _resolveOutlookTokenExpiry(accessToken);
            _saveOutlookTokenToCache(
              _outlookAccessToken!,
              _outlookTokenExpiry!,
            );
            return accessToken;
          },
        );
      }
    } catch (e) {
      throw CalendarSyncException(
        'Outlook sign-in failed: $e',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }
  }

  Future<String?> _signInOutlookWebWithFallback({
    required bool forceConsent,
  }) async {
    final candidates = _buildOutlookWebConfigCandidates();
    Object? lastError;

    for (final candidate in candidates) {
      try {
        await OutlookWebAuth.instance.reset();
        await OutlookWebAuth.instance.initialize(
          clientId: candidate.clientId,
          tenantId: candidate.tenant,
          redirectUri: candidate.redirectUri,
        );
        await OutlookWebAuth.instance.handleRedirectCallback();
        final token = await OutlookWebAuth.instance.signIn(
          scopes: _outlookMsalScopes,
          useRedirect: false,
          forceConsent: forceConsent,
        );
        if (token != null && token.trim().isNotEmpty) {
          _outlookWebClientId = candidate.clientId;
          _outlookWebTenant = candidate.tenant;
          _outlookWebRedirectUri = candidate.redirectUri;
          _outlookWebRedirectInProgress = false;
          return token;
        }
        _outlookWebClientId = candidate.clientId;
        _outlookWebTenant = candidate.tenant;
        _outlookWebRedirectUri = candidate.redirectUri;
        _outlookWebRedirectInProgress = true;
        await OutlookWebAuth.instance.signIn(
          scopes: _outlookMsalScopes,
          useRedirect: true,
          forceConsent: forceConsent,
        );
        return null;
      } catch (e) {
        lastError = e;
        final lower = e.toString().toLowerCase();
        final retryable =
            lower.contains('unauthorized_client') ||
            lower.contains('not enabled for consumers') ||
            lower.contains('aadsts700016');
        final popupClosed =
            lower.contains('popup') || lower.contains('window.closed');
        if (popupClosed && !retryable) {
          _outlookWebClientId = candidate.clientId;
          _outlookWebTenant = candidate.tenant;
          _outlookWebRedirectUri = candidate.redirectUri;
          _outlookWebRedirectInProgress = true;
          await OutlookWebAuth.instance.signIn(
            scopes: _outlookMsalScopes,
            useRedirect: true,
            forceConsent: forceConsent,
          );
          return null;
        }
        if (!retryable) {
          rethrow;
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    return null;
  }

  Future<String?> signInOutlook({
    bool allowNonWeb = false,
    bool forceConsent = false,
  }) {
    return _signInOutlook(allowNonWeb: allowNonWeb, forceConsent: forceConsent);
  }

  Future<String?> _getValidOutlookToken({bool allowNonWeb = false}) async {
    // Load from cache if not in memory
    if (_outlookAccessToken == null) {
      await _loadOutlookTokenFromCache();
    }

    // Check if token is valid
    if (_outlookAccessToken != null && !_isOutlookTokenExpired()) {
      return _outlookAccessToken;
    }

    final session = Supabase.instance.client.auth.currentSession;
    final user = Supabase.instance.client.auth.currentUser;
    final providerToken = session?.providerToken;
    if (providerToken != null &&
        providerToken.isNotEmpty &&
        (_hasAuthProvider(user, 'azure') ||
            _hasAuthProvider(user, 'microsoft') ||
            _hasAuthProvider(user, 'azuread'))) {
      final exp = session?.expiresAt;
      final expiry = exp != null
          ? DateTime.fromMillisecondsSinceEpoch(
              exp * 1000,
              isUtc: true,
            ).toLocal()
          : DateTime.now().add(const Duration(minutes: 55));
      _outlookAccessToken = providerToken;
      _outlookTokenExpiry = expiry;
      await _saveOutlookTokenToCache(providerToken, expiry);
      return _outlookAccessToken;
    }

    if (!kIsWeb && allowNonWeb) {
      final azurePayload = await _ensureAzureProviderSessionPayload();
      if (azurePayload != null) {
        final token = azurePayload['token'] as String;
        final expiry = azurePayload['expiry'] as DateTime;
        _outlookAccessToken = token;
        _outlookTokenExpiry = expiry;
        await _saveOutlookTokenToCache(token, expiry);
        return token;
      }
    }

    // Token expired or missing, try to get it silently (web) or refresh (mobile)
    if (kIsWeb) {
      await _ensureOutlookOAuth();
      if (_outlookAccessToken != null && !_isOutlookTokenExpired()) {
        return _outlookAccessToken;
      }
      try {
        final token = await OutlookWebAuth.instance.getAccessToken(
          scopes: _outlookMsalScopes,
          forceRefresh: false,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = _resolveOutlookTokenExpiry(token);
          await _saveOutlookTokenToCache(
            _outlookAccessToken!,
            _outlookTokenExpiry!,
          );
          _outlookWebRedirectInProgress = false;
          return token;
        }
      } catch (e) {
        final token = await OutlookWebAuth.instance.signIn(
          scopes: _outlookMsalScopes,
          forceConsent: false,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = _resolveOutlookTokenExpiry(token);
          await _saveOutlookTokenToCache(
            _outlookAccessToken!,
            _outlookTokenExpiry!,
          );
          _outlookWebRedirectInProgress = false;
          return token;
        }
      }
      return null;
    } else {
      // Mobile: refresh token
      return await _refreshOutlookToken(allowNonWeb: allowNonWeb);
    }
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb) {
      // On Web, "permissions" are handled during the sign-in flow.
      // We return true here to allow the flow to proceed to "retrieveCalendars"
      // where the actual sign-in will happen.
      return true;
    }
    try {
      final status = await _deviceCalendar.hasPermissions();
      _trace('CalendarSyncService permission status=$status');
      if (status == CalendarPermissionStatus.granted) return true;
      final newStatus = await _deviceCalendar.requestPermissions();
      _trace('CalendarSyncService permission request result=$newStatus');
      if (newStatus == CalendarPermissionStatus.granted) {
        return true;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          const platform = MethodChannel('com.example.matchme/app_check');
          final state = await platform.invokeMapMethod<String, dynamic>(
            'getCalendarPermissionRequestState',
          );
          if (state != null) {
            final readGranted = state['readGranted'] == true;
            final writeGranted = state['writeGranted'] == true;
            final shouldShowReadRationale =
                state['shouldShowReadRationale'] == true;
            final shouldShowWriteRationale =
                state['shouldShowWriteRationale'] == true;
            _trace(
              'CalendarSyncService android permission state readGranted=$readGranted writeGranted=$writeGranted shouldShowReadRationale=$shouldShowReadRationale shouldShowWriteRationale=$shouldShowWriteRationale',
            );
            final blockedByNoRationale =
                !readGranted &&
                !writeGranted &&
                !shouldShowReadRationale &&
                !shouldShowWriteRationale;
            if (blockedByNoRationale) {
              throw CalendarSyncException(
                'Calendar permissions blocked by OS rationale state',
                userMessage: 'calendarSyncPermissionBlocked',
              );
            }
          }
        } catch (e) {
          if (e is CalendarSyncException) rethrow;
          _trace(
            'CalendarSyncService android permission state check failed: $e',
          );
        }
      }
      final fullAccessStatus = await Permission.calendarFullAccess.status;
      final writeOnlyStatus = await Permission.calendarWriteOnly.status;
      final blockedByOs =
          fullAccessStatus.isPermanentlyDenied ||
          fullAccessStatus.isRestricted ||
          writeOnlyStatus.isPermanentlyDenied ||
          writeOnlyStatus.isRestricted;
      if (blockedByOs) {
        throw CalendarSyncException(
          'Calendar permissions blocked by OS',
          userMessage: 'calendarSyncPermissionBlocked',
        );
      }
      throw CalendarSyncException(
        'Calendar permissions denied',
        userMessage: 'calendarSyncPermissionDenied',
      );
    } catch (e) {
      _trace('CalendarSyncService requestPermissions failed: $e');
      if (e is CalendarSyncException) rethrow;
      throw CalendarSyncException(
        'Permission request failed: $e',
        userMessage: 'calendarSyncPermissionFailed',
      );
    }
  }

  Future<List<ExternalCalendar>> retrieveCalendars() async {
    if (kIsWeb) {
      final payload = _googleProviderSessionPayload();
      if (payload != null) {
        final token = payload['token'] as String;
        final expiry = payload['expiry'] as DateTime;
        final userEmail = payload['userEmail'] as String?;
        await _webService.seedGoogleAccessToken(
          accessToken: token,
          expiry: expiry,
          userEmail: userEmail,
        );
        return await _webService.retrieveGoogleCalendars(
          accessTokenOverride: token,
          accountLabelOverride: userEmail,
        );
      }
      return await _webService.retrieveGoogleCalendars();
    }
    try {
      final initialPermissions = await _deviceCalendar.hasPermissions();
      _trace(
        'CalendarSyncService initial permission status=$initialPermissions',
      );
      final permissionsWereMissing =
          initialPermissions != CalendarPermissionStatus.granted;

      final permissionsGranted = await requestPermissions();
      if (!permissionsGranted) return <ExternalCalendar>[];

      // If we just requested permissions, add a small delay to allow OS to propagate changes
      if (permissionsWereMissing) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      var calendars = await _deviceCalendar.listCalendars();
      _trace('CalendarSyncService listCalendars count=${calendars.length}');

      if (calendars.isEmpty && permissionsWereMissing) {
        await Future.delayed(const Duration(milliseconds: 500));
        calendars = await _deviceCalendar.listCalendars();
        _trace(
          'CalendarSyncService listCalendars retry count=${calendars.length}',
        );
      }

      final mapped = calendars.where((c) => c.id.trim().isNotEmpty).map((c) {
        return ExternalCalendar(
          id: c.id.trim(),
          name: c.name.trim().isNotEmpty ? c.name.trim() : 'Calendar',
          isReadOnly: c.readOnly,
          isDefault: c.isPrimary,
          accountName: c.accountName,
          accountType: c.accountType,
        );
      }).toList();
      for (final c in mapped) {
        _trace(
          'CalendarSyncService calendar id=${c.id} name=${c.name} accountName=${c.accountName ?? ''} accountType=${c.accountType ?? ''} isDefault=${c.isDefault}',
        );
      }
      return mapped;
    } catch (e) {
      _trace('CalendarSyncService retrieveCalendars failed: $e');
      if (e is CalendarSyncException) {
        rethrow;
      }
      throw CalendarSyncException(
        'Failed to retrieve device calendars: $e',
        userMessage: 'calendarSyncUnexpectedError',
      );
    }
  }

  Future<List<ExternalCalendar>> retrieveGoogleCalendarsNonWebOAuth() async {
    final payload = await _getGoogleImportSessionPayload();
    if (payload != null) {
      final token = payload['token'] as String;
      final expiry = payload['expiry'] as DateTime;
      final userEmail = payload['userEmail'] as String?;
      await _webService.seedGoogleAccessToken(
        accessToken: token,
        expiry: expiry,
        userEmail: userEmail,
      );
      return _webService.retrieveGoogleCalendars(
        accessTokenOverride: token,
        accountLabelOverride: userEmail,
      );
    }
    throw CalendarSyncException(
      'Google authentication failed: no provider token available',
      userMessage: 'calendarSyncGoogleAuthRequired',
      isAuthError: true,
    );
  }

  Future<List<ExternalEvent>> retrieveGoogleEventsNonWebOAuth(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final start = startDate ?? DateTime.now();
    final end = endDate ?? DateTime.now().add(const Duration(days: 30));
    final payload = await _getGoogleImportSessionPayload();
    if (payload != null) {
      final token = payload['token'] as String;
      final expiry = payload['expiry'] as DateTime;
      final userEmail = payload['userEmail'] as String?;
      await _webService.seedGoogleAccessToken(
        accessToken: token,
        expiry: expiry,
        userEmail: userEmail,
      );
      return _webService.retrieveGoogleEvents(
        calendarId,
        start,
        end,
        accessTokenOverride: token,
      );
    }
    throw CalendarSyncException(
      'Google authentication failed: no provider token available',
      userMessage: 'calendarSyncGoogleAuthRequired',
      isAuthError: true,
    );
  }

  Future<List<ExternalEvent>> retrieveEvents(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final start = startDate ?? DateTime.now();
    final end = endDate ?? DateTime.now().add(const Duration(days: 30));

    if (kIsWeb) {
      final payload = _googleProviderSessionPayload();
      if (payload != null) {
        final token = payload['token'] as String;
        final expiry = payload['expiry'] as DateTime;
        final userEmail = payload['userEmail'] as String?;
        await _webService.seedGoogleAccessToken(
          accessToken: token,
          expiry: expiry,
          userEmail: userEmail,
        );
        return await _webService.retrieveGoogleEvents(
          calendarId,
          start,
          end,
          accessTokenOverride: token,
        );
      }
      return await _webService.retrieveGoogleEvents(calendarId, start, end);
    }

    try {
      final events = await _deviceCalendar.listEvents(
        start,
        end,
        calendarIds: [calendarId],
      );
      _trace(
        'CalendarSyncService listEvents calendarId=$calendarId count=${events.length}',
      );

      return events.where((e) => e.instanceId.trim().isNotEmpty).map((e) {
        return ExternalEvent(
          calendarId: e.calendarId,
          id: e.instanceId,
          title: e.title.trim().isNotEmpty ? e.title.trim() : 'No Title',
          start: e.startDate,
          end: e.endDate,
          description: e.description,
          isAllDay: e.isAllDay,
          location: e.location,
          url: null,
          organizer: null,
        );
      }).toList();
    } catch (e) {
      _trace(
        'CalendarSyncService retrieveEvents failed calendarId=$calendarId error=$e',
      );
      return [];
    }
  }

  Future<Map<String, dynamic>> _fetchApplePublicCalendarPayload(
    String publicCalendarUrl, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final raw = publicCalendarUrl.trim();
    if (raw.isEmpty) {
      throw CalendarSyncException(
        'Apple public calendar URL is required',
        userMessage: 'calendarSyncApplePublicUrlRequired',
      );
    }
    final normalized = raw.toLowerCase().startsWith('webcal://')
        ? 'https://${raw.substring('webcal://'.length)}'
        : raw;
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw CalendarSyncException(
        'Apple public calendar URL is invalid',
        userMessage: 'calendarSyncApplePublicUrlInvalid',
      );
    }
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'fetch-public-calendar-ics',
        body: {
          'url': uri.toString(),
          'startDate': startDate?.toUtc().toIso8601String(),
          'endDate': endDate?.toUtc().toIso8601String(),
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw CalendarSyncException(
          'Apple public calendar function returned invalid data',
          userMessage: 'calendarSyncApplePublicFetchFailed',
          isNetworkError: true,
        );
      }
      return data;
    } on TimeoutException catch (e) {
      throw CalendarSyncException(
        'Apple public calendar timeout: $e',
        userMessage: 'calendarSyncTimeout',
        isNetworkError: true,
      );
    } on http.ClientException catch (e) {
      throw CalendarSyncException(
        'Apple public calendar network error: $e',
        userMessage: 'calendarSyncNetworkError',
        isNetworkError: true,
      );
    } catch (e) {
      if (e is CalendarSyncException) rethrow;
      throw CalendarSyncException(
        'Apple public calendar fetch failed: $e',
        userMessage: 'calendarSyncApplePublicFetchFailed',
        isNetworkError: true,
      );
    }
  }

  Future<List<ExternalCalendar>> retrieveApplePublicCalendars(
    String publicCalendarUrl,
  ) async {
    final data = await _fetchApplePublicCalendarPayload(publicCalendarUrl);
    final rawCalendar = data['calendar'];
    if (rawCalendar is! Map<String, dynamic>) {
      throw CalendarSyncException(
        'Apple public calendar payload missing calendar',
        userMessage: 'calendarSyncApplePublicFetchFailed',
      );
    }
    final id = (rawCalendar['id'] as String?)?.trim().isNotEmpty == true
        ? (rawCalendar['id'] as String).trim()
        : publicCalendarUrl.trim();
    final name = (rawCalendar['name'] as String?)?.trim().isNotEmpty == true
        ? (rawCalendar['name'] as String).trim()
        : 'Apple Public Calendar';
    return [
      ExternalCalendar(
        id: id,
        name: name,
        isReadOnly: true,
        isDefault: true,
        accountName: name,
        accountType: 'apple_public_ics',
      ),
    ];
  }

  Future<List<ExternalEvent>> retrieveApplePublicEvents(
    String publicCalendarUrl, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final data = await _fetchApplePublicCalendarPayload(
      publicCalendarUrl,
      startDate: startDate,
      endDate: endDate,
    );
    final rawEvents = data['events'];
    if (rawEvents is! List) {
      return <ExternalEvent>[];
    }
    final calendarId = publicCalendarUrl.trim();
    final events = <ExternalEvent>[];
    for (final item in rawEvents) {
      if (item is! Map<String, dynamic>) continue;
      final id = (item['id'] as String?)?.trim();
      if (id == null || id.isEmpty) continue;
      final title = (item['title'] as String?)?.trim();
      final startRaw = item['start'] as String?;
      final endRaw = item['end'] as String?;
      final start = startRaw != null ? DateTime.tryParse(startRaw) : null;
      final end = endRaw != null ? DateTime.tryParse(endRaw) : null;
      final normalizedStart = start?.isUtc == true ? start!.toLocal() : start;
      final normalizedEnd = end?.isUtc == true ? end!.toLocal() : end;
      events.add(
        ExternalEvent(
          calendarId: calendarId,
          id: id,
          title: title != null && title.isNotEmpty
              ? title
              : 'Apple Calendar Event',
          start: normalizedStart,
          end: normalizedEnd,
          description: (item['description'] as String?)?.trim(),
          isAllDay: item['isAllDay'] == true,
          location: (item['location'] as String?)?.trim(),
          url: Uri.tryParse((item['url'] as String?) ?? ''),
          organizer: (item['organizer'] as String?)?.trim(),
        ),
      );
    }
    return events;
  }

  Future<List<ExternalCalendar>> retrieveOutlookCalendars({
    bool allowNonWeb = false,
  }) async {
    if (!kIsWeb && !allowNonWeb) {
      throw CalendarSyncException(
        'Outlook OAuth is only available on web platform. Use device calendars on mobile.',
        userMessage: 'calendarSyncOutlookWebOnly',
      );
    }

    final token = await _getValidOutlookToken(allowNonWeb: allowNonWeb);
    if (token == null) {
      if (kIsWeb && _outlookWebRedirectInProgress) {
        return [];
      }
      throw CalendarSyncException(
        'Outlook authentication failed',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    try {
      final timeoutSeconds = await _outlookTimeoutSeconds();
      final calendars = <ExternalCalendar>[];
      Uri? nextUri = _buildOutlookCalendarsUri();

      do {
        final response = await http
            .get(nextUri!, headers: _outlookHeaders(token))
            .timeout(Duration(seconds: timeoutSeconds));

        if (response.statusCode == 401) {
          final newToken = await _refreshOutlookToken(allowNonWeb: allowNonWeb);
          if (newToken == null) {
            throw CalendarSyncException(
              'Outlook authentication expired',
              userMessage: 'calendarSyncOutlookExpired',
              isAuthError: true,
            );
          }
          return await retrieveOutlookCalendars(allowNonWeb: allowNonWeb);
        }

        if (response.statusCode != 200) {
          throw CalendarSyncException(
            'Outlook API error: ${response.statusCode}',
            userMessage: 'calendarSyncOutlookFailed',
          );
        }

        final data = json.decode(response.body) as Map<String, dynamic>;
        final List<dynamic> items = data['value'] as List<dynamic>? ?? [];

        calendars.addAll(
          items.map((item) {
            final map = item as Map<String, dynamic>;
            final owner = map['owner'] as Map<String, dynamic>?;
            final ownerAddress = owner != null
                ? owner['address'] as String?
                : null;
            final id = (map['id'] as String?)?.trim();
            if (id == null || id.isEmpty) return null;
            return ExternalCalendar(
              id: id,
              name: (map['name'] as String?)?.trim().isNotEmpty == true
                  ? (map['name'] as String).trim()
                  : 'Outlook Calendar',
              isReadOnly: !(map['canEdit'] == true),
              isDefault: map['isDefaultCalendar'] == true,
              accountName: ownerAddress ?? 'Outlook',
              accountType: 'com.microsoft.outlook',
            );
          }).whereType<ExternalCalendar>(),
        );

        final nextLink = data['@odata.nextLink'] as String?;
        nextUri = (nextLink != null && nextLink.trim().isNotEmpty)
            ? Uri.tryParse(nextLink)
            : null;
      } while (nextUri != null);

      return calendars;
    } on http.ClientException catch (e) {
      throw CalendarSyncException(
        'Network error: $e',
        userMessage: 'calendarSyncNetworkError',
        isNetworkError: true,
      );
    } on TimeoutException catch (e) {
      throw CalendarSyncException(
        'Request timeout: $e',
        userMessage: 'calendarSyncTimeout',
        isNetworkError: true,
      );
    } catch (e) {
      if (e is CalendarSyncException) rethrow;
      throw CalendarSyncException(
        'Failed to retrieve Outlook calendars: $e',
        userMessage: 'calendarSyncUnexpectedError',
      );
    }
  }

  /// Explicit Outlook OAuth retrieval for non-web platforms (mobile/desktop)
  Future<List<ExternalCalendar>> retrieveOutlookCalendarsNonWebOAuth() async {
    return retrieveOutlookCalendars(allowNonWeb: true);
  }

  Future<List<ExternalEvent>> retrieveOutlookEvents(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
    bool allowNonWeb = false,
  }) async {
    if (!kIsWeb && !allowNonWeb) {
      throw CalendarSyncException(
        'Outlook OAuth is only available on web platform. Use device calendars on mobile.',
        userMessage: 'calendarSyncOutlookWebOnly',
      );
    }
    final token = await _getValidOutlookToken(allowNonWeb: allowNonWeb);
    if (token == null) {
      if (kIsWeb && _outlookWebRedirectInProgress) {
        return [];
      }
      throw CalendarSyncException(
        'Outlook authentication failed',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    final start = (startDate ?? DateTime.now()).toUtc();
    final end = (endDate ?? DateTime.now().add(const Duration(days: 30)))
        .toUtc();

    final startIso = start.toIso8601String();
    final endIso = end.toIso8601String();

    try {
      final timeoutSeconds = await _outlookTimeoutSeconds();
      final allEvents = <ExternalEvent>[];
      Uri? nextUri = _buildOutlookCalendarViewUri(
        calendarId: calendarId,
        startIso: startIso,
        endIso: endIso,
      );

      do {
        final response = await http
            .get(nextUri!, headers: _outlookHeaders(token))
            .timeout(Duration(seconds: timeoutSeconds));

        if (response.statusCode == 401) {
          final newToken = await _refreshOutlookToken(allowNonWeb: allowNonWeb);
          if (newToken == null) {
            throw CalendarSyncException(
              'Outlook authentication expired',
              userMessage: 'calendarSyncOutlookExpired',
              isAuthError: true,
            );
          }
          return await retrieveOutlookEvents(
            calendarId,
            startDate: startDate,
            endDate: endDate,
            allowNonWeb: allowNonWeb,
          );
        }

        if (response.statusCode != 200) {
          throw CalendarSyncException(
            'Outlook API error: ${response.statusCode}',
            userMessage: 'calendarSyncOutlookEventsFailed',
          );
        }

        final data = json.decode(response.body) as Map<String, dynamic>;
        final List<dynamic> items = data['value'] as List<dynamic>? ?? [];

        allEvents.addAll(
          items.map((item) {
            final map = item as Map<String, dynamic>;
            final startObj = map['start'] as Map<String, dynamic>?;
            final endObj = map['end'] as Map<String, dynamic>?;

            DateTime? parseDate(Map<String, dynamic>? obj) {
              if (obj == null) return null;
              final dateTime = obj['dateTime'] as String?;
              if (dateTime == null) return null;
              final hasOffset = RegExp(
                r'(Z|[+-]\d{2}:\d{2})$',
              ).hasMatch(dateTime);
              if (hasOffset) {
                return DateTime.tryParse(dateTime);
              }
              final timeZone = (obj['timeZone'] as String?)
                  ?.trim()
                  .toUpperCase();
              if (timeZone == 'UTC') {
                return DateTime.tryParse('${dateTime}Z');
              }
              return DateTime.tryParse(dateTime);
            }

            final startDt = parseDate(startObj);
            final endDt = parseDate(endObj);
            final isAllDay = map['isAllDay'] == true;

            DateTime? normalizeDate(DateTime? dt) {
              if (dt == null) return null;
              if (isAllDay) return DateTime(dt.year, dt.month, dt.day);
              return dt.isUtc ? dt.toLocal() : dt;
            }

            final id = (map['id'] as String?)?.trim();
            if (id == null || id.isEmpty) return null;

            return ExternalEvent(
              calendarId: calendarId,
              id: id,
              title: (map['subject'] as String?)?.trim().isNotEmpty == true
                  ? (map['subject'] as String).trim()
                  : 'No Title',
              start: normalizeDate(startDt),
              end: normalizeDate(endDt),
              description: map['bodyPreview'] as String?,
              isAllDay: isAllDay,
              location:
                  (map['location'] as Map<String, dynamic>?)?['displayName']
                      as String?,
              url: Uri.tryParse((map['webLink'] as String?) ?? ''),
              organizer:
                  ((map['organizer'] as Map<String, dynamic>?)?['emailAddress']
                          as Map<String, dynamic>?)?['address']
                      as String?,
            );
          }).whereType<ExternalEvent>(),
        );

        final nextLink = data['@odata.nextLink'] as String?;
        nextUri = (nextLink != null && nextLink.trim().isNotEmpty)
            ? Uri.tryParse(nextLink)
            : null;
      } while (nextUri != null);

      return allEvents;
    } on http.ClientException catch (e) {
      throw CalendarSyncException(
        'Network error: $e',
        userMessage: 'calendarSyncNetworkError',
        isNetworkError: true,
      );
    } on TimeoutException catch (e) {
      throw CalendarSyncException(
        'Request timeout: $e',
        userMessage: 'calendarSyncTimeout',
        isNetworkError: true,
      );
    } catch (e) {
      if (e is CalendarSyncException) rethrow;
      throw CalendarSyncException(
        'Failed to retrieve Outlook events: $e',
        userMessage: 'calendarSyncUnexpectedError',
      );
    }
  }

  Future<List<ExternalEvent>> retrieveOutlookEventsNonWebOAuth(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
  }) {
    return retrieveOutlookEvents(
      calendarId,
      startDate: startDate,
      endDate: endDate,
      allowNonWeb: true,
    );
  }
}
