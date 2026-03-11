import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/calendar/v3.dart' as google_calendar;
import 'package:http/http.dart' as http;
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
  });
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
    if (_isInitialized || _isInitializing || !kIsWeb) return;
    _isInitializing = true;
    try {
      final envClientId = const String.fromEnvironment(
        'GOOGLE_CLIENT_ID',
        defaultValue: '',
      ).trim();
      final dotEnvClientId = (dotenv.env['GOOGLE_CLIENT_ID'] ?? '').trim();
      final clientId = envClientId.isNotEmpty ? envClientId : dotEnvClientId;

      if (clientId.isEmpty) {
        return;
      }

      await _googleSignIn.initialize(clientId: clientId);
      _googleSignIn.authenticationEvents.listen((event) {
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
      }).onError((e, st) {
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
      await prefs.setString(_googleAccessTokenExpiryKey, expiry.toIso8601String());
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

  bool _looksLikeAuthError(Object e) {
    final text = e.toString();
    return text.contains('401') ||
        text.toLowerCase().contains('unauthorized') ||
        text.toLowerCase().contains('authentication');
  }

  Future<void> _invalidateGoogleAuth() async {
    _activeClient?.close();
    _activeClient = null;
    _cachedAccessToken = null;
    _cachedAccessTokenExpiry = null;
    _cachedUserEmail = null;
    await _clearGoogleTokenCache();
  }

  Future<http.Client?> _createAuthenticatedClient({bool allowInteractive = true}) async {
    try {
      if (_activeClient != null) return _activeClient;

      await _loadGoogleTokenFromCache();
      if (!_isCachedTokenExpired()) {
        _activeClient = _BearerClient(
          http.Client(),
          _cachedAccessToken!,
        );
        return _activeClient;
      }

      final authClient = _googleSignIn.authorizationClient;
      // Note: 'authorizeScopes' triggers a popup.
      // If you see "Cross-Origin-Opener-Policy policy would block the window.closed call" in the console,
      // it is a known browser security warning when COOP headers are missing. It typically doesn't break the flow.
      final existingAuthorization = await authClient.authorizationForScopes(_scopes);
      final authorization =
          existingAuthorization ??
          (allowInteractive ? await authClient.authorizeScopes(_scopes) : null);
      if (authorization == null) return null;

      // Use the extension to create an authenticated client directly
      // This handles the 'Bearer' token and headers automatically
      _activeClient = authorization.authClient(scopes: _scopes);
      await _tryCacheAuthorization(authorization);
      return _activeClient;
    } catch (e) {
      return null;
    }
  }

  Stream<GoogleSignInAccount?> get onCurrentUserChanged =>
      _userController.stream;
  GoogleSignInAccount? get currentUser => _currentUser;

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
      final emailForLabel =
          (googleUser?.email.trim().isNotEmpty == true
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
        await _invalidateGoogleAuth();
        if (allowInteractive) {
          try {
            final httpClient = await _createAuthenticatedClient(allowInteractive: true);
            if (httpClient == null) {
              throw Exception('Authentication expired. Please sign in again.');
            }
            final calendarApi = google_calendar.CalendarApi(httpClient);
            final calendarList = await calendarApi.calendarList.list();
            return (calendarList.items ??
                    const <google_calendar.CalendarListEntry>[])
                .map((item) {
                  final id = item.id?.trim();
                  if (id == null || id.isEmpty) return null;
                  final label =
                      (_cachedUserEmail?.trim().isNotEmpty == true ? _cachedUserEmail! : 'google');
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
          } catch (_) {}
        }
        throw Exception('Authentication expired. Please sign in again.');
      }
      throw Exception('Failed to fetch Google Calendars. Please try again.');
    }
  }

  Future<List<ExternalEvent>> retrieveGoogleEvents(
    String calendarId,
    DateTime start,
    DateTime end,
    {bool allowInteractive = true, String? accessTokenOverride}
  ) async {
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
            maxResults: 250,
            pageToken: pageToken,
          );

          if (events.items != null) {
            allEvents.addAll(
              events.items!
                  .map((item) {
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
                );
              })
                  .whereType<ExternalEvent>(),
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
        httpClient = await _createAuthenticatedClient(allowInteractive: allowInteractive);
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
          maxResults: 250, // Google's max per page
          pageToken: pageToken,
        );

        if (events.items != null) {
          allEvents.addAll(
            events.items!
                .map((item) {
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
                url: item.htmlLink != null ? Uri.tryParse(item.htmlLink!) : null,
                organizer: item.organizer?.email,
              );
            })
                .whereType<ExternalEvent>(),
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
            final httpClient = await _createAuthenticatedClient(allowInteractive: true);
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
                maxResults: 250,
                pageToken: pageToken,
              );

              if (events.items != null) {
                allEvents.addAll(
                  events.items!
                      .map((item) {
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
                      url: item.htmlLink != null ? Uri.tryParse(item.htmlLink!) : null,
                      organizer: item.organizer?.email,
                    );
                  })
                      .whereType<ExternalEvent>(),
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
