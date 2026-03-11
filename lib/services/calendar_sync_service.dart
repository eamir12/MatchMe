import 'dart:convert';
import 'dart:async';

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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/outlook_web_auth.dart' if (dart.library.io) 'package:matchme/services/outlook_web_auth_stub.dart';
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
  static const String _outlookTokenKey = 'outlook_access_token';
  static const String _outlookTokenExpiryKey = 'outlook_token_expiry';

  CalendarSyncService();

  WebCalendarService get webService => _webService;

  bool _hasAuthProvider(User? user, String provider) {
    final p = provider.toLowerCase().trim();
    final meta = user?.appMetadata;
    final direct = meta?['provider']?.toString().toLowerCase().trim();
    if (direct == p) return true;
    final providers = meta?['providers'];
    if (providers is List) {
      for (final item in providers) {
        if (item.toString().toLowerCase().trim() == p) return true;
      }
    }
    return false;
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
          final packages = await platform.invokeMethod<List<Object?>>('findOutlookPackages');
          if (packages != null && packages.isNotEmpty) {
            final packageList = packages.cast<String>();
            
            // Filter to only Outlook-specific packages
            final outlookPackages = packageList.where((pkg) => 
              pkg.toLowerCase().contains('outlook')
            ).toList();
            
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
          } else {
          }
        } catch (_) {
          await Future<void>.value();
        }
        
        // Fallback: Try known package names
        final possiblePackages = [
          'com.microsoft.office.outlook',  // Main Outlook app
          'com.microsoft.outlook',         // Alternative package name
          'com.outlook.Z7',                // Old Outlook package
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

  Config _buildOutlookConfig() {
    var tenant =
        const String.fromEnvironment('OUTLOOK_TENANT_ID', defaultValue: '').trim();
    var clientId =
        const String.fromEnvironment('OUTLOOK_CLIENT_ID', defaultValue: '').trim();
    var redirectUri =
        const String.fromEnvironment('OUTLOOK_REDIRECT_URI', defaultValue: '').trim();

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

    return Config(
      tenant: tenant,
      clientId: clientId,
      scope:
          'https://graph.microsoft.com/User.Read https://graph.microsoft.com/Calendars.Read offline_access',
      redirectUri: redirectUri,
      navigatorKey: navigatorKey,
      webUseRedirect: false,
    );
  }

  Future<void> _ensureOutlookOAuth({bool allowNonWeb = false}) async {
    if (kIsWeb) {
      // Initialize web-specific Outlook auth using MSAL.js
      if (!OutlookWebAuth.instance.isInitialized) {
        final config = _buildOutlookConfig();
        await OutlookWebAuth.instance.initialize(
          clientId: config.clientId,
          tenantId: config.tenant,
          redirectUri: config.redirectUri,
        );
        
        // Handle any pending redirect callback from OAuth
        await OutlookWebAuth.instance.handleRedirectCallback();
      }
    } else {
      // Mobile platforms use aad_oauth
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
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: st),
      );
    }
  }

  Future<void> _saveOutlookTokenToCache(String token, DateTime expiry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outlookTokenKey, token);
      await prefs.setString(_outlookTokenExpiryKey, expiry.toIso8601String());
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: st),
      );
    }
  }

  Future<void> _clearOutlookTokenCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_outlookTokenKey);
      await prefs.remove(_outlookTokenExpiryKey);
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: st),
      );
    }
  }

  bool _isOutlookTokenExpired() {
    if (_outlookTokenExpiry == null) return true;
    // Consider token expired 5 minutes before actual expiry (using default, async load not practical here)
    const bufferMinutes = 5; // Default from config: calendar.token_refresh_buffer_minutes
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
        forceConsent: kIsWeb,
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
        // Use web-specific Outlook auth with MSAL.js
        final token = await OutlookWebAuth.instance.signIn(
          scopes: [
            'User.Read',
            'Calendars.Read',
            'offline_access',
          ],
          useRedirect: false,
          forceConsent: forceConsent,
        );
        
        if (token != null) {
          _outlookAccessToken = token;
          // Assume token expires in 1 hour (typical for Microsoft)
          _outlookTokenExpiry = DateTime.now().add(const Duration(hours: 1));
          await _saveOutlookTokenToCache(_outlookAccessToken!, _outlookTokenExpiry!);
          return token;
        }
        return null;
      } else {
        // Use mobile aad_oauth
        final result = await _outlookOAuth!.login();
        return result.fold(
          (l) {
            return null;
          },
          (r) {
            _outlookAccessToken = r.accessToken;
            // Assume token expires in 1 hour (typical for Microsoft)
            _outlookTokenExpiry = DateTime.now().add(const Duration(hours: 1));
            _saveOutlookTokenToCache(_outlookAccessToken!, _outlookTokenExpiry!);
            return r.accessToken;
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

  Future<String?> signInOutlook({
    bool allowNonWeb = false,
    bool forceConsent = false,
  }) {
    return _signInOutlook(
      allowNonWeb: allowNonWeb,
      forceConsent: forceConsent,
    );
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
          ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
              .toLocal()
          : DateTime.now().add(const Duration(minutes: 55));
      _outlookAccessToken = providerToken;
      _outlookTokenExpiry = expiry;
      await _saveOutlookTokenToCache(providerToken, expiry);
      return _outlookAccessToken;
    }

    // Token expired or missing, try to get it silently (web) or refresh (mobile)
    if (kIsWeb) {
      await _ensureOutlookOAuth();
      try {
        final token = await OutlookWebAuth.instance.getAccessToken(
          scopes: [
            'User.Read',
            'Calendars.Read',
            'offline_access',
          ],
          forceRefresh: true,
        );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = DateTime.now().add(const Duration(hours: 1));
          await _saveOutlookTokenToCache(_outlookAccessToken!, _outlookTokenExpiry!);
          return token;
        }
      } catch (e) {
        final token = await OutlookWebAuth.instance.signIn(
            scopes: [
              'User.Read',
              'Calendars.Read',
              'offline_access',
            ],
            forceConsent: true,
          );
        if (token != null) {
          _outlookAccessToken = token;
          _outlookTokenExpiry = DateTime.now().add(const Duration(hours: 1));
          await _saveOutlookTokenToCache(_outlookAccessToken!, _outlookTokenExpiry!);
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
      if (status == CalendarPermissionStatus.granted) return true;

      if (status == CalendarPermissionStatus.notDetermined) {
        final newStatus = await _deviceCalendar.requestPermissions();
        if (newStatus != CalendarPermissionStatus.granted) {
          throw CalendarSyncException(
            'Calendar permissions denied',
            userMessage: 'calendarSyncPermissionDenied',
          );
        }
        return true;
      }
      throw CalendarSyncException(
        'Calendar permissions denied',
        userMessage: 'calendarSyncPermissionDenied',
      );
    } catch (e) {
      if (e is CalendarSyncException) rethrow;
      throw CalendarSyncException(
        'Permission request failed: $e',
        userMessage: 'calendarSyncPermissionFailed',
      );
    }
  }

  Future<List<ExternalCalendar>> retrieveCalendars() async {
    if (kIsWeb) {
      final session = Supabase.instance.client.auth.currentSession;
      final user = Supabase.instance.client.auth.currentUser;
      final token = session?.providerToken;
      if (token != null &&
          token.isNotEmpty &&
          _hasAuthProvider(user, 'google')) {
        final exp = session?.expiresAt;
        final expiry = exp != null
            ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
                .toLocal()
            : DateTime.now().add(const Duration(minutes: 55));
        await _webService.seedGoogleAccessToken(
          accessToken: token,
          expiry: expiry,
          userEmail: user?.email,
        );
        return await _webService.retrieveGoogleCalendars(
          accessTokenOverride: token,
          accountLabelOverride: user?.email,
        );
      }
      return await _webService.retrieveGoogleCalendars();
    }
    try {
      final initialPermissions = await _deviceCalendar.hasPermissions();
      final permissionsWereMissing =
          initialPermissions != CalendarPermissionStatus.granted;

      final permissionsGranted = await requestPermissions();
      if (!permissionsGranted) return <ExternalCalendar>[];

      // If we just requested permissions, add a small delay to allow OS to propagate changes
      if (permissionsWereMissing) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      var calendars = await _deviceCalendar.listCalendars();

      if (calendars.isEmpty && permissionsWereMissing) {
        await Future.delayed(const Duration(milliseconds: 500));
        calendars = await _deviceCalendar.listCalendars();
      }

      return calendars
          .where((c) => c.id.trim().isNotEmpty)
          .map((c) {
            return ExternalCalendar(
              id: c.id.trim(),
              name: c.name.trim().isNotEmpty ? c.name.trim() : 'Calendar',
              isReadOnly: c.readOnly,
              isDefault: c.isPrimary,
              accountName: c.accountName,
              accountType: c.accountType,
            );
          })
          .toList();
    } catch (e) {
      return <ExternalCalendar>[];
    }
  }

  Future<List<ExternalEvent>> retrieveEvents(
    String calendarId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final start = startDate ?? DateTime.now();
    final end = endDate ?? DateTime.now().add(const Duration(days: 30));

    if (kIsWeb) {
      final session = Supabase.instance.client.auth.currentSession;
      final user = Supabase.instance.client.auth.currentUser;
      final token = session?.providerToken;
      if (token != null &&
          token.isNotEmpty &&
          _hasAuthProvider(user, 'google')) {
        final exp = session?.expiresAt;
        final expiry = exp != null
            ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
                .toLocal()
            : DateTime.now().add(const Duration(minutes: 55));
        await _webService.seedGoogleAccessToken(
          accessToken: token,
          expiry: expiry,
          userEmail: user?.email,
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

      return events
          .where((e) => e.instanceId.trim().isNotEmpty)
          .map((e) {
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
          })
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<List<ExternalCalendar>> retrieveOutlookCalendars({bool allowNonWeb = false}) async {
    if (!kIsWeb && !allowNonWeb) {
      throw CalendarSyncException(
        'Outlook OAuth is only available on web platform. Use device calendars on mobile.',
        userMessage: 'calendarSyncOutlookWebOnly',
      );
    }
    
    final token = await _getValidOutlookToken(allowNonWeb: allowNonWeb);
    if (token == null) {
      throw CalendarSyncException(
        'Outlook authentication failed',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    try {
      final response = await http
          .get(
            Uri.parse('https://graph.microsoft.com/v1.0/me/calendars'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(Duration(seconds: await appConfigService.getInt(
            'calendar.api_timeout_seconds',
            defaultValue: 30
          )));

      if (response.statusCode == 401) {
        // Token expired, try refresh
        final newToken = await _refreshOutlookToken(allowNonWeb: allowNonWeb);
        if (newToken == null) {
          throw CalendarSyncException(
            'Outlook authentication expired',
            userMessage: 'calendarSyncOutlookExpired',
            isAuthError: true,
          );
        }
        // Retry with new token
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

      return items.map((item) {
        final map = item as Map<String, dynamic>;
        final owner = map['owner'] as Map<String, dynamic>?;
        final ownerAddress = owner != null ? owner['address'] as String? : null;

        final id = (map['id'] as String?)?.trim();
        return ExternalCalendar(
          id: id?.isNotEmpty == true ? id! : 'outlook',
          name: (map['name'] as String?)?.trim().isNotEmpty == true
              ? (map['name'] as String).trim()
              : 'Outlook Calendar',
          isReadOnly: !(map['canEdit'] == true),
          isDefault: map['isDefaultCalendar'] == true,
          accountName: ownerAddress ?? 'Outlook',
          accountType: 'com.microsoft.outlook',
        );
      }).toList();
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
      throw CalendarSyncException(
        'Outlook authentication failed',
        userMessage: 'calendarSyncOutlookSignIn',
        isAuthError: true,
      );
    }

    final start = (startDate ?? DateTime.now()).toUtc();
    final end =
        (endDate ?? DateTime.now().add(const Duration(days: 30))).toUtc();

    final startIso = start.toIso8601String();
    final endIso = end.toIso8601String();

    try {
      final allEvents = <ExternalEvent>[];
      String? skipToken;

      // Implement pagination for Outlook events
      do {
        final baseUrl =
            'https://graph.microsoft.com/v1.0/me/calendars/$calendarId/calendarView?startDateTime=$startIso&endDateTime=$endIso&\$orderby=start/dateTime&\$top=250';
        final url =
            skipToken != null ? '$baseUrl&\$skiptoken=$skipToken' : baseUrl;

        final response = await http
            .get(
              Uri.parse(url),
              headers: {
                'Authorization': 'Bearer $token',
                'Accept': 'application/json',
              },
            )
            .timeout(Duration(seconds: await appConfigService.getInt(
              'calendar.api_timeout_seconds',
              defaultValue: 30
            )));

        if (response.statusCode == 401) {
          // Token expired, try refresh
          final newToken = await _refreshOutlookToken(allowNonWeb: allowNonWeb);
          if (newToken == null) {
            throw CalendarSyncException(
              'Outlook authentication expired',
              userMessage: 'calendarSyncOutlookExpired',
              isAuthError: true,
            );
          }
          // Retry with new token
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
              location: (map['location'] as Map<String, dynamic>?)?['displayName']
                  as String?,
              url: null,
              organizer: null,
            );
          }).whereType<ExternalEvent>(),
        );

        // Check for next page
        skipToken =
            data['@odata.nextLink'] != null
                ? Uri.parse(
                  data['@odata.nextLink'] as String,
                ).queryParameters['\$skiptoken']
                : null;
      } while (skipToken != null);

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
