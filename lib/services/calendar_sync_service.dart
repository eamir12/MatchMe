import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:matchme/main.dart' show navigatorKey;
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/utils/event_import_classifier.dart';
import 'package:msal_auth/msal_auth.dart';
import 'package:aad_oauth/aad_oauth.dart';
import 'package:aad_oauth/model/config.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/sensitive_session_store.dart';
import 'package:matchme/services/auth_transition_guard.dart';
import 'package:matchme/services/oauth_loopback_server.dart';
import 'package:matchme/utils/desktop_window_focus.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/services/outlook_web_auth.dart'
    if (dart.library.io) 'package:matchme/services/outlook_web_auth_stub.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  static String? _googleImportAccessToken;
  static DateTime? _googleImportTokenExpiry;
  static String? _googleImportUserEmail;
  static bool _didLoadGoogleImportTokenCache = false;
  static bool _googleImportOAuthInProgress = false;
  static String? _googleImportOAuthError;
  static const String _outlookTokenKey = 'outlook_access_token';
  static const String _outlookTokenExpiryKey = 'outlook_token_expiry';
  static String? _outlookImportAccessToken;
  static DateTime? _outlookImportTokenExpiry;
  static String? _outlookImportUserEmail;
  static bool _didLoadOutlookImportTokenCache = false;
  static const String _outlookImportTokenKey = 'outlook_import_access_token';
  static const String _outlookImportTokenExpiryKey =
      'outlook_import_token_expiry';
  static const String _outlookImportUserEmailKey = 'outlook_import_user_email';
  static const String _googleImportTokenKey = 'google_import_access_token';
  static const String _googleImportTokenExpiryKey =
      'google_import_access_token_expiry';
  static const String _googleImportUserEmailKey = 'google_import_user_email';
  static const String _googleImportOAuthInProgressKey =
      'google_import_oauth_in_progress';
  static const String _googleImportOAuthErrorKey = 'google_import_oauth_error';
  // NOTE: legacy plain-prefs OAuth temp keys ('oauth_original_session_json',
  // 'oauth_original_user_id') were migrated to SensitiveSessionStore/
  // SecureStorage. Do not reintroduce plain writes.
  static const String _googleSwitchFlowIdKey = 'google_switch_flow_id';
  static const String _googleSwitchCompletedFlowIdKey =
      'google_switch_completed_flow_id';
  static const List<String> _outlookMsalScopes = [
    'User.Read',
    'Calendars.Read',
    'offline_access',
  ];
  static const List<String> _outlookNativeMsalScopes = [
    'User.Read',
    'Calendars.Read',
  ];
  String? _outlookWebClientId;
  String? _outlookWebTenant;
  String? _outlookWebRedirectUri;
  bool _outlookWebRedirectInProgress = false;

  /// Read a sensitive value from SecureStorage, falling back to legacy
  /// plain SharedPreferences for previously-migrated data.
  static Future<String?> _secureRead(String key) async {
    try {
      final value = await SecureStorageService.instance.read(key);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {}
    return null;
  }

  /// Write a sensitive value to SecureStorage and remove any legacy plain
  /// SharedPreferences copy.
  static Future<void> _secureWrite(String key, String value) async {
    try {
      await SecureStorageService.instance.write(key, value);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) await prefs.remove(key);
    } catch (_) {}
  }

  /// Delete a sensitive value from both SecureStorage and SharedPreferences.
  static Future<void> _secureDelete(String key) async {
    try {
      await SecureStorageService.instance.delete(key);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) await prefs.remove(key);
    } catch (_) {}
  }

  static SingleAccountPca? _outlookNativeClient;
  static String? _outlookNativeClientId;
  static String? _outlookNativeClientRedirectUri;
  static String? _outlookNativeAccessToken;
  static DateTime? _outlookNativeTokenExpiry;
  static String? _outlookNativeUserEmail;

  /// Wipe all persisted calendar OAuth credentials (tokens, expiries, user
  /// emails) from SecureStorage and legacy SharedPreferences, and reset the
  /// static in-memory token caches. Called on explicit logout and on account
  /// deletion so the next account on this device never inherits them.
  static Future<void> clearPersistedCalendarCredentials() async {
    await _secureDelete(_googleImportTokenKey);
    await _secureDelete(_googleImportTokenExpiryKey);
    await _secureDelete(_googleImportUserEmailKey);
    await _secureDelete(_outlookImportTokenKey);
    await _secureDelete(_outlookImportTokenExpiryKey);
    await _secureDelete(_outlookImportUserEmailKey);
    await _secureDelete(_outlookTokenKey);
    await _secureDelete(_outlookTokenExpiryKey);
    _googleImportAccessToken = null;
    _googleImportTokenExpiry = null;
    _googleImportUserEmail = null;
    _outlookImportAccessToken = null;
    _outlookImportTokenExpiry = null;
    _outlookImportUserEmail = null;
    _didLoadGoogleImportTokenCache = false;
    _didLoadOutlookImportTokenCache = false;
  }

  CalendarSyncService();

  WebCalendarService get webService => _webService;

  void _trace(String message) {
    print(message);
    developer.log(message, name: 'CalendarSyncService');
  }

  LaunchMode get _mobileOAuthLaunchMode {
    if (kIsWeb) {
      return LaunchMode.platformDefault;
    }
    return LaunchMode.platformDefault;
  }

  /// Whether a `com.example.matchme://login-callback` redirect can reach this
  /// app at all.
  ///
  /// It cannot: this project registers no protocol handler for Windows/Linux,
  /// and macOS declares no `CFBundleURLSchemes` in its Info.plist. So a
  /// custom-scheme OAuth redirect always dead-ends in the browser there, and
  /// desktop must use the RFC 8252 loopback listener instead.
  static bool get _hasNoCustomSchemeCallback {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// Google needs the loopback flow only where `google_sign_in` has no
  /// implementation at all. macOS keeps its native SDK, which works.
  static bool get _useLoopbackGoogleOAuth {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  /// Outlook needs it on every desktop target, because the "native" MSAL path
  /// is hardcoded to `AndroidConfig` and cannot run on any of them.
  static bool get _useLoopbackOutlookOAuth => _hasNoCustomSchemeCallback;

  /// Whether device-calendar import is available on this platform.
  ///
  /// `device_calendar_plus` ships Android and iOS implementations **only**. On
  /// web, Windows, macOS and Linux its `DeviceCalendarPlusPlatform.instance` is
  /// left uninitialised, so every call throws
  /// `Bad state: DeviceCalendarPlusPlatform.instance has not been initialized`.
  /// UI must use this to hide the option instead of offering it and letting it
  /// fail, and the device operations themselves assert on it.
  static bool get isDeviceCalendarSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// Cancels a pending loopback calendar OAuth when the user returns to the app
  /// without the browser having delivered a code.
  _CalendarOAuthCancellation? _calendarOAuthCancellation;

  /// Watches for the user coming back to the app mid-flow so a pending loopback
  /// sign-in can stop waiting instead of sitting on a spinner. Scoped to the
  /// duration of a single attempt rather than registered for the service's
  /// lifetime.
  AppLifecycleListener? _calendarLifecycleListener;

  /// Upper bound on a loopback calendar sign-in. The user is completing a
  /// provider consent screen by hand, so this is generous; returning to the app
  /// normally ends the wait much sooner.
  static const Duration _loopbackOAuthTimeout = Duration(minutes: 5);

  /// Grace period after the user returns before a pending loopback sign-in is
  /// treated as abandoned - the browser hitting the callback and focus
  /// returning can land within milliseconds of each other.
  static const Duration _loopbackOAuthResumeGrace = Duration(seconds: 2);

  bool _isGoogleSignInCancelled(Object error) {
    if (error is! GoogleSignInException ||
        error.code != GoogleSignInExceptionCode.canceled) {
      return false;
    }
    final text = error.toString().toLowerCase();
    return !text.contains('credential') &&
        !text.contains('framework') &&
        !text.contains('reauth') &&
        !text.contains('no credential') &&
        !text.contains('unknownerror');
  }

  bool _isGoogleSignInConfigError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('clientconfiguration') ||
        text.contains('developer error') ||
        text.contains('10:') ||
        text.contains('16:');
  }

  bool _looksLikeGoogleAccessBlockedError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('access blocked') ||
        text.contains('has not completed the google verification process') ||
        text.contains('developer-approved testers') ||
        text.contains('error 403: access_denied') ||
        text.contains('403: access_denied') ||
        text.contains('app is blocked');
  }

  CalendarSyncException _mapGoogleSignInFailure(
    Object error, {
    required bool duringSwitch,
  }) {
    if (_looksLikeGoogleAccessBlockedError(error)) {
      return CalendarSyncException('');
    }
    if (_isGoogleSignInConfigError(error)) {
      return CalendarSyncException('');
    }
    if (_looksLikeGooglePermissionError(error)) {
      return CalendarSyncException(
        duringSwitch
            ? 'Google account switch permission denied: $error'
            : 'Google calendar permission denied: $error',
        userMessage: 'calendarSyncGooglePermissionDenied',
        isAuthError: true,
      );
    }
    return CalendarSyncException(
      duringSwitch
          ? 'Google account switch failed: $error'
          : 'Google authentication failed: $error',
      userMessage: 'calendarSyncGoogleAuthRequired',
      isAuthError: true,
    );
  }

  static Future<Map<String, dynamic>?> getCachedGoogleImportPayload() async {
    final token = _googleImportAccessToken?.trim();
    final expiry = _googleImportTokenExpiry;
    if (token == null || token.isEmpty || expiry == null) {
      debugPrint(
        '[CalendarSync] getCachedGoogleImportPayload -> null '
        '(token=${token == null ? 'NULL' : (token.isEmpty ? 'EMPTY' : 'len ${token.length}')}, '
        'expiry=$expiry, loaded=$_didLoadGoogleImportTokenCache)',
      );
      return null;
    }
    final buffer = await (() async {
      try {
        return await appConfigService.getDuration(
          'calendar.token_refresh_buffer_seconds',
          defaultValue: const Duration(minutes: 5),
        );
      } catch (e) {
        return const Duration(minutes: 5);
      }
    })();
    if (DateTime.now().isAfter(expiry.subtract(buffer))) {
      debugPrint(
        '[CalendarSync] getCachedGoogleImportPayload -> null (token expired: '
        'expiry=$expiry, buffer=${buffer.inMinutes}m, now=${DateTime.now()})',
      );
      return null;
    }
    return {
      'token': token,
      'expiry': expiry,
      'userEmail': _googleImportUserEmail,
    };
  }

  static Future<String?> getCachedGoogleImportEmailFromPrefs() async {
    try {
      final token = await _secureRead(_googleImportTokenKey);
      final expiry = await _secureRead(_googleImportTokenExpiryKey);
      if (token == null || token.isEmpty || expiry == null) {
        return null;
      }
      final expiryDate = DateTime.tryParse(expiry);
      if (expiryDate == null) {
        return null;
      }
      if (DateTime.now().isAfter(
        expiryDate.subtract(
          await (() async {
            try {
              return await appConfigService.getDuration(
                'calendar.token_refresh_buffer_seconds',
                defaultValue: const Duration(minutes: 5),
              );
            } catch (e) {
              return const Duration(minutes: 5);
            }
          })(),
        ),
      )) {
        return null;
      }
      return await _secureRead(_googleImportUserEmailKey);
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasGoogleImportSessionPayload() async {
    await _loadGoogleImportTokenFromCache();
    return await CalendarSyncService.getCachedGoogleImportPayload() != null;
  }

  Future<bool> hasOutlookImportSessionPayload() async {
    await _loadOutlookImportTokenFromCache();
    return await _getCachedOutlookImportPayload() != null;
  }

  Future<List<String>> listAvailableGoogleImportAccounts() async {
    final emails = <String>{};
    await _loadGoogleImportTokenFromCache();

    final cachedPayload =
        await CalendarSyncService.getCachedGoogleImportPayload();
    final cachedEmail = (cachedPayload?['userEmail'] as String?)?.trim();
    if (cachedEmail != null && cachedEmail.isNotEmpty) {
      emails.add(cachedEmail);
    }

    final webEmails = await _webService.listAvailableGoogleAccountEmails();
    for (final email in webEmails) {
      final normalized = email.trim();
      if (normalized.isNotEmpty) {
        emails.add(normalized);
      }
    }

    return emails.toList()..sort();
  }

  Future<List<String>> listAvailableOutlookImportAccounts({
    bool allowNonWeb = false,
  }) async {
    final emails = <String>{};
    await _loadOutlookImportTokenFromCache();

    final cachedPayload = await _getCachedOutlookImportPayload();
    final cachedEmail = (cachedPayload?['userEmail'] as String?)?.trim();
    if (cachedEmail != null && cachedEmail.isNotEmpty) {
      emails.add(cachedEmail);
    }

    if (kIsWeb) {
      await _ensureOutlookOAuth();
      for (final account in OutlookWebAuth.instance.listAccounts()) {
        final username = account.username.trim();
        if (username.isNotEmpty) {
          emails.add(username);
        }
      }
    } else if (allowNonWeb) {
      final currentEmail = await _getOutlookNativeCurrentAccountEmail();
      if (currentEmail != null && currentEmail.isNotEmpty) {
        emails.add(currentEmail);
      }
    }

    return emails.toList()..sort();
  }

  static Future<void> beginGoogleImportOAuthFlow() async {
    _googleImportOAuthInProgress = true;
    _googleImportOAuthError = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_googleImportOAuthInProgressKey, true);
      await prefs.remove(_googleImportOAuthErrorKey);
    } catch (_) {}
  }

  static Future<void> failGoogleImportOAuthFlow(String error) async {
    _googleImportOAuthInProgress = false;
    _googleImportOAuthError = error.trim().isEmpty
        ? 'oauth_error'
        : error.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_googleImportOAuthInProgressKey);
      await prefs.setString(
        _googleImportOAuthErrorKey,
        _googleImportOAuthError!,
      );
    } catch (_) {}
  }

  static Future<void> endGoogleImportOAuthFlow() async {
    _googleImportOAuthInProgress = false;
    _googleImportOAuthError = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_googleImportOAuthInProgressKey);
      await prefs.remove(_googleImportOAuthErrorKey);
    } catch (_) {}
  }

  static bool shouldAbortGoogleImportOAuthWait() {
    if (!_googleImportOAuthInProgress) {
      return false;
    }
    return _googleImportOAuthError != null &&
        _googleImportOAuthError!.isNotEmpty;
  }

  static Future<void> cacheGoogleImportToken({
    required String token,
    required DateTime expiry,
    String? userEmail,
  }) async {
    final normalizedToken = token.trim();
    final normalizedEmail = userEmail?.trim();
    _didLoadGoogleImportTokenCache = true;

    if (normalizedToken.isEmpty) {
      _googleImportAccessToken = null;
      _googleImportTokenExpiry = null;
      _googleImportUserEmail = null;
      try {
        await _secureDelete(_googleImportTokenKey);
        await _secureDelete(_googleImportTokenExpiryKey);
        await _secureDelete(_googleImportUserEmailKey);
      } catch (_) {}
      return;
    }

    _googleImportAccessToken = normalizedToken;
    _googleImportTokenExpiry = expiry;
    _googleImportUserEmail =
        normalizedEmail != null && normalizedEmail.isNotEmpty
        ? normalizedEmail
        : null;

    try {
      await _secureWrite(_googleImportTokenKey, normalizedToken);
      await _secureWrite(_googleImportTokenExpiryKey, expiry.toIso8601String());
      if (_googleImportUserEmail != null) {
        await _secureWrite(_googleImportUserEmailKey, _googleImportUserEmail!);
      } else {
        await _secureDelete(_googleImportUserEmailKey);
      }
    } catch (_) {}
  }

  static Future<void> clearGoogleImportTokenCache() async {
    await cacheGoogleImportToken(
      token: '',
      expiry: DateTime.now(),
      userEmail: null,
    );
  }

  static Future<void> cacheOutlookImportToken({
    required String token,
    required DateTime expiry,
    String? userEmail,
  }) async {
    final normalizedToken = token.trim();
    final normalizedEmail = userEmail?.trim();
    _didLoadOutlookImportTokenCache = true;

    if (normalizedToken.isEmpty) {
      _outlookImportAccessToken = null;
      _outlookImportTokenExpiry = null;
      _outlookImportUserEmail = null;
      try {
        await _secureDelete(_outlookImportTokenKey);
        await _secureDelete(_outlookImportTokenExpiryKey);
        await _secureDelete(_outlookImportUserEmailKey);
      } catch (_) {}
      return;
    }

    _outlookImportAccessToken = normalizedToken;
    _outlookImportTokenExpiry = expiry;
    _outlookImportUserEmail =
        normalizedEmail != null && normalizedEmail.isNotEmpty
        ? normalizedEmail
        : null;

    try {
      await _secureWrite(_outlookImportTokenKey, normalizedToken);
      await _secureWrite(
        _outlookImportTokenExpiryKey,
        expiry.toIso8601String(),
      );
      if (_outlookImportUserEmail != null) {
        await _secureWrite(
          _outlookImportUserEmailKey,
          _outlookImportUserEmail!,
        );
      } else {
        await _secureDelete(_outlookImportUserEmailKey);
      }
    } catch (_) {}
  }

  static Future<void> clearOutlookImportTokenCache() async {
    await cacheOutlookImportToken(
      token: '',
      expiry: DateTime.now(),
      userEmail: null,
    );
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

  bool _looksLikeGoogleAuthError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('401') ||
        text.contains('unauthorized') ||
        text.contains('invalid authentication credentials') ||
        text.contains('authentication failed') ||
        text.contains('google authentication failed') ||
        text.contains('calendarsyncgoogleauthrequired') ||
        text.contains('login cookie') ||
        text.contains('oauth 2 access token');
  }

  bool _looksLikeGooglePermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('403') ||
        text.contains('insufficient authentication scopes') ||
        text.contains('insufficientpermissions') ||
        text.contains('insufficient permissions') ||
        text.contains('permission denied') ||
        text.contains('access_denied') ||
        text.contains('access denied') ||
        text.contains('forbidden');
  }

  bool _looksLikeOutlookPermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('403') ||
        text.contains('forbidden') ||
        text.contains('access_denied') ||
        text.contains('access denied') ||
        text.contains('authorization_request_denied') ||
        text.contains('insufficient privileges') ||
        text.contains('insufficient_privileges') ||
        text.contains('consent_required') ||
        text.contains('need admin approval') ||
        text.contains('has not consented') ||
        text.contains('not consented') ||
        text.contains('aadsts65001') ||
        text.contains('aadsts65004');
  }

  bool _looksLikeOutlookSignInCancelled(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('cancel') ||
        text.contains('canceled') ||
        text.contains('cancelled') ||
        text.contains('user_cancelled') ||
        text.contains('authentication canceled') ||
        text.contains('authentication cancelled');
  }

  bool _isOutlookNotConfiguredError(Object error) {
    if (error is CalendarSyncException) {
      return error.userMessage == 'calendarSyncOutlookNotConfigured';
    }
    final text = error.toString().toLowerCase();
    return text.contains('outlook oauth configuration is missing') ||
        text.contains('outlook native android configuration is missing');
  }

  CalendarSyncException _mapGoogleAccessFailure(
    Object error, {
    required String action,
  }) {
    if (error is CalendarSyncException) {
      return error;
    }
    if (_looksLikeGooglePermissionError(error)) {
      return CalendarSyncException(
        'Google calendar permission denied while trying to $action: $error',
        userMessage: 'calendarSyncGooglePermissionDenied',
        isAuthError: true,
      );
    }
    if (_looksLikeGoogleAuthError(error)) {
      return CalendarSyncException(
        'Google authentication failed while trying to $action: $error',
        userMessage: 'calendarSyncGoogleAuthRequired',
        isAuthError: true,
      );
    }
    return CalendarSyncException(
      'Google calendar request failed while trying to $action: $error',
      userMessage: 'calendarSyncUnexpectedError',
    );
  }

  String? _extractGoogleIdentityEmail(User? user) {
    final identities = user?.identities;
    if (identities == null) return null;
    for (final identity in identities) {
      if (identity.provider == 'google' && identity.identityData != null) {
        final data = identity.identityData as Map<String, dynamic>;
        final email = (data['email'] as String?)?.trim();
        if (email != null && email.isNotEmpty) return email;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _googlePayloadFromSession(
    Session? session,
  ) async {
    final user = session?.user;
    final token = session?.providerToken?.trim();

    if (token != null && token.isNotEmpty && _hasAuthProvider(user, 'google')) {
      final exp = session?.expiresAt;
      final expiry = exp != null
          ? DateTime.fromMillisecondsSinceEpoch(
              exp * 1000,
              isUtc: true,
            ).toLocal()
          : DateTime.now().add(
              await (() async {
                try {
                  return await appConfigService.getDuration(
                    'calendar.default_token_expiry_seconds',
                    defaultValue: const Duration(minutes: 55),
                  );
                } catch (e) {
                  return const Duration(minutes: 55);
                }
              })(),
            );
      final userEmail = _extractGoogleIdentityEmail(user) ?? user?.email;
      return {'token': token, 'expiry': expiry, 'userEmail': userEmail};
    }

    _trace(
      '_googleProviderSessionPayload: providerToken is ${token == null ? 'NULL' : 'EMPTY'} - session user=${session?.user.id}',
    );

    if (user?.identities != null && user!.identities!.isNotEmpty) {
      for (final identity in user.identities!) {
        _trace(
          '_googleProviderSessionPayload: Checking identity provider=${identity.provider}',
        );
        if (identity.provider == 'google' && identity.identityData != null) {
          final data = identity.identityData as Map<String, dynamic>;
          final providerToken = (data['access_token'] as String?)?.trim();
          if (providerToken != null && providerToken.isNotEmpty) {
            _trace(
              '_googleProviderSessionPayload: FOUND token in identities.access_token',
            );
            final userEmail = (data['email'] as String?)?.trim() ?? user.email;
            return {
              'token': providerToken,
              'expiry': DateTime.now().add(
                await (() async {
                  try {
                    return await appConfigService.getDuration(
                      'calendar.default_token_expiry_seconds',
                      defaultValue: const Duration(minutes: 55),
                    );
                  } catch (e) {
                    return const Duration(minutes: 55);
                  }
                })(),
              ),
              'userEmail': userEmail,
            };
          }
        }
      }
    }

    return null;
  }

  Future<Map<String, dynamic>?> _googleProviderSessionPayload() async {
    final cachedPayload =
        await CalendarSyncService.getCachedGoogleImportPayload();
    if (cachedPayload != null) {
      _trace('_googleProviderSessionPayload: Using cached Google import token');
      return cachedPayload;
    }

    final sessionPayload = await _googlePayloadFromSession(
      Supabase.instance.client.auth.currentSession,
    );
    return sessionPayload;
  }

  Future<Map<String, dynamic>?> _azureProviderSessionPayload() async {
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
        : DateTime.now().add(
            await (() async {
              try {
                return await appConfigService.getDuration(
                  'calendar.default_token_expiry_seconds',
                  defaultValue: const Duration(minutes: 55),
                );
              } catch (e) {
                return const Duration(minutes: 55);
              }
            })(),
          );
    return {'token': token, 'expiry': expiry, 'userEmail': user?.email};
  }

  Future<Map<String, dynamic>?> _waitForGoogleSwitchCompletion({
    required String flowId,
    required Duration timeout,
    Future<void>? cancelSignal,
    bool Function()? shouldAbort,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (shouldAbort?.call() == true) {
        _trace('_waitForGoogleSwitchCompletion: Aborted while waiting');
        return null;
      }
      await _loadGoogleImportTokenFromCache();
      try {
        final prefs = await SharedPreferences.getInstance();
        final completedFlowId = prefs.getString(
          _googleSwitchCompletedFlowIdKey,
        );
        if (completedFlowId == flowId) {
          final payload =
              await CalendarSyncService.getCachedGoogleImportPayload();
          if (payload != null) {
            _trace(
              '_waitForGoogleSwitchCompletion: Flow completed with cached payload',
            );
            return payload;
          }
        }
      } catch (e) {
        _trace('_waitForGoogleSwitchCompletion: Poll error: $e');
      }
      if (cancelSignal != null) {
        final didCancel = await Future.any<bool>([
          cancelSignal.then((_) => true),
          Future<bool>.delayed(const Duration(milliseconds: 200), () => false),
        ]);
        if (didCancel) {
          _trace('_waitForGoogleSwitchCompletion: Cancelled by signal');
          return null;
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    await _loadGoogleImportTokenFromCache();
    final fallbackPayload =
        await CalendarSyncService.getCachedGoogleImportPayload();
    _trace(
      '_waitForGoogleSwitchCompletion: Timeout reached for flow=$flowId result=${fallbackPayload != null}',
    );
    return fallbackPayload;
  }

  Future<void> _startSupabaseOAuth({
    required OAuthProvider provider,
    required String scopes,
    Map<String, String>? queryParams,
  }) async {
    const mobileRedirectTo = 'com.example.matchme://login-callback';
    final redirectTo = kIsWeb
        ? '${Uri.base.origin}/auth/callback'
        : mobileRedirectTo;

    // CRITICAL: Save original session BEFORE OAuth to ensure the deep link handler
    // can restore it after the OAuth callback. BUT ONLY if:
    // 1. We're not already in an active account switch flow
    // 2. This prevents saving a previously-switched-to Google account as the "original"
    try {
      final originalUserId = Supabase.instance.client.auth.currentUser?.id;
      final originalSession = Supabase.instance.client.auth.currentSession;

      if (originalUserId != null && originalSession != null) {
        // CRITICAL: Don't save if we're already in a switch account flow
        // This prevents overwriting the real original session with a Google account
        // NOTE: temp session lives in SecureStorage now (was plaintext prefs).
        final existingSessionJson = await SensitiveSessionStore.instance
            .readOAuthSessionJson();
        final existingUserId = await SensitiveSessionStore.instance
            .readOAuthUserId();

        // Only save if not already saved (avoid overwriting during account switch flow)
        // If already saved, we're in an active switch and should not update
        if (existingSessionJson == null ||
            existingSessionJson.isEmpty ||
            existingUserId == null ||
            existingUserId.isEmpty) {
          final sessionJson = jsonEncode(originalSession.toJson());
          await SensitiveSessionStore.instance.writeOAuthSession(
            sessionJson: sessionJson,
            userId: originalUserId,
          );
          _trace(
            '_startSupabaseOAuth: Saved original session for ${provider.name} OAuth: $originalUserId',
          );
        } else {
          _trace(
            '_startSupabaseOAuth: Already in switch account flow, not overwriting saved session',
          );
        }
      }
    } catch (e) {
      _trace('_startSupabaseOAuth: Error saving session: $e');
    }

    // Start OAuth flow - note: this may temporarily change the session
    // to the provider's account (e.g., Google account), but the deep link handler
    // will detect the change and restore the original session.
    if (_useLoopbackGoogleOAuth || _useLoopbackOutlookOAuth) {
      await _runLoopbackSupabaseOAuth(
        provider: provider,
        scopes: scopes,
        queryParams: queryParams,
      );
      return;
    }

    await Supabase.instance.client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectTo,
      scopes: scopes,
      queryParams: queryParams,
      authScreenLaunchMode: _mobileOAuthLaunchMode,
    );
    _trace('_startSupabaseOAuth: OAuth launched for ${provider.name}');
  }

  /// Desktop OAuth: send the user to the system browser against a loopback
  /// redirect this app owns, then exchange the returned PKCE code ourselves.
  ///
  /// This is the same mechanism the login screen uses. It is required here
  /// because desktop cannot return from a `com.example.matchme://` redirect -
  /// see [_hasNoCustomSchemeCallback]. Supabase mediates the provider token
  /// exchange either way, so the resulting session (and the provider token the
  /// calendar code reads afterwards) is identical to the web flow's.
  Future<void> _runLoopbackSupabaseOAuth({
    required OAuthProvider provider,
    required String scopes,
    Map<String, String>? queryParams,
  }) async {
    final listener = OAuthLoopbackServer.instance;
    final cancellation = _CalendarOAuthCancellation();
    _calendarOAuthCancellation = cancellation;
    _calendarLifecycleListener?.dispose();
    // Opening the system browser is exactly what *backgrounds* the app, so
    // cancelling on `onHide` aborted every attempt that took longer than the
    // grace period - it looked like it worked only for accounts already signed
    // into the provider, which redirect back almost instantly.
    //
    // `onHide` therefore only records that we left; a subsequent `onResume`
    // (the user coming back without a callback) is the real cancel signal.
    // Requiring the app to have gone away first also filters out the brief
    // focus bounce Windows emits while handing off to the browser.
    var sawBackground = false;
    _calendarLifecycleListener = AppLifecycleListener(
      onHide: () => sawBackground = true,
      onPause: () => sawBackground = true,
      onDetach: () => cancellation.cancel(),
      onResume: () {
        if (sawBackground) {
          debugPrint(
            '[CalendarSync] app resumed while OAuth was pending — treating as '
            'a cancelled calendar sign-in',
          );
          cancellation.cancel();
        }
      },
    );

    try {
      final Uri redirectUri;
      try {
        redirectUri = await listener.listen();
      } on OAuthLoopbackException catch (e) {
        throw CalendarSyncException(
          'Local OAuth listener unavailable (${e.failure.name})',
          userMessage: provider == OAuthProvider.google
              ? 'calendarSyncGoogleAuthTimeout'
              : 'calendarSyncOutlookAuthTimeout',
          isNetworkError: true,
        );
      }

      // Generates and persists the PKCE verifier, then opens the browser.
      final launched = await Supabase.instance.client.auth.signInWithOAuth(
        provider,
        redirectTo: redirectUri.toString(),
        scopes: scopes,
        queryParams: queryParams,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw CalendarSyncException(
          'Could not open the browser for ${provider.name} sign-in',
          userMessage: provider == OAuthProvider.google
              ? 'calendarSyncGoogleAuthTimeout'
              : 'calendarSyncOutlookAuthTimeout',
        );
      }
      _trace(
        '_startSupabaseOAuth: loopback OAuth launched for ${provider.name}',
      );

      final OAuthLoopbackCallback callback;
      try {
        callback = await Future.any<OAuthLoopbackCallback>([
          listener.waitForCallback(_loopbackOAuthTimeout),
          _abandonCalendarOAuthAfterResume(cancellation),
        ]);
      } on _CalendarOAuthAbandoned {
        _trace('_startSupabaseOAuth: loopback OAuth abandoned by user');
        throw CalendarSyncException(
          'Sign-in was cancelled',
          userMessage: provider == OAuthProvider.google
              ? 'calendarSyncGoogleSignInCancelled'
              : 'calendarSyncOutlookNotConfigured',
        );
      }

      if (!callback.isSuccess) {
        _trace(
          '_startSupabaseOAuth: provider error ${callback.error}: ${callback.errorDescription}',
        );
        final denied = (callback.error ?? '').toLowerCase().contains('denied');
        throw CalendarSyncException(
          'Provider returned an error: ${callback.error}',
          userMessage: denied && provider == OAuthProvider.google
              ? 'calendarSyncGoogleSignInCancelled'
              : (provider == OAuthProvider.google
                    ? 'calendarSyncGoogleAuthTimeout'
                    : 'calendarSyncOutlookAuthTimeout'),
        );
      }

      // Signs the Supabase session in as the provider account. The caller
      // restores the original MatchMe session via _restoreSessionIfChanged.
      //
      // The guard stops the app's auth router from treating that transient
      // provider session as a real sign-in - without it the whole widget tree
      // is swapped to ProfileCheckScreen for the Google/Microsoft account and
      // the user is dumped on that account's home screen.
      final anchorUserId = Supabase.instance.client.auth.currentUser?.id;
      if (anchorUserId != null) {
        AuthTransitionGuard.begin(anchorUserId);
        _trace(
          'AuthTransitionGuard: BEGIN anchor=$anchorUserId '
          '(auth router will ignore the transient ${provider.name} session)',
        );
      } else {
        _trace(
          'AuthTransitionGuard: no current user, skipping guard for ${provider.name}',
        );
      }
      await Supabase.instance.client.auth.exchangeCodeForSession(
        callback.code!,
      );
      _trace(
        '_startSupabaseOAuth: loopback OAuth code exchanged for ${provider.name}',
      );
    } on CalendarSyncException {
      rethrow;
    } on AuthException catch (e) {
      throw CalendarSyncException(
        'OAuth code exchange failed: ${e.message}',
        userMessage: provider == OAuthProvider.google
            ? 'calendarSyncGoogleAuthTimeout'
            : 'calendarSyncOutlookAuthTimeout',
        isNetworkError: true,
      );
    } finally {
      _calendarOAuthCancellation = null;
      _calendarLifecycleListener?.dispose();
      _calendarLifecycleListener = null;
      await listener.close();
      // The browser is still in front of us; raise our own window back up.
      unawaited(focusAppWindow());
    }
  }

  /// Fails with [_CalendarOAuthAbandoned] once the user has been back in the app
  /// for the grace period without the browser delivering a code.
  static Future<OAuthLoopbackCallback> _abandonCalendarOAuthAfterResume(
    _CalendarOAuthCancellation? cancellation,
  ) async {
    if (cancellation == null) {
      return Completer<OAuthLoopbackCallback>().future;
    }
    await cancellation.future;
    await Future<void>.delayed(_loopbackOAuthResumeGrace);
    throw const _CalendarOAuthAbandoned();
  }

  /// Switch Google account for calendar import WITHOUT changing the main user session
  /// This allows users to select a different Google account for calendar sync
  /// while staying logged in to MatchMe as their original user
  Future<bool> switchGoogleAccount({
    Future<void>? cancelSignal,
    bool Function()? shouldAbort,
  }) async {
    // Native SDK path is Android/iOS/macOS only - see _useLoopbackGoogleOAuth.
    if (!kIsWeb && !_useLoopbackGoogleOAuth) {
      try {
        final payload = await _webService.authenticateGoogleCalendarAccess(
          forceAccountSelection: true,
        );
        if (payload == null) {
          return false;
        }
        await _cacheGoogleImportPayload(payload);
        return true;
      } catch (e) {
        if (_isGoogleSignInCancelled(e)) {
          return false;
        }
        throw _mapGoogleSignInFailure(e, duringSwitch: true);
      }
    }
    try {
      _trace('🔄 [Switch Account] Starting provider account switch...');

      // CRITICAL: Store the current MatchMe user - we want to keep them logged in
      final originalUserId = Supabase.instance.client.auth.currentUser?.id;
      final originalSession = Supabase.instance.client.auth.currentSession;

      if (originalUserId == null || originalSession == null) {
        throw Exception(
          'No active user session to switch calendar account for',
        );
      }

      _trace('🔐 [Switch Account] Current MatchMe user: $originalUserId');

      // CRITICAL: Check if we have a previously-saved original session different from current
      // This can happen when the deep link handler restored the session after a previous OAuth flow,
      // leaving a stale saved session. Clear it and proceed with the current valid session.
      final savedOriginalUserId = await SensitiveSessionStore.instance
          .readOAuthUserId();
      if (savedOriginalUserId != null &&
          savedOriginalUserId != originalUserId) {
        _trace(
          '⚠️ [Switch Account] Current user ($originalUserId) != saved original ($savedOriginalUserId)',
        );
        _trace(
          '⚠️ [Switch Account] Clearing stale saved session and proceeding with current user',
        );
        await SensitiveSessionStore.instance.clearOAuthSession();
      }

      _trace(
        '🔄 [Switch Account] Initiating OAuth to select different Google account...',
      );

      final flowId = 'google-switch-${DateTime.now().microsecondsSinceEpoch}';

      // CRITICAL: Save original session to secure storage BEFORE OAuth
      // The background service may clear credentials while OAuth is in progress.
      // Full session JSON (contains refresh token) must never sit in plaintext.
      final sessionJson = jsonEncode(originalSession.toJson());
      await SensitiveSessionStore.instance.writeOAuthSession(
        sessionJson: sessionJson,
        userId: originalUserId,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_googleSwitchFlowIdKey, flowId);
      await prefs.remove(_googleSwitchCompletedFlowIdKey);
      _trace(
        '💾 [Switch Account] Saved original session to secure storage: $originalUserId',
      );

      // Clear cached Google tokens for this account
      _googleImportAccessToken = null;
      _googleImportTokenExpiry = null;
      _googleImportUserEmail = null;
      _didLoadGoogleImportTokenCache = false;

      await CalendarSyncService.clearGoogleImportTokenCache();

      // Start OAuth with account selection prompt
      // DO NOT sign out - we're keeping the MatchMe session
      const googleCalendarScopes =
          'openid email profile '
          'https://www.googleapis.com/auth/calendar.readonly '
          'https://www.googleapis.com/auth/calendar.events.readonly';
      const selectAccountParams = {'prompt': 'select_account'};

      if (_useLoopbackGoogleOAuth) {
        // Desktop cannot return from a `com.example.matchme://` redirect - see
        // _hasNoCustomSchemeCallback. This call has its own inline OAuth (it
        // deliberately skips _startSupabaseOAuth to control the account
        // chooser), so it needs the loopback redirect explicitly.
        await _runLoopbackSupabaseOAuth(
          provider: OAuthProvider.google,
          scopes: googleCalendarScopes,
          queryParams: selectAccountParams,
        );
        _trace('🔄 [Switch Account] Loopback OAuth code exchanged');

        // On mobile the deep-link handler in main.dart finishes this flow: it
        // caches the provider payload, publishes _googleSwitchCompletedFlowIdKey
        // and restores the MatchMe session. No deep link fires here, so this
        // method has to do all three itself - otherwise the app stays signed in
        // as the Google account and the wait below can never find a payload.
        final payload = await _googleProviderSessionPayload();
        if (payload == null) {
          _trace(
            '❌ [Switch Account] Loopback exchange produced no provider token',
          );
          await _restoreSessionIfChanged(
            originalSession: originalSession,
            originalUserId: originalUserId,
          );
          return false;
        }
        await _cacheGoogleImportPayload(payload);
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_googleSwitchCompletedFlowIdKey, flowId);
        } catch (_) {}
        await _restoreSessionIfChanged(
          originalSession: originalSession,
          originalUserId: originalUserId,
        );
        // The MatchMe session is back in place; the saved OAuth session is stale.
        try {
          await SensitiveSessionStore.instance.clearOAuthSession();
        } catch (_) {}
        _trace('✅ [Switch Account] New Google token obtained (loopback)');
        return true;
      }

      // Mobile and web: the deep-link handler in main.dart completes this flow.
      const mobileRedirectTo = 'com.example.matchme://login-callback';
      final redirectTo = kIsWeb
          ? '${Uri.base.origin}/auth/callback'
          : mobileRedirectTo;

      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectTo,
        scopes: googleCalendarScopes,
        queryParams: selectAccountParams,
        authScreenLaunchMode: _mobileOAuthLaunchMode,
      );

      _trace('⏳ [Switch Account] Waiting for new Google token...');
      final oauthTimeout = kIsWeb
          ? const Duration(seconds: 75)
          : const Duration(seconds: 45);
      final payload = await _waitForGoogleSwitchCompletion(
        flowId: flowId,
        timeout: oauthTimeout,
        cancelSignal: cancelSignal,
        shouldAbort: shouldAbort,
      );

      if (payload != null) {
        await _cacheGoogleImportPayload(payload);
        _trace('✅ [Switch Account] New Google token obtained!');
        return true;
      }
      if (shouldAbort?.call() == true) {
        _trace('ℹ️ [Switch Account] Account chooser dismissed by user');
        return false;
      }
      _trace(
        '⚠️ [Switch Account] Could not retrieve new token, but continuing...',
      );
      return false;
    } catch (e) {
      _trace('❌ [Switch Account] Error: $e');
      rethrow;
    } finally {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_googleSwitchFlowIdKey);
        await prefs.remove(_googleSwitchCompletedFlowIdKey);
      } catch (_) {}
    }
  }

  Future<void> _restoreSessionIfChanged({
    required Session? originalSession,
    required String? originalUserId,
  }) async {
    if (originalSession == null || originalUserId == null) {
      AuthTransitionGuard.end();
      return;
    }
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == originalUserId) {
      _trace(
        '_restoreSessionIfChanged: User ID unchanged, no restoration needed',
      );
      AuthTransitionGuard.end();
      return;
    }

    _trace(
      '_restoreSessionIfChanged: User changed from $currentUserId to $originalUserId, restoring original session',
    );
    try {
      // Restore the original session from its serialized payload.
      final sessionJson = jsonEncode(originalSession.toJson());
      await Supabase.instance.client.auth.recoverSession(sessionJson);
      _trace('✅ _restoreSessionIfChanged: Original user session restored');
    } catch (e) {
      _trace('⚠️ _restoreSessionIfChanged: Failed to restore: $e');
      // Try refresh as fallback
      try {
        await Supabase.instance.client.auth.refreshSession();
        _trace('✅ _restoreSessionIfChanged: Session refreshed via fallback');
        return;
      } catch (e2) {
        _trace('❌ _restoreSessionIfChanged: Failed to restore session: $e2');
        return;
      }
    }

    // `recoverSession` only assigns `_currentSession` in memory - gotrue's
    // `_saveSession` never touches the storage backend. Without the refresh
    // below, the provider account that the OAuth flow just signed in as stays
    // on disk, and the next cold start comes up as the Google/Microsoft account
    // instead of the MatchMe user. `refreshSession` validates and persists.
    // Best effort: we must never trade a working in-memory session for this.
    try {
      await Supabase.instance.client.auth.refreshSession();
      _trace('💾 _restoreSessionIfChanged: Restored session persisted');
    } catch (e) {
      _trace(
        '⚠️ _restoreSessionIfChanged: could not persist restored session: $e',
      );
    }

    // The secure store is the source of truth the native background service
    // reads, so mirror the restored tokens into it.
    try {
      final user = Supabase.instance.client.auth.currentUser;
      final session = Supabase.instance.client.auth.currentSession;
      if (user != null && session != null) {
        await SensitiveSessionStore.instance.writeAuthTokens(
          userId: user.id,
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
        );
        _trace(
          '💾 _restoreSessionIfChanged: secure store updated for ${user.id}',
        );
      }
    } catch (e) {
      _trace('⚠️ _restoreSessionIfChanged: secure store update failed: $e');
    }

    // The original MatchMe account is back in place, so the auth router may
    // honour sign-in events again.
    AuthTransitionGuard.end();
    _trace('AuthTransitionGuard: END (original session restored)');
  }

  Future<Map<String, dynamic>?> _waitForProviderPayload({
    required Future<Map<String, dynamic>?> Function() readPayload,
    Future<Map<String, dynamic>?> Function(AuthState authState)?
    readPayloadFromAuthState,
    bool Function(Map<String, dynamic> payload)? acceptPayload,
    bool Function()? shouldAbort,
    Duration timeout = const Duration(minutes: 2),
    Future<void>? cancelSignal,
  }) async {
    if (shouldAbort?.call() == true) {
      _trace('_waitForProviderPayload: Aborted before wait started');
      return null;
    }
    final immediatePayload = await readPayload();
    if (immediatePayload != null &&
        (acceptPayload == null || acceptPayload(immediatePayload))) {
      _trace('_waitForProviderPayload: Immediate payload found');
      return immediatePayload;
    }

    _trace(
      '_waitForProviderPayload: Starting wait for payload (timeout=${timeout.inSeconds}s)...',
    );
    final completer = Completer<Map<String, dynamic>?>();
    final startTime = DateTime.now();

    Future<void> resolveIfAvailable() async {
      if (completer.isCompleted) return;
      if (shouldAbort?.call() == true) {
        _trace('_waitForProviderPayload: Aborted while waiting');
        completer.complete(null);
        return;
      }
      final payload = await readPayload();
      if (payload != null &&
          (acceptPayload == null || acceptPayload(payload))) {
        _trace('_waitForProviderPayload: Payload became available!');
        completer.complete(payload);
      }
    }

    final authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
      (authState) async {
        _trace(
          '_waitForProviderPayload: Auth state change: ${authState.event}',
        );
        final eventPayload = await readPayloadFromAuthState?.call(authState);
        if (eventPayload != null &&
            !completer.isCompleted &&
            (acceptPayload == null || acceptPayload(eventPayload))) {
          _trace(
            '_waitForProviderPayload: Payload found directly from auth event',
          );
          completer.complete(eventPayload);
          return;
        }
        if (authState.event == AuthChangeEvent.initialSession ||
            authState.event == AuthChangeEvent.signedIn ||
            authState.event == AuthChangeEvent.tokenRefreshed) {
          _trace(
            '_waitForProviderPayload: Trigger check on auth state: ${authState.event}',
          );
          resolveIfAvailable();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _trace('_waitForProviderPayload: Auth error: $error');
      },
    );

    // Fast polling for first 5 seconds, then slower polling
    final fastPollTimer = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) {
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      if (elapsed < 5 && !completer.isCompleted) {
        resolveIfAvailable();
      }
    });

    // Slower polling after 5 seconds
    final slowPollTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      if (elapsed >= 5 && !completer.isCompleted) {
        resolveIfAvailable();
      }
    });

    Timer? cancelTimer;
    if (cancelSignal != null) {
      cancelTimer = Timer(Duration.zero, () async {
        try {
          await cancelSignal;
          if (!completer.isCompleted) {
            _trace('_waitForProviderPayload: Cancelled by signal');
            completer.complete(null);
          }
        } catch (e) {
          // Ignore errors from cancel signal
        }
      });
    }

    final timeoutTimer = Timer(timeout, () async {
      if (!completer.isCompleted) {
        _trace(
          '_waitForProviderPayload: Timeout reached (${timeout.inSeconds}s)',
        );
        final payload = await readPayload();
        if (payload != null &&
            (acceptPayload == null || acceptPayload(payload))) {
          completer.complete(payload);
        } else {
          completer.complete(null);
        }
      }
    });

    try {
      final result = await completer.future;
      _trace(
        '_waitForProviderPayload: Completed with result: ${result != null}',
      );
      return result;
    } finally {
      await authSub.cancel();
      fastPollTimer.cancel();
      slowPollTimer.cancel();
      timeoutTimer.cancel();
      cancelTimer?.cancel();
    }
  }

  Future<Map<String, dynamic>?> _ensureGoogleProviderSessionPayload({
    Future<void>? cancelSignal,
  }) async {
    final existing = await _googleProviderSessionPayload();
    if (existing != null) return existing;
    // The native Google SDK only exists on Android/iOS/macOS. Everywhere else
    // fall through to the Supabase + loopback flow below.
    if (!kIsWeb && !_useLoopbackGoogleOAuth) {
      try {
        final payload = await _webService.authenticateGoogleCalendarAccess();
        if (payload == null) {
          throw CalendarSyncException(
            'Google sign-in was cancelled',
            userMessage: 'calendarSyncGoogleSignInCancelled',
          );
        }
        await _cacheGoogleImportPayload(payload);
        return payload;
      } catch (e) {
        if (e is CalendarSyncException) {
          rethrow;
        }
        if (_isGoogleSignInCancelled(e)) {
          throw CalendarSyncException(
            'Google sign-in was cancelled',
            userMessage: 'calendarSyncGoogleSignInCancelled',
          );
        }
        throw _mapGoogleSignInFailure(e, duringSwitch: false);
      }
    }
    final originalSession = Supabase.instance.client.auth.currentSession;
    final originalUserId = Supabase.instance.client.auth.currentUser?.id;
    await CalendarSyncService.beginGoogleImportOAuthFlow();
    try {
      try {
        await _startSupabaseOAuth(
          provider: OAuthProvider.google,
          scopes:
              'openid email profile https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events.readonly',
          queryParams: {'prompt': 'select_account'},
        );
      } catch (e) {
        _trace('CalendarSyncService OAuth start error: $e');
      }
      final oauthTimeout = kIsWeb
          ? const Duration(seconds: 75)
          : const Duration(seconds: 45);
      _trace(
        'CalendarSyncService waiting for Google OAuth with timeout=${oauthTimeout.inSeconds}s',
      );

      final payload = await _waitForProviderPayload(
        readPayload: _googleProviderSessionPayload,
        readPayloadFromAuthState: (authState) =>
            _googlePayloadFromSession(authState.session),
        shouldAbort: CalendarSyncService.shouldAbortGoogleImportOAuthWait,
        timeout: oauthTimeout,
        cancelSignal: cancelSignal,
      );

      if (payload == null) {
        _trace('CalendarSyncService Google OAuth timeout or failed');
        throw CalendarSyncException(
          'Google authentication timed out. Please check your internet connection and try again.',
          userMessage: 'calendarSyncGoogleAuthTimeout',
          isNetworkError: true,
        );
      }

      await _cacheGoogleImportPayload(payload);
      await _restoreSessionIfChanged(
        originalSession: originalSession,
        originalUserId: originalUserId,
      );
      return payload;
    } finally {
      await CalendarSyncService.endGoogleImportOAuthFlow();
    }
  }

  Future<Map<String, dynamic>?> authenticateGoogleImportAccount({
    bool forceAccountSelection = false,
    Future<void>? cancelSignal,
  }) async {
    if (forceAccountSelection) {
      final switched = await switchGoogleAccount(cancelSignal: cancelSignal);
      _trace(
        'authenticateGoogleImportAccount: switchGoogleAccount returned $switched',
      );
      if (!switched) return null;
      await _loadGoogleImportTokenFromCache();
      final cached = await CalendarSyncService.getCachedGoogleImportPayload();
      _trace(
        'authenticateGoogleImportAccount: cached payload '
        '${cached == null ? 'NULL' : 'token len ${(cached['token'] as String).length}, expiry ${cached['expiry']}, email ${cached['userEmail']}'}',
      );
      return cached;
    }
    return _getGoogleImportSessionPayload(
      allowInteractive: true,
      cancelSignal: cancelSignal,
    );
  }

  Future<Map<String, dynamic>?> _ensureAzureProviderSessionPayload({
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
    // Android only: the MSAL path below is built from AndroidConfig. Desktop
    // uses the Supabase + loopback flow, which works on every platform.
    if (!kIsWeb && !_useLoopbackOutlookOAuth) {
      return await _ensureOutlookNativeSessionPayload();
    }
    final existing = await _azureProviderSessionPayload();
    if (existing != null) return existing;
    final originalSession = Supabase.instance.client.auth.currentSession;
    final originalUserId = Supabase.instance.client.auth.currentUser?.id;
    try {
      await _startSupabaseOAuth(
        provider: OAuthProvider.azure,
        scopes: 'openid email profile offline_access User.Read Calendars.Read',
        // Without the prompt, Microsoft signs the user straight back in with
        // the account that is already signed into the browser, and there is
        // no way to pick a different one. The hint keeps a refresh tied to
        // the account the calendar was connected with, instead of the account
        // the browser happens to have signed in.
        queryParams: {
          if (forceAccountSelection) 'prompt': 'select_account',
          if (loginHint != null && loginHint.trim().isNotEmpty)
            'login_hint': loginHint.trim(),
        },
      );
    } catch (e) {
      _trace('CalendarSyncService OAuth start error: $e');
    }
    final oauthTimeout = kIsWeb
        ? const Duration(seconds: 75)
        : const Duration(seconds: 45);
    _trace(
      'CalendarSyncService waiting for Outlook OAuth with timeout=${oauthTimeout.inSeconds}s',
    );

    final payload = await _waitForProviderPayload(
      readPayload: _azureProviderSessionPayload,
      timeout: oauthTimeout,
    );

    if (payload == null) {
      _trace('CalendarSyncService Outlook OAuth timeout or failed');
      throw CalendarSyncException(
        'Outlook authentication timed out. Please check your internet connection and try again.',
        userMessage: 'calendarSyncOutlookAuthTimeout',
        isNetworkError: true,
      );
    }

    await _restoreSessionIfChanged(
      originalSession: originalSession,
      originalUserId: originalUserId,
    );
    return payload;
  }

  Future<Map<String, dynamic>?> authenticateOutlookImportAccount({
    bool allowNonWeb = false,
    bool forceAccountSelection = false,
    String? preferredUserEmail,
  }) async {
    final preferredEmail = preferredUserEmail?.trim();
    final cachedPayload = await _getCachedOutlookImportPayload();
    final cachedEmail = (cachedPayload?['userEmail'] as String?)?.trim();
    if (!forceAccountSelection &&
        cachedPayload != null &&
        (preferredEmail == null ||
            preferredEmail.isEmpty ||
            cachedEmail?.toLowerCase() == preferredEmail.toLowerCase())) {
      return cachedPayload;
    }

    if (!kIsWeb && allowNonWeb) {
      if (_canUseOutlookNativeAuth()) {
        if (forceAccountSelection) {
          await CalendarSyncService.clearOutlookImportTokenCache();
          _outlookAccessToken = null;
          _outlookTokenExpiry = null;
          _outlookImportAccessToken = null;
          _outlookImportTokenExpiry = null;
          _outlookImportUserEmail = null;
          try {
            final nativePayload = await _ensureOutlookNativeSessionPayload(
              forceInteractive: true,
              forceAccountSelection: true,
            );
            if (nativePayload != null) {
              await CalendarSyncService.cacheOutlookImportToken(
                token: nativePayload['token'] as String,
                expiry: nativePayload['expiry'] as DateTime,
                userEmail: nativePayload['userEmail'] as String?,
              );
              return nativePayload;
            }
          } catch (e) {
            _trace(
              'authenticateOutlookImportAccount native interactive failed, falling back: $e',
            );
          }
        } else {
          if (preferredEmail != null && preferredEmail.isNotEmpty) {
            try {
              final targetedPayload =
                  await _tryAuthenticateOutlookPreferredAccount(
                    preferredEmail,
                    allowNonWeb: allowNonWeb,
                  );
              if (targetedPayload != null) {
                await CalendarSyncService.cacheOutlookImportToken(
                  token: targetedPayload['token'] as String,
                  expiry: targetedPayload['expiry'] as DateTime,
                  userEmail: targetedPayload['userEmail'] as String?,
                );
                return targetedPayload;
              }
            } catch (e) {
              _trace(
                'authenticateOutlookImportAccount targeted native auth failed, falling back: $e',
              );
            }
          }
          try {
            final nativePayload = await _ensureOutlookNativeSessionPayload();
            if (nativePayload != null) {
              await CalendarSyncService.cacheOutlookImportToken(
                token: nativePayload['token'] as String,
                expiry: nativePayload['expiry'] as DateTime,
                userEmail: nativePayload['userEmail'] as String?,
              );
              return nativePayload;
            }
          } catch (e) {
            _trace(
              'authenticateOutlookImportAccount native session failed, falling back: $e',
            );
          }
        }
      }
      await signInOutlook(
        allowNonWeb: true,
        forceAccountSelection: forceAccountSelection,
        loginHint: preferredEmail,
      );
      final fallbackPayload = await _getCachedOutlookImportPayload();
      if (fallbackPayload != null) {
        return fallbackPayload;
      }
      final token =
          _outlookImportAccessToken?.trim() ?? _outlookAccessToken?.trim();
      final expiry = _outlookImportTokenExpiry ?? _outlookTokenExpiry;
      final userEmail = (_outlookImportUserEmail?.trim().isNotEmpty == true
          ? _outlookImportUserEmail!.trim()
          : preferredEmail);
      if (token != null && token.isNotEmpty && expiry != null) {
        await CalendarSyncService.cacheOutlookImportToken(
          token: token,
          expiry: expiry,
          userEmail: userEmail,
        );
        return {'token': token, 'expiry': expiry, 'userEmail': userEmail};
      }
      throw CalendarSyncException(
        'Outlook sign-in failed to return an authenticated account',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    if (forceAccountSelection) {
      await CalendarSyncService.clearOutlookImportTokenCache();
      _outlookAccessToken = null;
      _outlookTokenExpiry = null;
      _outlookImportAccessToken = null;
      _outlookImportTokenExpiry = null;
      _outlookImportUserEmail = null;
      await signInOutlook(
        allowNonWeb: allowNonWeb,
        forceAccountSelection: true,
        loginHint: preferredEmail,
      );
      // The sign-in above already produced a token for the account the user
      // picked. Return it instead of falling through to the provider-token
      // lookup below, which belongs to the account the user signed in to
      // MatchMe with - and would ask Microsoft to sign in a second time.
      final selectedPayload = await _getCachedOutlookImportPayload();
      if (selectedPayload != null) {
        return selectedPayload;
      }
    } else if (preferredEmail != null && preferredEmail.isNotEmpty) {
      final targetedPayload = await _tryAuthenticateOutlookPreferredAccount(
        preferredEmail,
        allowNonWeb: allowNonWeb,
      );
      if (targetedPayload != null) {
        await CalendarSyncService.cacheOutlookImportToken(
          token: targetedPayload['token'] as String,
          expiry: targetedPayload['expiry'] as DateTime,
          userEmail: targetedPayload['userEmail'] as String?,
        );
        return targetedPayload;
      }
    }

    final payload = await _ensureAzureProviderSessionPayload(
      forceAccountSelection: forceAccountSelection,
      loginHint: preferredEmail,
    );
    if (payload == null) {
      return null;
    }

    final token = payload['token'] as String?;
    final expiry = payload['expiry'] as DateTime?;
    final userEmail = payload['userEmail'] as String?;
    if (token == null || expiry == null) {
      return null;
    }
    await CalendarSyncService.cacheOutlookImportToken(
      token: token,
      expiry: expiry,
      userEmail: userEmail,
    );
    return {'token': token, 'expiry': expiry, 'userEmail': userEmail};
  }

  Future<Map<String, dynamic>?> _ensureOutlookNativeSessionPayload({
    bool forceInteractive = false,
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
    await _loadOutlookImportTokenFromCache();
    final cachedPayload = forceInteractive
        ? null
        : await _getCachedOutlookImportPayload();
    if (cachedPayload != null) {
      _outlookAccessToken = cachedPayload['token'] as String;
      _outlookTokenExpiry = cachedPayload['expiry'] as DateTime;
      return cachedPayload;
    }
    final token = await _getOutlookNativeToken(
      forceInteractive: forceInteractive,
      forceAccountSelection: forceAccountSelection,
      loginHint: loginHint,
    );
    if (token != null) {
      final expiry =
          _outlookNativeTokenExpiry ??
          DateTime.now().add(const Duration(hours: 1));
      final userEmail = _outlookNativeUserEmail;
      _outlookAccessToken = token;
      _outlookTokenExpiry = expiry;
      return {'token': token, 'expiry': expiry, 'userEmail': userEmail};
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getCachedOutlookImportPayload() async {
    final token = _outlookImportAccessToken?.trim();
    final expiry = _outlookImportTokenExpiry;
    if (token == null || token.isEmpty || expiry == null) {
      return null;
    }
    if (DateTime.now().isAfter(
      expiry.subtract(
        await (() async {
          try {
            return await appConfigService.getDuration(
              'calendar.token_refresh_buffer_seconds',
              defaultValue: const Duration(minutes: 5),
            );
          } catch (e) {
            return const Duration(minutes: 5);
          }
        })(),
      ),
    )) {
      return null;
    }
    return {
      'token': token,
      'expiry': expiry,
      'userEmail': _outlookImportUserEmail,
    };
  }

  Future<Map<String, dynamic>?> getCachedOutlookImportPayload() async {
    return await _getCachedOutlookImportPayload();
  }

  Future<Map<String, dynamic>?> _tryAuthenticateOutlookPreferredAccount(
    String preferredUserEmail, {
    required bool allowNonWeb,
  }) async {
    final normalizedEmail = preferredUserEmail.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return null;
    }

    if (kIsWeb) {
      await _ensureOutlookOAuth();
      final token = await OutlookWebAuth.instance.getAccessTokenForUsername(
        username: preferredUserEmail,
        scopes: _outlookMsalScopes,
        forceRefresh: false,
      );
      if (token == null || token.trim().isEmpty) {
        return null;
      }
      final expiry = await _resolveOutlookTokenExpiry(token);
      _outlookAccessToken = token;
      _outlookTokenExpiry = expiry;
      _outlookImportAccessToken = token;
      _outlookImportTokenExpiry = expiry;
      _outlookImportUserEmail = preferredUserEmail.trim();
      await _saveOutlookTokenToCache(token, expiry);
      return {
        'token': token,
        'expiry': expiry,
        'userEmail': preferredUserEmail.trim(),
      };
    }

    if (!allowNonWeb) {
      return null;
    }

    final currentEmail = await _getOutlookNativeCurrentAccountEmail();
    if (currentEmail != null &&
        currentEmail.trim().toLowerCase() == normalizedEmail) {
      final token = await _getOutlookNativeToken();
      if (token == null || token.trim().isEmpty) {
        return null;
      }
      final expiry =
          _outlookNativeTokenExpiry ??
          DateTime.now().add(const Duration(hours: 1));
      return {
        'token': token,
        'expiry': expiry,
        'userEmail': currentEmail.trim(),
      };
    }

    return null;
  }

  Future<void> _loadOutlookImportTokenFromCache() async {
    if (_didLoadOutlookImportTokenCache) return;
    _didLoadOutlookImportTokenCache = true;
    try {
      final token = await _secureRead(_outlookImportTokenKey);
      final expiryRaw = await _secureRead(_outlookImportTokenExpiryKey);
      final email = await _secureRead(_outlookImportUserEmailKey);
      final expiry = expiryRaw != null ? DateTime.tryParse(expiryRaw) : null;
      if (token == null || token.trim().isEmpty || expiry == null) return;
      _outlookImportAccessToken = token;
      _outlookImportTokenExpiry = expiry;
      _outlookImportUserEmail = email;
    } catch (_) {}
  }

  Future<bool> _isOutlookImportTokenExpired() async {
    if (_outlookNativeAccessToken == null ||
        _outlookNativeAccessToken!.trim().isEmpty) {
      return true;
    }
    final expiry = _outlookNativeTokenExpiry;
    if (expiry == null) return true;
    return DateTime.now().isAfter(
      expiry.subtract(
        await (() async {
          try {
            return await appConfigService.getDuration(
              'calendar.token_refresh_buffer_seconds',
              defaultValue: const Duration(minutes: 5),
            );
          } catch (e) {
            return const Duration(minutes: 5);
          }
        })(),
      ),
    );
  }

  Future<String?> _getOutlookNativeCurrentAccountEmail() async {
    if (_outlookNativeUserEmail != null &&
        _outlookNativeUserEmail!.trim().isNotEmpty) {
      return _outlookNativeUserEmail!.trim();
    }

    try {
      final client = await _getOutlookNativeClient();
      final account = await client.currentAccount;
      final username = account.username?.trim();
      if (username != null && username.isNotEmpty) {
        _outlookNativeUserEmail = username;
        return username;
      }
    } catch (e) {
      _trace('_getOutlookNativeCurrentAccountEmail failed: $e');
    }
    return null;
  }

  Future<String?> _getOutlookNativeToken({
    bool forceInteractive = false,
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
    if (!forceInteractive &&
        _outlookNativeAccessToken != null &&
        !await _isOutlookImportTokenExpired()) {
      return _outlookNativeAccessToken;
    }
    if (!forceInteractive) {
      try {
        final client = await _getOutlookNativeClient();
        final result = await client.acquireTokenSilent(
          scopes: _outlookNativeMsalScopes,
        );
        final accessToken = result.accessToken;
        final expiresOn = result.expiresOn;
        if (accessToken.isNotEmpty) {
          _outlookNativeAccessToken = accessToken;
          _outlookNativeTokenExpiry = expiresOn;
          _outlookNativeUserEmail = result.account.username;
          await _cacheOutlookNativeToken(
            accessToken,
            expiresOn,
            result.account.username,
          );
          return accessToken;
        }
      } catch (e) {
        if (e is CalendarSyncException && !_isOutlookNotConfiguredError(e)) {
          rethrow;
        }
        _trace('_getOutlookNativeToken silent failed: $e');
      }
    }

    try {
      final client = await _getOutlookNativeClient();
      if (forceAccountSelection) {
        // MSAL's single-account mode only accepts an interactive sign-in for
        // the account it already has: picking a different one in the chooser
        // fails with "current_account_mismatch". Dropping the current account
        // first is MSAL's own way to switch accounts - the account the user
        // picks then becomes the current one.
        try {
          await client.signOut();
          _trace('_getOutlookNativeToken signed out before account selection');
        } catch (e) {
          _trace('_getOutlookNativeToken sign-out before account selection failed: $e');
        }
      }
      final result = await client.acquireToken(
        scopes: _outlookNativeMsalScopes,
        // SELECT_ACCOUNT makes Microsoft show its account picker instead of
        // reusing the account that is already signed in on the device.
        prompt: forceAccountSelection
            ? Prompt.selectAccount
            : Prompt.whenRequired,
        // Keeps a refresh tied to the account the calendar was connected
        // with, instead of the device's default Microsoft account.
        loginHint: loginHint,
      );
      final accessToken = result.accessToken;
      final expiresOn = result.expiresOn;
      if (accessToken.isNotEmpty) {
        _outlookNativeAccessToken = accessToken;
        _outlookNativeTokenExpiry = expiresOn;
        _outlookNativeUserEmail = result.account.username;
        await _cacheOutlookNativeToken(
          accessToken,
          expiresOn,
          result.account.username,
        );
        return accessToken;
      }
    } catch (e) {
      if (e is CalendarSyncException && _isOutlookNotConfiguredError(e)) {
        _trace('_getOutlookNativeToken native client unavailable: $e');
        return null;
      }
      if (e is CalendarSyncException) {
        rethrow;
      }
      if (_looksLikeOutlookSignInCancelled(e)) {
        _trace('_getOutlookNativeToken interactive cancelled: $e');
        return null;
      }
      _trace('_getOutlookNativeToken interactive failed: $e');
      throw CalendarSyncException(
        'Outlook native sign-in failed: $e',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }
    return null;
  }

  Future<SingleAccountPca> _getOutlookNativeClient() async {
    try {
      final clientId = _resolveOutlookClientId();
      final androidRedirectUri = _resolveOutlookAndroidRedirectUri();
      if (clientId.isEmpty || androidRedirectUri.isEmpty) {
        throw CalendarSyncException(
          'Outlook native Android configuration is missing',
          userMessage: 'calendarSyncOutlookNotConfigured',
        );
      }

      if (_outlookNativeClient != null &&
          _outlookNativeClientId == clientId &&
          _outlookNativeClientRedirectUri == androidRedirectUri) {
        return _outlookNativeClient!;
      }

      final androidConfig = AndroidConfig(
        configFilePath: 'assets/msal_config.json',
        redirectUri: androidRedirectUri,
      );

      _outlookNativeClient = await SingleAccountPca.create(
        clientId: clientId,
        androidConfig: androidConfig,
      );
      _outlookNativeClientId = clientId;
      _outlookNativeClientRedirectUri = androidRedirectUri;
      return _outlookNativeClient!;
    } catch (e) {
      if (e is CalendarSyncException) {
        rethrow;
      }
      _outlookNativeClient = null;
      _outlookNativeClientId = null;
      _outlookNativeClientRedirectUri = null;
      _trace('_getOutlookNativeClient creation failed: $e');
      throw CalendarSyncException(
        'Outlook native client creation failed: $e',
        userMessage: 'calendarSyncOutlookNotConfigured',
      );
    }
  }

  Future<void> _cacheOutlookNativeToken(
    String token,
    DateTime expiry,
    String? userEmail,
  ) async {
    _outlookImportAccessToken = token;
    _outlookImportTokenExpiry = expiry;
    _outlookImportUserEmail = userEmail;
    _outlookAccessToken = token;
    _outlookTokenExpiry = expiry;
    try {
      await _secureWrite(_outlookImportTokenKey, token);
      await _secureWrite(
        _outlookImportTokenExpiryKey,
        expiry.toIso8601String(),
      );
      if (userEmail != null) {
        await _secureWrite(_outlookImportUserEmailKey, userEmail);
      } else {
        await _secureDelete(_outlookImportUserEmailKey);
      }
    } catch (_) {}
  }

  Future<void> _loadGoogleImportTokenFromCache() async {
    if (_didLoadGoogleImportTokenCache) return;
    _didLoadGoogleImportTokenCache = true;
    try {
      final token = await _secureRead(_googleImportTokenKey);
      final expiryRaw = await _secureRead(_googleImportTokenExpiryKey);
      final email = await _secureRead(_googleImportUserEmailKey);
      final expiry = expiryRaw != null ? DateTime.tryParse(expiryRaw) : null;
      if (token == null || token.trim().isEmpty || expiry == null) return;
      _googleImportAccessToken = token;
      _googleImportTokenExpiry = expiry;
      _googleImportUserEmail = email;
    } catch (_) {}
  }

  Future<void> _cacheGoogleImportPayload(Map<String, dynamic> payload) async {
    await CalendarSyncService.cacheGoogleImportToken(
      token: payload['token'] as String,
      expiry: payload['expiry'] as DateTime,
      userEmail: payload['userEmail'] as String?,
    );
  }

  Future<Map<String, dynamic>?> _getGoogleImportSessionPayload({
    bool allowInteractive = false,
    Future<void>? cancelSignal,
  }) async {
    await _loadGoogleImportTokenFromCache();
    final cachedPayload =
        await CalendarSyncService.getCachedGoogleImportPayload();
    if (cachedPayload != null) {
      return cachedPayload;
    }
    final currentPayload = await _googleProviderSessionPayload();
    if (currentPayload != null) {
      await _cacheGoogleImportPayload(currentPayload);
      return currentPayload;
    }
    if (!allowInteractive) {
      return null;
    }
    final oauthPayload = await _ensureGoogleProviderSessionPayload(
      cancelSignal: cancelSignal,
    );
    if (oauthPayload == null) return null;
    await _cacheGoogleImportPayload(oauthPayload);
    return oauthPayload;
  }

  void dispose() {
    _calendarLifecycleListener?.dispose();
    _calendarLifecycleListener = null;
    _calendarOAuthCancellation?.cancel();
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
    String? prompt,
    String? loginHint,
  }) {
    return Config(
      tenant: tenant,
      clientId: clientId,
      scope: 'User.Read Calendars.Read offline_access',
      redirectUri: redirectUri,
      navigatorKey: navigatorKey,
      webUseRedirect: false,
      // `select_account` makes Microsoft show its account picker, so the user
      // can pick an account other than the one already signed in.
      prompt: prompt,
      // Keeps a refresh tied to the account the calendar was connected with,
      // instead of the device's default Microsoft account.
      loginHint: loginHint,
    );
  }

  String _readOutlookConfigValue(String key) {
    final compileTimeValue = switch (key) {
      'OUTLOOK_TENANT_ID' => const String.fromEnvironment(
        'OUTLOOK_TENANT_ID',
        defaultValue: '',
      ),
      'OUTLOOK_CLIENT_ID' => const String.fromEnvironment(
        'OUTLOOK_CLIENT_ID',
        defaultValue: '',
      ),
      'OUTLOOK_REDIRECT_URI' => const String.fromEnvironment(
        'OUTLOOK_REDIRECT_URI',
        defaultValue: '',
      ),
      'OUTLOOK_ANDROID_REDIRECT_URI' => const String.fromEnvironment(
        'OUTLOOK_ANDROID_REDIRECT_URI',
        defaultValue: '',
      ),
      _ => '',
    }.trim();
    if (compileTimeValue.isNotEmpty) {
      return compileTimeValue;
    }
    return (dotenv.env[key] ?? '').trim();
  }

  String _resolveOutlookTenantId() =>
      _readOutlookConfigValue('OUTLOOK_TENANT_ID');

  String _resolveOutlookClientId() =>
      _readOutlookConfigValue('OUTLOOK_CLIENT_ID');

  String _resolveOutlookWebRedirectUri() =>
      _readOutlookConfigValue('OUTLOOK_REDIRECT_URI');

  String _normalizeOutlookAndroidRedirectUri(String value) {
    final trimmed = value.trim();
    if (!trimmed.toLowerCase().startsWith('msauth://')) {
      return trimmed;
    }
    final hostSeparator = trimmed.indexOf('://');
    final signatureSeparator = trimmed.indexOf('/', hostSeparator + 3);
    if (signatureSeparator == -1 || signatureSeparator >= trimmed.length - 1) {
      return trimmed;
    }
    final prefix = trimmed.substring(0, signatureSeparator + 1);
    final signature = trimmed.substring(signatureSeparator + 1);
    if (signature.contains('%')) {
      return trimmed;
    }
    return '$prefix${Uri.encodeComponent(signature)}';
  }

  String _resolveOutlookAndroidRedirectUri() {
    final androidRedirectUri = _normalizeOutlookAndroidRedirectUri(
      _readOutlookConfigValue('OUTLOOK_ANDROID_REDIRECT_URI'),
    );
    if (androidRedirectUri.isNotEmpty) {
      return androidRedirectUri;
    }
    final redirectUri = _normalizeOutlookAndroidRedirectUri(
      _resolveOutlookWebRedirectUri(),
    );
    if (redirectUri.toLowerCase().startsWith('msauth://')) {
      return redirectUri;
    }
    return '';
  }

  bool _canUseOutlookNativeAuth() {
    if (kIsWeb) {
      return false;
    }
    // The "native" Outlook path builds a `SingleAccountPca` from
    // `AndroidConfig` + assets/msal_config.json, so it only works on Android.
    // Reaching it from any other non-web target just throws, which is why
    // desktop uses the Supabase loopback flow instead.
    if (_useLoopbackOutlookOAuth) {
      return false;
    }
    return _resolveOutlookClientId().isNotEmpty &&
        _resolveOutlookAndroidRedirectUri().isNotEmpty;
  }

  Config _buildOutlookConfig({
    bool forceAccountSelection = false,
    String? loginHint,
  }) {
    final tenant = _resolveOutlookTenantId();
    final clientId = _resolveOutlookClientId();
    final redirectUri = kIsWeb
        ? _resolveOutlookWebRedirectUri()
        : (_resolveOutlookAndroidRedirectUri().isNotEmpty
              ? _resolveOutlookAndroidRedirectUri()
              : _resolveOutlookWebRedirectUri());

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
      prompt: forceAccountSelection ? 'select_account' : null,
      loginHint: loginHint,
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

  Future<DateTime> _fallbackOutlookExpiry() async {
    return DateTime.now().add(
      await (() async {
        try {
          return await appConfigService.getDuration(
            'calendar.default_token_expiry_seconds',
            defaultValue: const Duration(minutes: 55),
          );
        } catch (e) {
          return const Duration(minutes: 55);
        }
      })(),
    );
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

  Future<DateTime> _resolveOutlookTokenExpiry(String token) async {
    final jwtExpiry = _extractJwtExpiry(token);
    return jwtExpiry ?? await _fallbackOutlookExpiry();
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

  Future<void> _ensureOutlookOAuth({
    bool allowNonWeb = false,
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
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
        _outlookTokenExpiry = await _resolveOutlookTokenExpiry(redirectToken);
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
      if (forceAccountSelection) {
        // The cached client was built without a prompt, so it would sign the
        // user back in with the account already signed in on the device.
        _outlookOAuth = AadOAuth(
          _buildOutlookConfig(
            forceAccountSelection: true,
            loginHint: loginHint,
          ),
        );
      } else {
        _outlookOAuth ??= AadOAuth(
          _buildOutlookConfig(loginHint: loginHint),
        );
      }
    }
  }

  Future<void> _loadOutlookTokenFromCache() async {
    try {
      _outlookAccessToken = await _secureRead(_outlookTokenKey);
      final expiryString = await _secureRead(_outlookTokenExpiryKey);
      if (expiryString != null) {
        _outlookTokenExpiry = DateTime.tryParse(expiryString);
      }
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  Future<void> _saveOutlookTokenToCache(String token, DateTime expiry) async {
    try {
      await _secureWrite(_outlookTokenKey, token);
      await _secureWrite(_outlookTokenExpiryKey, expiry.toIso8601String());
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  Future<void> _clearOutlookTokenCache() async {
    try {
      await _secureDelete(_outlookTokenKey);
      await _secureDelete(_outlookTokenExpiryKey);
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    }
  }

  Future<bool> _isOutlookTokenExpired() async {
    if (_outlookTokenExpiry == null) return true;
    return DateTime.now().isAfter(
      _outlookTokenExpiry!.subtract(
        await (() async {
          try {
            return await appConfigService.getDuration(
              'calendar.token_refresh_buffer_seconds',
              defaultValue: const Duration(minutes: 5),
            );
          } catch (e) {
            return const Duration(minutes: 5);
          }
        })(),
      ),
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
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
    try {
      if (kIsWeb) {
        await _ensureOutlookOAuth(allowNonWeb: allowNonWeb);
        final token = await _signInOutlookWebWithFallback(
          forceConsent: forceConsent,
          forceAccountSelection: forceAccountSelection,
          loginHint: loginHint,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = await _resolveOutlookTokenExpiry(token);
          await _saveOutlookTokenToCache(
            _outlookAccessToken!,
            _outlookTokenExpiry!,
          );
          _outlookWebRedirectInProgress = false;
          return token;
        }
        return null;
      } else {
        if (!allowNonWeb) {
          throw CalendarSyncException(
            'Outlook OAuth requires mobile platform',
            userMessage: 'calendarSyncOutlookMobileOnly',
          );
        }
        // Desktop: neither msal_auth nor aad_oauth can complete a flow here -
        // both come back through a registered custom-scheme protocol handler,
        // which Windows/Linux/macOS do not have. Supabase mediates the provider
        // exchange for us over the loopback redirect instead.
        if (_useLoopbackOutlookOAuth) {
          final payload = await _ensureAzureProviderSessionPayload(
            forceAccountSelection: forceAccountSelection,
            loginHint: loginHint,
          );
          final accessToken = (payload?['token'] as String?)?.trim();
          if (accessToken == null || accessToken.isEmpty) {
            return null;
          }
          final expiry =
              payload?['expiry'] as DateTime? ??
              await _resolveOutlookTokenExpiry(accessToken);
          final userEmail = (payload?['userEmail'] as String?)?.trim();
          _outlookAccessToken = accessToken;
          _outlookTokenExpiry = expiry;
          _outlookImportAccessToken = accessToken;
          _outlookImportTokenExpiry = expiry;
          _outlookImportUserEmail = userEmail != null && userEmail.isNotEmpty
              ? userEmail
              : null;
          await _saveOutlookTokenToCache(accessToken, expiry);
          await CalendarSyncService.cacheOutlookImportToken(
            token: accessToken,
            expiry: expiry,
            userEmail: _outlookImportUserEmail,
          );
          _trace('_signInOutlook: loopback OAuth token acquired');
          return accessToken;
        }
        if (_canUseOutlookNativeAuth()) {
          try {
            final payload = await _ensureOutlookNativeSessionPayload(
              forceInteractive: true,
              forceAccountSelection: forceAccountSelection,
              loginHint: loginHint,
            );
            if (payload != null) {
              final accessToken = (payload['token'] as String?)?.trim();
              final expiry = payload['expiry'] as DateTime?;
              final userEmail = (payload['userEmail'] as String?)?.trim();
              if (accessToken != null &&
                  accessToken.isNotEmpty &&
                  expiry != null) {
                _outlookAccessToken = accessToken;
                _outlookTokenExpiry = expiry;
                _outlookImportAccessToken = accessToken;
                _outlookImportTokenExpiry = expiry;
                _outlookImportUserEmail =
                    userEmail != null && userEmail.isNotEmpty
                    ? userEmail
                    : null;
                await _saveOutlookTokenToCache(accessToken, expiry);
                return accessToken;
              }
            }
          } catch (e) {
            _trace('_signInOutlook native interactive fallback: $e');
            if (defaultTargetPlatform == TargetPlatform.android) {
              if (e is CalendarSyncException) {
                rethrow;
              }
              throw CalendarSyncException(
                'Outlook native sign-in failed: $e',
                userMessage: 'calendarSyncOutlookSignIn',
                isAuthError: true,
              );
            }
          }
          if (defaultTargetPlatform == TargetPlatform.android) {
            return null;
          }
        }
        await _ensureOutlookOAuth(
          allowNonWeb: allowNonWeb,
          forceAccountSelection: forceAccountSelection,
          loginHint: loginHint,
        );
        final result = await _outlookOAuth!.login();
        return await result.fold((l) => null, (r) async {
          final accessToken = r.accessToken?.trim();
          if (accessToken == null || accessToken.isEmpty) {
            return null;
          }
          final expiry = await _resolveOutlookTokenExpiry(accessToken);
          _outlookAccessToken = accessToken;
          _outlookTokenExpiry = expiry;
          _outlookImportAccessToken = accessToken;
          _outlookImportTokenExpiry = expiry;
          _outlookImportUserEmail =
              loginHint != null && loginHint.trim().isNotEmpty
              ? loginHint.trim()
              : _outlookImportUserEmail;
          await _saveOutlookTokenToCache(accessToken, expiry);
          await CalendarSyncService.cacheOutlookImportToken(
            token: accessToken,
            expiry: expiry,
            userEmail: _outlookImportUserEmail,
          );
          return accessToken;
        });
      }
    } catch (e) {
      if (_looksLikeOutlookPermissionError(e)) {
        throw CalendarSyncException(
          'Outlook sign-in permission denied: $e',
          userMessage: 'calendarSyncOutlookPermissionDenied',
          isAuthError: true,
        );
      }
      throw CalendarSyncException(
        'Outlook sign-in failed: $e',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }
  }

  Future<String?> _signInOutlookWebWithFallback({
    required bool forceConsent,
    bool forceAccountSelection = false,
    String? loginHint,
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
          forceAccountSelection: forceAccountSelection,
          loginHint: loginHint,
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
          forceAccountSelection: forceAccountSelection,
          loginHint: loginHint,
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
            forceAccountSelection: forceAccountSelection,
            loginHint: loginHint,
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
    bool forceAccountSelection = false,
    String? loginHint,
  }) {
    return _signInOutlook(
      allowNonWeb: allowNonWeb,
      forceConsent: forceConsent,
      forceAccountSelection: forceAccountSelection,
      loginHint: loginHint,
    );
  }

  Future<String?> _getValidOutlookToken({bool allowNonWeb = false}) async {
    // Load from cache if not in memory
    if (_outlookAccessToken == null) {
      await _loadOutlookTokenFromCache();
    }

    // Check if token is valid
    if (_outlookAccessToken != null && !await _isOutlookTokenExpired()) {
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
          : DateTime.now().add(
              await (() async {
                try {
                  return await appConfigService.getDuration(
                    'calendar.default_token_expiry_seconds',
                    defaultValue: const Duration(minutes: 55),
                  );
                } catch (e) {
                  return const Duration(minutes: 55);
                }
              })(),
            );
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
      if (_outlookAccessToken != null && !await _isOutlookTokenExpired()) {
        return _outlookAccessToken;
      }
      try {
        final token = await OutlookWebAuth.instance.getAccessToken(
          scopes: _outlookMsalScopes,
          forceRefresh: false,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = await _resolveOutlookTokenExpiry(token);
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
          _outlookTokenExpiry = await _resolveOutlookTokenExpiry(token);
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
    if (!isDeviceCalendarSupported) {
      // Device calendar is Android/iOS only. Without this the plugin call below
      // throws `Bad state: DeviceCalendarPlusPlatform.instance has not been
      // initialized`, which surfaces to the user as a raw Dart error.
      _trace(
        'CalendarSyncService requestPermissions: device calendar unsupported on ${defaultTargetPlatform.name}',
      );
      throw CalendarSyncException(
        'Device calendar is not available on this platform',
        userMessage: 'calendarSyncDeviceNotSupported',
      );
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
    if (!kIsWeb && !isDeviceCalendarSupported) {
      // Reached only if a caller asked for device calendars on a platform the
      // plugin does not implement; fail with a localizable error rather than the
      // plugin's `Bad state: DeviceCalendarPlusPlatform.instance has not been
      // initialized`.
      throw CalendarSyncException(
        'Device calendar is not available on this platform',
        userMessage: 'calendarSyncDeviceNotSupported',
      );
    }
    if (kIsWeb) {
      try {
        final payload = await _googleProviderSessionPayload();
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
      } catch (e) {
        throw _mapGoogleAccessFailure(e, action: 'load calendars');
      }
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

  Future<List<ExternalCalendar>> retrieveGoogleCalendarsNonWebOAuth({
    bool allowInteractive = false,
    Future<void>? cancelSignal,
  }) async {
    final payload = await _getGoogleImportSessionPayload(
      allowInteractive: allowInteractive,
      cancelSignal: cancelSignal,
    );
    if (payload != null) {
      final token = payload['token'] as String;
      final expiry = payload['expiry'] as DateTime;
      final userEmail = payload['userEmail'] as String?;
      await _webService.seedGoogleAccessToken(
        accessToken: token,
        expiry: expiry,
        userEmail: userEmail,
      );
      try {
        return await _webService.retrieveGoogleCalendars(
          accessTokenOverride: token,
          accountLabelOverride: userEmail,
        );
      } catch (e) {
        if (_looksLikeGooglePermissionError(e)) {
          throw CalendarSyncException(
            'Google calendar permission denied: $e',
            userMessage: 'calendarSyncGooglePermissionDenied',
            isAuthError: true,
          );
        }
        if (_looksLikeGoogleAuthError(e)) {
          await CalendarSyncService.clearGoogleImportTokenCache();
          await _webService.clearGoogleAuthCache();
          throw CalendarSyncException(
            'Google authentication failed: $e',
            userMessage: 'calendarSyncGoogleAuthRequired',
            isAuthError: true,
          );
        }
        rethrow;
      }
    }
    throw CalendarSyncException(
      'Google authentication failed: no provider token available',
      userMessage: 'calendarSyncGoogleAuthRequired',
      isAuthError: true,
    );
  }

  Future<List<ExternalCalendar>> retrieveGoogleCalendarsWithAccessToken({
    required String accessToken,
    String? userEmail,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw CalendarSyncException(
        'Google authentication failed: empty access token',
        userMessage: 'calendarSyncGoogleAuthRequired',
        isAuthError: true,
      );
    }
    try {
      return await _webService.retrieveGoogleCalendars(
        accessTokenOverride: token,
        accountLabelOverride: userEmail,
      );
    } catch (e) {
      throw _mapGoogleAccessFailure(e, action: 'load calendars');
    }
  }

  /// The default calendar import window: midnight today through `days` ahead,
  /// where `days` comes from `calendar.fetch_range_days` (default 30).
  ///
  /// The start is midnight rather than `DateTime.now()` on purpose. An event
  /// that already began earlier today is still "upcoming" as far as the user is
  /// concerned, but a window anchored at the current clock time drops it without
  /// any indication - which reads as "the import is broken" when it is not.
  Future<_FetchWindow> _defaultFetchWindow() async {
    final now = DateTime.now();
    var days = 30;
    try {
      days = await appConfigService.getInt(
        'calendar.fetch_range_days',
        defaultValue: 30,
      );
    } catch (_) {
      days = 30;
    }
    return _FetchWindow(
      start: DateTime(now.year, now.month, now.day),
      end: now.add(Duration(days: days)),
    );
  }

  Future<List<ExternalEvent>> retrieveGoogleEventsNonWebOAuth(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
    bool allowInteractive = false,
    Future<void>? cancelSignal,
  }) async {
    final window = await _defaultFetchWindow();
    final start = startDate ?? window.start;
    final end = endDate ?? window.end;
    final payload = await _getGoogleImportSessionPayload(
      allowInteractive: allowInteractive,
      cancelSignal: cancelSignal,
    );
    if (payload != null) {
      final token = payload['token'] as String;
      final expiry = payload['expiry'] as DateTime;
      final userEmail = payload['userEmail'] as String?;
      await _webService.seedGoogleAccessToken(
        accessToken: token,
        expiry: expiry,
        userEmail: userEmail,
      );
      try {
        return await _webService.retrieveGoogleEvents(
          calendarId,
          start,
          end,
          accessTokenOverride: token,
        );
      } catch (e) {
        if (_looksLikeGooglePermissionError(e)) {
          throw CalendarSyncException(
            'Google calendar permission denied while loading events: $e',
            userMessage: 'calendarSyncGooglePermissionDenied',
            isAuthError: true,
          );
        }
        if (_looksLikeGoogleAuthError(e)) {
          await CalendarSyncService.clearGoogleImportTokenCache();
          await _webService.clearGoogleAuthCache();
          throw CalendarSyncException(
            'Google authentication failed: $e',
            userMessage: 'calendarSyncGoogleAuthRequired',
            isAuthError: true,
          );
        }
        rethrow;
      }
    }
    throw CalendarSyncException(
      'Google authentication failed: no provider token available',
      userMessage: 'calendarSyncGoogleAuthRequired',
      isAuthError: true,
    );
  }

  Future<List<ExternalEvent>> retrieveGoogleEventsWithAccessToken(
    String calendarId, {
    required String accessToken,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw CalendarSyncException(
        'Google authentication failed: empty access token',
        userMessage: 'calendarSyncGoogleAuthRequired',
        isAuthError: true,
      );
    }
    try {
      final window = await _defaultFetchWindow();
      final start = startDate ?? window.start;
      final end = endDate ?? window.end;
      final fetched = await _webService.retrieveGoogleEvents(
        calendarId,
        start,
        end,
        accessTokenOverride: token,
      );
      _trace(
        'retrieveGoogleEventsWithAccessToken: calendarId=$calendarId '
        'range=$start -> $end raw=${fetched.length} event(s)',
      );
      for (final e in fetched.take(5)) {
        _trace(
          '  · "${e.title}" @ ${e.start} -> ${e.end} (allDay=${e.isAllDay})',
        );
      }
      if (fetched.isEmpty) {
        _trace(
          '  ⚠️ Google returned NO events between $start and $end. Verify the '
          'calendar has events in that window, or widen '
          'calendar.fetch_range_days in app_config.',
        );
      }
      return fetched;
    } catch (e) {
      throw _mapGoogleAccessFailure(e, action: 'load events');
    }
  }

  Future<List<ExternalEvent>> retrieveEvents(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final window = await _defaultFetchWindow();
    final start = startDate ?? window.start;
    final end = endDate ?? window.end;

    if (kIsWeb) {
      try {
        final payload = await _googleProviderSessionPayload();
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
      } catch (e) {
        throw _mapGoogleAccessFailure(e, action: 'load events');
      }
    }

    if (!isDeviceCalendarSupported) {
      throw CalendarSyncException(
        'Device calendar is not available on this platform',
        userMessage: 'calendarSyncDeviceNotSupported',
      );
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
          availability: e.availability.name,
          attendeeCount: e.attendees?.isEmpty == false
              ? e.attendees!.length
              : null,
          recurrenceRule: e.isRecurring ? e.recurrenceRule?.rruleString : null,
        );
      }).toList();
    } catch (e) {
      _trace(
        'CalendarSyncService retrieveEvents failed calendarId=$calendarId error=$e',
      );
      return [];
    }
  }

  Future<bool> openDeviceCalendarEvent(String instanceId) async {
    final trimmedId = instanceId.trim();
    if (kIsWeb || trimmedId.isEmpty) {
      return false;
    }
    if (!isDeviceCalendarSupported) {
      _trace('openDeviceCalendarEvent: unsupported platform, ignoring');
      return false;
    }

    try {
      final permissionStatus = await _deviceCalendar.hasPermissions();
      if (permissionStatus != CalendarPermissionStatus.granted) {
        return false;
      }

      await _deviceCalendar.showEventModal(trimmedId);
      return true;
    } catch (e) {
      _trace(
        'CalendarSyncService openDeviceCalendarEvent failed instanceId=$trimmedId error=$e',
      );
      return false;
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
          // Empty titles are rendered by the UI via the
          // `eventNoTitle` translation-table key (never hardcoded here).
          title: title != null && title.isNotEmpty ? title : '',
          start: normalizedStart,
          end: normalizedEnd,
          description: (item['description'] as String?)?.trim(),
          isAllDay: item['isAllDay'] == true,
          location: (item['location'] as String?)?.trim(),
          url: Uri.tryParse((item['url'] as String?) ?? ''),
          organizer: (item['organizer'] as String?)?.trim(),
          visibility: (item['class'] as String?)?.trim(),
          recurrenceRule: (item['rrule'] as String?)?.trim(),
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

        if (response.statusCode == 403) {
          throw CalendarSyncException(
            'Outlook permission denied: ${response.body}',
            userMessage: 'calendarSyncOutlookPermissionDenied',
            isAuthError: true,
          );
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

  Future<List<ExternalCalendar>> retrieveOutlookCalendarsWithAccessToken({
    required String accessToken,
    String? userEmail,
  }) async {
    return _retrieveOutlookCalendarsWithToken(
      accessToken: accessToken,
      userEmail: userEmail,
    );
  }

  /// Explicit Outlook OAuth retrieval for non-web platforms (mobile/desktop)
  Future<List<ExternalCalendar>> retrieveOutlookCalendarsNonWebOAuth() async {
    return retrieveOutlookCalendars(allowNonWeb: true);
  }

  Future<List<ExternalCalendar>> _retrieveOutlookCalendarsWithToken({
    required String accessToken,
    String? userEmail,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
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
          throw CalendarSyncException(
            'Outlook authentication expired',
            userMessage: 'calendarSyncOutlookExpired',
            isAuthError: true,
          );
        }
        if (response.statusCode == 403) {
          throw CalendarSyncException(
            'Outlook permission denied: ${response.body}',
            userMessage: 'calendarSyncOutlookPermissionDenied',
            isAuthError: true,
          );
        }
        if (response.statusCode != 200) {
          throw CalendarSyncException(
            'Outlook API error: ${response.statusCode}',
            userMessage: 'calendarSyncOutlookFailed',
          );
        }
        final data = json.decode(response.body) as Map<String, dynamic>;
        final items = data['value'] as List<dynamic>? ?? [];
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
              accountName: userEmail ?? ownerAddress ?? 'Outlook',
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

  /// Retrieve events from multiple calendars
  Future<List<EventModel>> retrieveEventsFromCalendars(
    List<ExternalCalendar> calendars,
  ) async {
    final allEvents = <EventModel>[];

    for (final calendar in calendars) {
      try {
        final externalEvents = await retrieveEvents(calendar.id);
        for (final externalEvent in externalEvents) {
          // Convert ExternalEvent to EventModel
          final event = EventModel(
            id: '', // Will be generated when saved
            eventName: externalEvent.title,
            startTime: externalEvent.start ?? DateTime.now(),
            endTime:
                externalEvent.end ??
                externalEvent.start?.add(const Duration(hours: 1)) ??
                DateTime.now().add(const Duration(hours: 1)),
            eventVenue: externalEvent.location,
            description: externalEvent.description,
            isAllDay: externalEvent.isAllDay,
            externalCalendarId: calendar.id,
            externalEventId: externalEvent.id,
            externalProvider: _calendarProviderToString(calendar.accountType),
            markedPrivateInSource: isMarkedPrivateInSourceCalendar(
              availability: externalEvent.availability,
              transparency: externalEvent.transparency,
              visibility: externalEvent.visibility,
              sensitivity: externalEvent.sensitivity,
            ),
          );
          allEvents.add(event);
        }
      } catch (e) {
        _trace('Failed to retrieve events from calendar ${calendar.id}: $e');
      }
    }

    return allEvents;
  }

  String _calendarProviderToString(String? accountType) {
    if (accountType == null) return 'unknown';
    final lower = accountType.toLowerCase();
    if (lower.contains('google')) return 'google';
    if (lower.contains('outlook') || lower.contains('microsoft')) {
      return 'outlook';
    }
    if (lower.contains('apple') || lower.contains('icloud')) return 'apple';
    return 'unknown';
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

    final window = await _defaultFetchWindow();
    final start = (startDate ?? window.start).toUtc();
    final end = (endDate ?? window.end).toUtc();

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

        if (response.statusCode == 403) {
          throw CalendarSyncException(
            'Outlook permission denied while loading events: ${response.body}',
            userMessage: 'calendarSyncOutlookPermissionDenied',
            isAuthError: true,
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
              sensitivity: map['sensitivity'] as String?,
              availability: map['showAs'] as String?,
              attendeeCount: (map['attendees'] as List<dynamic>?)
                  ?.whereType<Map<String, dynamic>>()
                  .length,
              recurrenceRule:
                  ((map['recurrence'] as Map<String, dynamic>?)?['pattern']
                          as Map<String, dynamic>?)?['type']
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

  Future<List<ExternalEvent>> retrieveOutlookEventsWithAccessToken(
    String calendarId, {
    required String accessToken,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    return _retrieveOutlookEventsWithToken(
      calendarId,
      accessToken: accessToken,
      startDate: startDate,
      endDate: endDate,
    );
  }

  Future<List<ExternalEvent>> _retrieveOutlookEventsWithToken(
    String calendarId, {
    required String accessToken,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw CalendarSyncException(
        'Outlook authentication failed',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    final window = await _defaultFetchWindow();
    final start = (startDate ?? window.start).toUtc();
    final end = (endDate ?? window.end).toUtc();
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
          throw CalendarSyncException(
            'Outlook authentication expired',
            userMessage: 'calendarSyncOutlookExpired',
            isAuthError: true,
          );
        }

        if (response.statusCode == 403) {
          throw CalendarSyncException(
            'Outlook permission denied while loading events: ${response.body}',
            userMessage: 'calendarSyncOutlookPermissionDenied',
            isAuthError: true,
          );
        }

        if (response.statusCode != 200) {
          throw CalendarSyncException(
            'Outlook API error: ${response.statusCode}',
            userMessage: 'calendarSyncOutlookEventsFailed',
          );
        }

        final data = json.decode(response.body) as Map<String, dynamic>;
        final items = data['value'] as List<dynamic>? ?? [];

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

            DateTime? normalizeDate(DateTime? dateTime) {
              if (dateTime == null) return null;
              if (isAllDay) {
                return DateTime(dateTime.year, dateTime.month, dateTime.day);
              }
              return dateTime.isUtc ? dateTime.toLocal() : dateTime;
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
              sensitivity: map['sensitivity'] as String?,
              availability: map['showAs'] as String?,
              attendeeCount: (map['attendees'] as List<dynamic>?)
                  ?.whereType<Map<String, dynamic>>()
                  .length,
              recurrenceRule:
                  ((map['recurrence'] as Map<String, dynamic>?)?['pattern']
                          as Map<String, dynamic>?)?['type']
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

/// Completes when the user returns to the app during a loopback calendar OAuth
/// attempt. See [CalendarSyncService._abandonCalendarOAuthAfterResume].
class _CalendarOAuthCancellation {
  final Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Internal signal: the user left the browser without completing the flow.
class _CalendarOAuthAbandoned implements Exception {
  const _CalendarOAuthAbandoned();

  @override
  String toString() => '_CalendarOAuthAbandoned';
}

/// Default calendar import window. See
/// [CalendarSyncService._defaultFetchWindow].
class _FetchWindow {
  const _FetchWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}
