import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as google_calendar;
import 'package:http/http.dart' as http;
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/google_sign_in_nonce.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExternalCalendar {
  final String id;
  final String name;
  final bool isReadOnly;
  final bool isDefault;
  final String? accountName;
  final String? accountType;

  const ExternalCalendar({
    required this.id,
    required this.name,
    required this.isReadOnly,
    required this.isDefault,
    this.accountName,
    this.accountType,
  });
}

class ExternalEvent {
  final String calendarId;
  final String id;
  final String title;
  final DateTime? start;
  final DateTime? end;
  final String? description;
  final bool isAllDay;
  final String? location;
  final Uri? url;
  final String? organizer;

  /// Provider-native privacy/availability signals, used to keep private
  /// items out of the import pickers. Null when the provider doesn't expose
  /// the signal.
  ///
  /// - device: Availability enum name (busy/free/tentative/unavailable)
  /// - outlook: event "showAs" value (free/busy/oof/workingElsewhere/…)
  final String? availability;

  /// Google only: "transparent" means the slot is shown as free.
  final String? transparency;

  /// Google / Apple ICS CLASS: default/public/private/confidential.
  final String? visibility;

  /// Outlook only: normal/personal/private/confidential.
  final String? sensitivity;

  /// Number of attendees on the event, when the provider exposes the
  /// guest list. Drives the self-organized-small-meeting heuristic.
  final int? attendeeCount;

  /// Recurrence description (RRULE string for Google/device/ICS, Outlook
  /// pattern type for Graph). Drives the routine-recurrence heuristic.
  final String? recurrenceRule;

  const ExternalEvent({
    required this.calendarId,
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.description,
    required this.isAllDay,
    required this.location,
    required this.url,
    required this.organizer,
    this.availability,
    this.transparency,
    this.visibility,
    this.sensitivity,
    this.attendeeCount,
    this.recurrenceRule,
  });
}

/// How a Google ID token's nonce claim relates to the app's raw nonce.
enum GoogleIdTokenNonce {
  /// The token carries the hashed nonce claim that matches the raw nonce.
  match,

  /// The token carries no nonce claim; Supabase accepts it only when no
  /// nonce parameter is sent either.
  absent,

  /// The token carries a nonce that doesn't match (e.g. minted by an older
  /// app run before persistence); Supabase would reject it, so callers must
  /// fall back to the interactive flow.
  mismatch,
}

class WebCalendarService {
  static const List<String> _scopes = [
    google_calendar.CalendarApi.calendarReadonlyScope,
    google_calendar.CalendarApi.calendarEventsReadonlyScope,
  ];

  static const String _googleAccessTokenKey = 'google_calendar_access_token';
  static const String _googleAccessTokenExpiryKey =
      'google_calendar_access_token_expiry';
  static const String _googleUserEmailKey = 'google_calendar_user_email';
  static const String _googleSignInNonceKey = 'google_sign_in_raw_nonce';
  static Future<void>? _sharedGoogleSignInInitFuture;
  static String? _lastInitializedClientId;
  static String? _lastInitializedServerClientId;
  static String? _googleSignInRawNonce;

  static String _createGoogleSignInNonce() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Returns the device's Google Sign-In nonce, generating and persisting it
  /// on first use. Persistence matters for silently restored sessions: Google
  /// embeds the hash of the nonce used at sign-in time in the ID token, and
  /// Supabase re-hashes the raw nonce we pass to `signInWithIdToken` and
  /// compares it with that claim. Without persistence a restarted app would
  /// present a different nonce than the one baked into the restored token.
  static Future<String> _loadOrCreateRawNonce() async {
    final inMemory = _googleSignInRawNonce;
    if (inMemory != null && inMemory.isNotEmpty) return inMemory;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_googleSignInNonceKey);
      if (stored != null && stored.isNotEmpty) {
        _googleSignInRawNonce = stored;
        return stored;
      }
      final created = _createGoogleSignInNonce();
      await prefs.setString(_googleSignInNonceKey, created);
      _googleSignInRawNonce = created;
      return created;
    } catch (_) {
      return _googleSignInRawNonce ??= _createGoogleSignInNonce();
    }
  }

  /// Inspects the nonce claim inside a Google ID token so a silently restored
  /// session can be validated by Supabase.
  ///
  /// Supabase requires the claim and the `nonce` parameter to either both
  /// exist (and match after SHA-256) or both be absent.
  static GoogleIdTokenNonce googleIdTokenNonceState(
    String idToken,
    String rawNonce,
  ) {
    try {
      final parts = idToken.split('.');
      if (parts.length != 3) return GoogleIdTokenNonce.mismatch;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      if (claims is! Map<String, dynamic>) return GoogleIdTokenNonce.mismatch;
      final claim = claims['nonce'];
      if (claim is! String || claim.isEmpty) return GoogleIdTokenNonce.absent;
      return claim == hashGoogleSignInNonce(rawNonce)
          ? GoogleIdTokenNonce.match
          : GoogleIdTokenNonce.mismatch;
    } catch (_) {
      return GoogleIdTokenNonce.mismatch;
    }
  }

  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final StreamController<GoogleSignInAccount?> _userController =
      StreamController<GoogleSignInAccount?>.broadcast();
  GoogleSignInAccount? _currentUser;
  bool _isInitialized = false;
  bool _isInitializing = false;
  http.Client? _activeClient;
  String? _cachedAccessToken;
  DateTime? _cachedAccessTokenExpiry;
  String? _cachedUserEmail;
  bool _didLoadTokenCache = false;

  WebCalendarService();

  void _trace(String message) {
    print(message);
    developer.log(message, name: 'WebCalendarService');
  }

  static String _envValue(String key) {
    final defineValue = switch (key) {
      'GOOGLE_CLIENT_ID' => const String.fromEnvironment(
        'GOOGLE_CLIENT_ID',
        defaultValue: '',
      ).trim(),
      'GOOGLE_SERVER_CLIENT_ID' => const String.fromEnvironment(
        'GOOGLE_SERVER_CLIENT_ID',
        defaultValue: '',
      ).trim(),
      'GOOGLE_ANDROID_CLIENT_ID' => const String.fromEnvironment(
        'GOOGLE_ANDROID_CLIENT_ID',
        defaultValue: '',
      ).trim(),
      'GOOGLE_IOS_CLIENT_ID' => const String.fromEnvironment(
        'GOOGLE_IOS_CLIENT_ID',
        defaultValue: '',
      ).trim(),
      _ => '',
    };
    if (defineValue.isNotEmpty) {
      return defineValue;
    }
    return (dotenv.env[key] ?? '').trim();
  }

  static Future<String> ensureGoogleSignInInitialized({
    required String clientId,
    String? serverClientId,
  }) async {
    final normalizedClientId = clientId.trim();
    final normalizedServerClientId = serverClientId?.trim() ?? '';
    final rawNonce = await _loadOrCreateRawNonce();
    // Google embeds the hash in its ID token; Supabase verifies that claim
    // against the raw nonce passed to signInWithIdToken.
    final hashedNonce = hashGoogleSignInNonce(rawNonce);

    if (_lastInitializedClientId == normalizedClientId &&
        _lastInitializedServerClientId == normalizedServerClientId) {
      print(
        'WebCalendarService.ensureGoogleSignInInitialized: already initialized with same client IDs',
      );
      return rawNonce;
    }

    print(
      'WebCalendarService.ensureGoogleSignInInitialized: clientId=$normalizedClientId, serverClientId=$normalizedServerClientId, kIsWeb=$kIsWeb',
    );
    if (kIsWeb && normalizedClientId.isEmpty) {
      print(
        'WebCalendarService.ensureGoogleSignInInitialized: ABORTING - clientId is empty on Web',
      );
      return rawNonce;
    }
    final pendingInit = _sharedGoogleSignInInitFuture;
    if (pendingInit != null) {
      await pendingInit;
      return rawNonce;
    }
    final Future<void> initFuture = () async {
      if (kIsWeb) {
        await GoogleSignIn.instance.initialize(
          clientId: normalizedClientId,
          nonce: hashedNonce,
        );
        return;
      }
      if (normalizedServerClientId.isNotEmpty) {
        await GoogleSignIn.instance.initialize(
          clientId: normalizedClientId,
          serverClientId: normalizedServerClientId,
          nonce: hashedNonce,
        );
        return;
      }
      if (normalizedClientId.isNotEmpty) {
        await GoogleSignIn.instance.initialize(
          clientId: normalizedClientId,
          serverClientId: normalizedClientId,
          nonce: hashedNonce,
        );
      } else {
        await GoogleSignIn.instance.initialize(nonce: hashedNonce);
      }
    }();
    _sharedGoogleSignInInitFuture = initFuture;
    try {
      await initFuture;
      _lastInitializedClientId = normalizedClientId;
      _lastInitializedServerClientId = normalizedServerClientId;
      return rawNonce;
    } catch (_) {
      _sharedGoogleSignInInitFuture = null;
      rethrow;
    }
  }

  Future<void> ensureInitialized() async {
    await _init();
  }

  Future<void> seedGoogleAccessToken({
    required String accessToken,
    DateTime? expiry,
    String? userEmail,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) return;
    final exp = expiry ?? DateTime.now().add(const Duration(minutes: 55));
    await _saveGoogleTokenToCache(token, exp);
    final email = userEmail?.trim();
    if (email != null && email.isNotEmpty) {
      await _saveGoogleUserEmailToCache(email);
    }
  }

  Future<void> _init() async {
    if (_isInitialized || _isInitializing) return;
    _isInitializing = true;
    try {
      print(
        'WebCalendarService._init: starting initialization. dotenv.isInitialized=${dotenv.isInitialized}',
      );
      final clientId = _envValue('GOOGLE_CLIENT_ID');
      final serverClientId = _envValue('GOOGLE_SERVER_CLIENT_ID').isNotEmpty
          ? _envValue('GOOGLE_SERVER_CLIENT_ID')
          : clientId;
      final androidClientId = _envValue('GOOGLE_ANDROID_CLIENT_ID');
      final iosClientId = _envValue('GOOGLE_IOS_CLIENT_ID');

      print('WebCalendarService._init: GOOGLE_CLIENT_ID=$clientId');
      print(
        'WebCalendarService._init: GOOGLE_SERVER_CLIENT_ID=$serverClientId',
      );
      print(
        'WebCalendarService._init: GOOGLE_ANDROID_CLIENT_ID=$androidClientId',
      );
      print('WebCalendarService._init: GOOGLE_IOS_CLIENT_ID=$iosClientId');

      if (kIsWeb && clientId.isEmpty) {
        print(
          'WebCalendarService._init: GOOGLE_CLIENT_ID is empty on Web, aborting',
        );
        return;
      }

      final platformClientId = switch (defaultTargetPlatform) {
        TargetPlatform.android => androidClientId,
        TargetPlatform.iOS => iosClientId,
        _ => clientId,
      };
      await ensureGoogleSignInInitialized(
        clientId: !kIsWeb && platformClientId.isNotEmpty
            ? platformClientId
            : clientId,
        serverClientId: serverClientId,
      );
      _googleSignIn.authenticationEvents
          .listen((event) {
            if (event is GoogleSignInAuthenticationEventSignIn) {
              _currentUser = event.user;
              _cachedUserEmail = event.user.email;
              unawaited(_saveGoogleUserEmailToCache(event.user.email));
            } else {
              _currentUser = null;
              _activeClient?.close();
              _activeClient = null;
              _cachedAccessToken = null;
              _cachedAccessTokenExpiry = null;
              _cachedUserEmail = null;
              unawaited(_clearGoogleTokenCache());
            }
            _userController.add(_currentUser);
          })
          .onError((e, st) {
            if (e is GoogleSignInException &&
                e.code == GoogleSignInExceptionCode.canceled) {
              return;
            }
          });

      await _loadGoogleTokenFromCache();

      _isInitialized = true;
    } finally {
      _isInitializing = false;
    }
  }

  void dispose() {
    _activeClient?.close();
    _userController.close();
  }

  Future<void> _loadGoogleTokenFromCache() async {
    if (_didLoadTokenCache) return;
    _didLoadTokenCache = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_googleAccessTokenKey);
      final expiryRaw = prefs.getString(_googleAccessTokenExpiryKey);
      final expiry = expiryRaw != null ? DateTime.tryParse(expiryRaw) : null;
      if (token == null || token.isEmpty || expiry == null) return;
      _cachedAccessToken = token;
      _cachedAccessTokenExpiry = expiry;
      _cachedUserEmail = prefs.getString(_googleUserEmailKey);
    } catch (_) {}
  }

  Future<void> _saveGoogleTokenToCache(String token, DateTime expiry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_googleAccessTokenKey, token);
      await prefs.setString(
        _googleAccessTokenExpiryKey,
        expiry.toIso8601String(),
      );
      _cachedAccessToken = token;
      _cachedAccessTokenExpiry = expiry;
    } catch (_) {}
  }

  Future<void> _saveGoogleUserEmailToCache(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_googleUserEmailKey, email);
      _cachedUserEmail = email;
    } catch (_) {}
  }

  Future<void> _clearGoogleTokenCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_googleAccessTokenKey);
      await prefs.remove(_googleAccessTokenExpiryKey);
      await prefs.remove(_googleUserEmailKey);
    } catch (_) {}
  }

  bool _isCachedTokenExpired() {
    if (_cachedAccessToken == null || _cachedAccessTokenExpiry == null) {
      return true;
    }
    return DateTime.now().isAfter(
      _cachedAccessTokenExpiry!.subtract(const Duration(minutes: 5)),
    );
  }

  Future<void> _tryCacheAuthorization(dynamic authorization) async {
    String? token;
    DateTime? expiry;
    try {
      token = (authorization as dynamic).accessToken as String?;
    } catch (_) {}
    try {
      final raw = (authorization as dynamic).expiresAt;
      if (raw is DateTime) {
        expiry = raw;
      } else if (raw is String) {
        expiry = DateTime.tryParse(raw);
      } else if (raw is int) {
        expiry = DateTime.fromMillisecondsSinceEpoch(raw);
      }
    } catch (_) {}
    if (token == null || token.isEmpty) return;
    expiry ??= DateTime.now().add(const Duration(minutes: 55));
    await _saveGoogleTokenToCache(token, expiry);
    final email = _currentUser?.email;
    if (email != null && email.isNotEmpty) {
      await _saveGoogleUserEmailToCache(email);
    }
  }

  Map<String, dynamic>? _authorizationPayload({
    required dynamic authorization,
    required String? userEmail,
  }) {
    String? token;
    DateTime? expiry;
    try {
      token = (authorization as dynamic).accessToken as String?;
    } catch (_) {}
    try {
      final raw = (authorization as dynamic).expiresAt;
      if (raw is DateTime) {
        expiry = raw;
      } else if (raw is String) {
        expiry = DateTime.tryParse(raw);
      } else if (raw is int) {
        expiry = DateTime.fromMillisecondsSinceEpoch(raw);
      }
    } catch (_) {}
    final normalizedToken = token?.trim();
    if (normalizedToken == null || normalizedToken.isEmpty) {
      return null;
    }
    return {
      'token': normalizedToken,
      'expiry': expiry ?? DateTime.now().add(const Duration(minutes: 55)),
      'userEmail': userEmail?.trim().isNotEmpty == true
          ? userEmail!.trim()
          : null,
    };
  }

  Future<GoogleSignInAccount?> _recoverAuthenticatedUserAfterFailure() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final currentUser = _currentUser;
      if (currentUser != null) {
        _trace(
          'authenticateGoogleCalendarAccess: recovered current user from auth event stream on attempt ${attempt + 1}: ${currentUser.email}',
        );
        return currentUser;
      }
    }
    try {
      final lightweightUser = await _googleSignIn
          .attemptLightweightAuthentication();
      if (lightweightUser != null) {
        _trace(
          'authenticateGoogleCalendarAccess: recovered lightweight user ${lightweightUser.email}',
        );
        _currentUser = lightweightUser;
        _cachedUserEmail = lightweightUser.email;
        await _saveGoogleUserEmailToCache(lightweightUser.email);
      } else {
        _trace(
          'authenticateGoogleCalendarAccess: lightweight recovery returned no user',
        );
      }
      return lightweightUser;
    } catch (e) {
      _trace(
        'authenticateGoogleCalendarAccess: lightweight recovery failed: $e',
      );
      return _currentUser;
    }
  }

  Future<dynamic> _getGoogleAuthorization(
    GoogleSignInAccount googleUser,
  ) async {
    dynamic authorization;
    try {
      authorization = await googleUser.authorizationClient
          .authorizationForScopes(_scopes);
    } catch (_) {}
    authorization ??= await googleUser.authorizationClient.authorizeScopes(
      _scopes,
    );
    return authorization;
  }

  Future<Map<String, dynamic>?> authenticateGoogleCalendarAccess({
    bool forceAccountSelection = false,
  }) async {
    await _init();
    if (!_isInitialized || kIsWeb) {
      return null;
    }
    _trace(
      'authenticateGoogleCalendarAccess: start forceAccountSelection=$forceAccountSelection currentUser=${_currentUser?.email ?? 'none'} cachedUser=${_cachedUserEmail ?? 'none'}',
    );
    if (forceAccountSelection) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {
        try {
          await _googleSignIn.disconnect();
        } catch (_) {}
      }
      _currentUser = null;
      _activeClient?.close();
      _activeClient = null;
      _cachedAccessToken = null;
      _cachedAccessTokenExpiry = null;
      _cachedUserEmail = null;
      await _clearGoogleTokenCache();
      _trace(
        'authenticateGoogleCalendarAccess: cleared existing Google session before account selection',
      );
    }
    final GoogleSignInAccount googleUser;
    try {
      final authenticatedUser = await _googleSignIn.authenticate(
        scopeHint: _scopes,
      );
      googleUser = authenticatedUser;
      _trace(
        'authenticateGoogleCalendarAccess: authenticate returned user ${googleUser.email}',
      );
    } on GoogleSignInException catch (e) {
      _trace(
        'authenticateGoogleCalendarAccess: authenticate threw ${e.code}: $e',
      );
      _trace(
        'authenticateGoogleCalendarAccess: GoogleSignInException details - code: ${e.code}, toString: ${e.toString()}, runtimeType: ${e.runtimeType}',
      );
      if (e.code == GoogleSignInExceptionCode.canceled) {
        final recoveredUser = await _recoverAuthenticatedUserAfterFailure();
        if (recoveredUser == null) {
          _trace(
            'authenticateGoogleCalendarAccess: no user recovered after canceled exception',
          );
          return null;
        }
        _currentUser = recoveredUser;
        _cachedUserEmail = recoveredUser.email;
        await _saveGoogleUserEmailToCache(recoveredUser.email);
        final authorization = await _getGoogleAuthorization(recoveredUser);
        _trace(
          'authenticateGoogleCalendarAccess: recovered user authorization completed for ${recoveredUser.email}',
        );
        await _tryCacheAuthorization(authorization);
        return _authorizationPayload(
          authorization: authorization,
          userEmail: recoveredUser.email,
        );
      }
      rethrow;
    }
    _currentUser = googleUser;
    _cachedUserEmail = googleUser.email;
    await _saveGoogleUserEmailToCache(googleUser.email);
    final authorization = await _getGoogleAuthorization(googleUser);
    _trace(
      'authenticateGoogleCalendarAccess: authorization completed for ${googleUser.email}',
    );
    await _tryCacheAuthorization(authorization);
    return _authorizationPayload(
      authorization: authorization,
      userEmail: googleUser.email,
    );
  }

  bool _looksLikeAuthError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('401') ||
        text.contains('unauthorized') ||
        text.contains('authentication') ||
        text.contains('authenticated client') ||
        text.contains('sign in again') ||
        text.contains('failed to authenticate with google') ||
        text.contains('user information is not available') ||
        text.contains('google sign in') ||
        text.contains('apiexception: 10') ||
        text.contains('developer error') ||
        text.contains('clientconfiguration');
  }

  bool _isPopupClosedError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('popup') ||
        text.contains('window.closed') ||
        text.contains('closed_by_user') ||
        text.contains('cancel') ||
        text.contains('canceled');
  }

  Future<void> _invalidateGoogleAuth() async {
    _activeClient?.close();
    _activeClient = null;
    _cachedAccessToken = null;
    _cachedAccessTokenExpiry = null;
    _cachedUserEmail = null;
    await _clearGoogleTokenCache();
  }

  Future<void> clearGoogleAuthCache() async {
    await _invalidateGoogleAuth();
  }

  Future<http.Client?> _createAuthenticatedClient({
    bool allowInteractive = true,
  }) async {
    try {
      if (_activeClient != null) return _activeClient;

      await _loadGoogleTokenFromCache();
      if (!_isCachedTokenExpired()) {
        _activeClient = _BearerClient(http.Client(), _cachedAccessToken!);
        return _activeClient;
      }

      if (!kIsWeb && allowInteractive && _currentUser == null) {
        try {
          final signedInUser = await _googleSignIn.authenticate();
          _currentUser = signedInUser;
          _cachedUserEmail = signedInUser.email;
          unawaited(_saveGoogleUserEmailToCache(signedInUser.email));
        } catch (_) {}
      }

      final authClient = _googleSignIn.authorizationClient;
      var authorization = await authClient.authorizationForScopes(_scopes);
      if (authorization == null && allowInteractive) {
        authorization = await authClient.authorizeScopes(_scopes);
      }
      if (authorization == null) return null;

      // Use the extension to create an authenticated client directly
      // This handles the 'Bearer' token and headers automatically
      _activeClient = authorization.authClient(scopes: _scopes);
      await _tryCacheAuthorization(authorization);
      return _activeClient;
    } catch (e) {
      throw Exception('Google sign in failed: $e');
    }
  }

  Stream<GoogleSignInAccount?> get onCurrentUserChanged =>
      _userController.stream;
  GoogleSignInAccount? get currentUser => _currentUser;

  Future<List<String>> listAvailableGoogleAccountEmails() async {
    await _init();
    final emails = <String>{};

    final currentEmail = _currentUser?.email.trim();
    if (currentEmail != null && currentEmail.isNotEmpty) {
      emails.add(currentEmail);
    }

    await _loadGoogleTokenFromCache();
    final cachedEmail = _cachedUserEmail?.trim();
    if (cachedEmail != null && cachedEmail.isNotEmpty) {
      emails.add(cachedEmail);
    }

    if (!kIsWeb && _currentUser == null) {
      try {
        final lightweightUser = await _googleSignIn
            .attemptLightweightAuthentication();
        final lightweightEmail = lightweightUser?.email.trim();
        if (lightweightEmail != null && lightweightEmail.isNotEmpty) {
          _currentUser = lightweightUser;
          _cachedUserEmail = lightweightEmail;
          emails.add(lightweightEmail);
          await _saveGoogleUserEmailToCache(lightweightEmail);
        }
      } catch (_) {}
    }

    return emails.toList()..sort();
  }

  Future<List<ExternalCalendar>> retrieveGoogleCalendars({
    bool allowInteractive = true,
    String? accessTokenOverride,
    String? accountLabelOverride,
  }) async {
    final override = accessTokenOverride?.trim();
    if (override != null && override.isNotEmpty) {
      final tokenClient = _BearerClient(http.Client(), override);
      try {
        final calendarApi = google_calendar.CalendarApi(tokenClient);
        final calendarList = await calendarApi.calendarList.list();
        final label = (accountLabelOverride?.trim().isNotEmpty == true)
            ? accountLabelOverride!.trim()
            : 'google';
        return (calendarList.items ??
                const <google_calendar.CalendarListEntry>[])
            .map((item) {
              final id = item.id?.trim();
              if (id == null || id.isEmpty) return null;
              return ExternalCalendar(
                id: id,
                name: item.summary?.trim().isNotEmpty == true
                    ? item.summary!.trim()
                    : 'Google Calendar',
                isReadOnly: item.accessRole == 'reader',
                isDefault: item.primary == true,
                accountName: label,
                accountType: 'com.google',
              );
            })
            .whereType<ExternalCalendar>()
            .toList();
      } finally {
        tokenClient.close();
      }
    }

    await _init();
    if (!_isInitialized) return <ExternalCalendar>[];
    try {
      GoogleSignInAccount? googleUser = _currentUser;

      await _loadGoogleTokenFromCache();
      final emailForLabel = (googleUser?.email.trim().isNotEmpty == true
          ? googleUser!.email
          : (_cachedUserEmail?.trim().isNotEmpty == true
                ? _cachedUserEmail!
                : 'google'));

      http.Client? httpClient = await _createAuthenticatedClient(
        allowInteractive: allowInteractive,
      );
      if (httpClient == null) {
        throw Exception(
          'Failed to get authenticated client. Please sign in again.',
        );
      }

      final calendarApi = google_calendar.CalendarApi(httpClient);
      final calendarList = await calendarApi.calendarList.list();

      return (calendarList.items ?? const <google_calendar.CalendarListEntry>[])
          .map((item) {
            final id = item.id?.trim();
            if (id == null || id.isEmpty) return null;
            return ExternalCalendar(
              id: id,
              name: item.summary?.trim().isNotEmpty == true
                  ? item.summary!.trim()
                  : 'Google Calendar',
              isReadOnly: item.accessRole == 'reader',
              isDefault: item.primary == true,
              accountName: emailForLabel,
              accountType: 'com.google',
            );
          })
          .whereType<ExternalCalendar>()
          .toList();
    } on http.ClientException catch (_) {
      throw Exception(
        'Network error. Please check your internet connection and try again.',
      );
    } catch (e) {
      if (_looksLikeAuthError(e)) {
        final errorText = e.toString().toLowerCase();
        final shouldRetryInteractively =
            allowInteractive &&
            !_isPopupClosedError(e) &&
            !errorText.contains('failed to get authenticated client') &&
            !errorText.contains('authentication failed');
        await _invalidateGoogleAuth();
        if (shouldRetryInteractively) {
          try {
            final httpClient = await _createAuthenticatedClient(
              allowInteractive: true,
            );
            if (httpClient == null) {
              throw Exception(
                'Failed to get authenticated client. Please sign in again.',
              );
            }
            final calendarApi = google_calendar.CalendarApi(httpClient);
            final calendarList = await calendarApi.calendarList.list();
            return (calendarList.items ??
                    const <google_calendar.CalendarListEntry>[])
                .map((item) {
                  final id = item.id?.trim();
                  if (id == null || id.isEmpty) return null;
                  final label = (_cachedUserEmail?.trim().isNotEmpty == true
                      ? _cachedUserEmail!
                      : 'google');
                  return ExternalCalendar(
                    id: id,
                    name: item.summary?.trim().isNotEmpty == true
                        ? item.summary!.trim()
                        : 'Google Calendar',
                    isReadOnly: item.accessRole == 'reader',
                    isDefault: item.primary == true,
                    accountName: label,
                    accountType: 'com.google',
                  );
                })
                .whereType<ExternalCalendar>()
                .toList();
          } catch (retryError) {
            if (_looksLikeAuthError(retryError)) {
              throw Exception(
                'Authentication failed. Please sign in with your Google account to continue.',
              );
            } else if (retryError.toString().toLowerCase().contains('popup') ||
                retryError.toString().toLowerCase().contains('window.closed')) {
              throw Exception('Sign-in was cancelled. Please try again.');
            } else {
              throw Exception(
                'Failed to authenticate with Google: $retryError',
              );
            }
          }
        }
        if (_isPopupClosedError(e)) {
          throw Exception('Sign-in was cancelled. Please try again.');
        }
        throw Exception(
          'Authentication failed. Please sign in with your Google account to continue.',
        );
      }
      throw Exception('Failed to fetch Google Calendars. $e');
    }
  }

  Future<List<ExternalEvent>> retrieveGoogleEvents(
    String calendarId,
    DateTime start,
    DateTime end, {
    bool allowInteractive = true,
    String? accessTokenOverride,
  }) async {
    final override = accessTokenOverride?.trim();
    if (override != null && override.isNotEmpty) {
      final tokenClient = _BearerClient(http.Client(), override);
      try {
        final calendarApi = google_calendar.CalendarApi(tokenClient);
        final allEvents = <ExternalEvent>[];
        String? pageToken;
        do {
          final events = await calendarApi.events.list(
            calendarId,
            timeMin: start.toUtc(),
            timeMax: end.toUtc(),
            singleEvents: true,
            orderBy: 'startTime',
            showDeleted: false,
            eventTypes: ['default'],
            maxResults: await (() async {
              try {
                return await appConfigService.getInt(
                  'calendar.google_max_results',
                  defaultValue: 250,
                );
              } catch (e) {
                return 250;
              }
            })(),
            pageToken: pageToken,
          );

          if (events.items != null) {
            allEvents.addAll(
              events.items!.map((item) {
                final startDt = item.start?.dateTime ?? item.start?.date;
                final endDt = item.end?.dateTime ?? item.end?.date;
                final isAllDay = item.start?.date != null;

                DateTime? normalizeDate(DateTime? dt) {
                  if (dt == null) return null;
                  if (isAllDay) return DateTime(dt.year, dt.month, dt.day);
                  return dt.isUtc ? dt.toLocal() : dt;
                }

                final id = item.id?.trim();
                if (id == null || id.isEmpty) {
                  return null;
                }

                return ExternalEvent(
                  calendarId: calendarId,
                  id: id,
                  title: item.summary?.trim().isNotEmpty == true
                      ? item.summary!.trim()
                      : 'No Title',
                  start: normalizeDate(startDt),
                  end: normalizeDate(endDt),
                  description: item.description,
                  isAllDay: isAllDay,
                  location: item.location,
                  url: item.htmlLink != null
                      ? Uri.tryParse(item.htmlLink!)
                      : null,
                  organizer: item.organizer?.email,
                  transparency: item.transparency,
                  visibility: item.visibility,
                  attendeeCount: item.attendees?.isEmpty == false
                      ? item.attendees!.length
                      : null,
                  recurrenceRule: item.recurrence?.isEmpty == false
                      ? item.recurrence!.join(' ')
                      : null,
                );
              }).whereType<ExternalEvent>(),
            );
          }
          pageToken = events.nextPageToken;
        } while (pageToken != null);
        return allEvents;
      } finally {
        tokenClient.close();
      }
    }

    await _init();
    if (!_isInitialized) return <ExternalEvent>[];
    try {
      await _loadGoogleTokenFromCache();

      http.Client? httpClient;
      if (!_isCachedTokenExpired()) {
        _activeClient?.close();
        _activeClient = _BearerClient(http.Client(), _cachedAccessToken!);
        httpClient = _activeClient;
      } else {
        httpClient = await _createAuthenticatedClient(
          allowInteractive: allowInteractive,
        );
      }
      if (httpClient == null) return [];

      final calendarApi = google_calendar.CalendarApi(httpClient);
      final allEvents = <ExternalEvent>[];
      String? pageToken;

      // Implement pagination to handle large event lists
      do {
        final events = await calendarApi.events.list(
          calendarId,
          timeMin: start.toUtc(),
          timeMax: end.toUtc(),
          singleEvents: true,
          orderBy: 'startTime',
          showDeleted: false,
          eventTypes: ['default'],
          maxResults: await (() async {
            try {
              return await appConfigService.getInt(
                'calendar.google_max_results',
                defaultValue: 250,
              );
            } catch (e) {
              return 250;
            }
          })(),
          pageToken: pageToken,
        );

        if (events.items != null) {
          allEvents.addAll(
            events.items!.map((item) {
              final startDt = item.start?.dateTime ?? item.start?.date;
              final endDt = item.end?.dateTime ?? item.end?.date;
              final isAllDay = item.start?.date != null;

              DateTime? normalizeDate(DateTime? dt) {
                if (dt == null) return null;
                if (isAllDay) return DateTime(dt.year, dt.month, dt.day);
                return dt.isUtc ? dt.toLocal() : dt;
              }

              final id = item.id?.trim();
              if (id == null || id.isEmpty) {
                return null;
              }

              return ExternalEvent(
                calendarId: calendarId,
                id: id,
                title: item.summary?.trim().isNotEmpty == true
                    ? item.summary!.trim()
                    : 'No Title',
                start: normalizeDate(startDt),
                end: normalizeDate(endDt),
                description: item.description,
                isAllDay: isAllDay,
                location: item.location,
                url: item.htmlLink != null
                    ? Uri.tryParse(item.htmlLink!)
                    : null,
                organizer: item.organizer?.email,
                transparency: item.transparency,
                visibility: item.visibility,
                attendeeCount: item.attendees?.isEmpty == false
                    ? item.attendees!.length
                    : null,
                recurrenceRule: item.recurrence?.isEmpty == false
                    ? item.recurrence!.join(' ')
                    : null,
              );
            }).whereType<ExternalEvent>(),
          );
        }

        pageToken = events.nextPageToken;
      } while (pageToken != null);

      return allEvents;
    } on http.ClientException catch (_) {
      throw Exception('Network error. Please check your internet connection.');
    } catch (e) {
      if (_looksLikeAuthError(e)) {
        await _invalidateGoogleAuth();
        if (allowInteractive) {
          try {
            final httpClient = await _createAuthenticatedClient(
              allowInteractive: true,
            );
            if (httpClient == null) return [];

            final calendarApi = google_calendar.CalendarApi(httpClient);
            final allEvents = <ExternalEvent>[];
            String? pageToken;

            do {
              final events = await calendarApi.events.list(
                calendarId,
                timeMin: start.toUtc(),
                timeMax: end.toUtc(),
                singleEvents: true,
                orderBy: 'startTime',
                showDeleted: false,
                eventTypes: ['default'],
                maxResults: await (() async {
                  try {
                    return await appConfigService.getInt(
                      'calendar.google_max_results',
                      defaultValue: 250,
                    );
                  } catch (e) {
                    return 250;
                  }
                })(),
                pageToken: pageToken,
              );

              if (events.items != null) {
                allEvents.addAll(
                  events.items!.map((item) {
                    final startDt = item.start?.dateTime ?? item.start?.date;
                    final endDt = item.end?.dateTime ?? item.end?.date;
                    final isAllDay = item.start?.date != null;

                    DateTime? normalizeDate(DateTime? dt) {
                      if (dt == null) return null;
                      if (isAllDay) return DateTime(dt.year, dt.month, dt.day);
                      return dt.isUtc ? dt.toLocal() : dt;
                    }

                    final id = item.id?.trim();
                    if (id == null || id.isEmpty) {
                      return null;
                    }

                    return ExternalEvent(
                      calendarId: calendarId,
                      id: id,
                      title: item.summary?.trim().isNotEmpty == true
                          ? item.summary!.trim()
                          : 'No Title',
                      start: normalizeDate(startDt),
                      end: normalizeDate(endDt),
                      description: item.description,
                      isAllDay: isAllDay,
                      location: item.location,
                      url: item.htmlLink != null
                          ? Uri.tryParse(item.htmlLink!)
                          : null,
                      organizer: item.organizer?.email,
                      transparency: item.transparency,
                      visibility: item.visibility,
                      attendeeCount: item.attendees?.isEmpty == false
                          ? item.attendees!.length
                          : null,
                      recurrenceRule: item.recurrence?.isEmpty == false
                          ? item.recurrence!.join(' ')
                          : null,
                    );
                  }).whereType<ExternalEvent>(),
                );
              }

              pageToken = events.nextPageToken;
            } while (pageToken != null);

            return allEvents;
          } catch (_) {}
        }
        throw Exception('Authentication expired. Please sign in again.');
      }
      return [];
    }
  }
}

class _BearerClient extends http.BaseClient {
  final http.Client _inner;
  final String _accessToken;

  _BearerClient(this._inner, this._accessToken);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_accessToken';
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
