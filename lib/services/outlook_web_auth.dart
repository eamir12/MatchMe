// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

// lib/services/outlook_web_auth.dart
import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

// Direct constructor access for MSAL PublicClientApplication
@JS('msal.PublicClientApplication')
@staticInterop
class MSALPublicClientApplication {
  external factory MSALPublicClientApplication(JSObject config);
}

extension MSALPublicClientApplicationExtension on MSALPublicClientApplication {
  external JSPromise loginPopup(JSAny request);
  external JSPromise loginRedirect(JSAny request);
  external JSPromise handleRedirectPromise();
  external JSPromise acquireTokenSilent(JSAny request);
  external JSPromise acquireTokenPopup(JSAny request);
  external JSArray getAllAccounts(); // Synchronous method!
  external JSPromise logoutPopup(JSAny request);
  external JSPromise initialize();
}

// Authentication result
@JS()
@staticInterop
class MSALAuthResult {}

extension MSALAuthResultExtension on MSALAuthResult {
  external String? get accessToken;
  external JSArray? get scopes;
  external bool? get fromCache;
}

@JS()
@staticInterop
class MSALAccount {}

extension MSALAccountExtension on MSALAccount {
  external String? get username;
  external String? get name;
}

class OutlookWebAccount {
  final String username;
  final String? name;

  const OutlookWebAccount({required this.username, this.name});
}

// PublicClientApplication dart wrapper
class PublicClientApplication {
  final MSALPublicClientApplication _instance;

  PublicClientApplication(this._instance);

  Future<void> initialize() async {
    try {
      print('🔄 [MSAL] Attempting to call initialize() on MSAL instance...');
      final promise = _instance.initialize();
      print(
        '🔄 [MSAL] Promise returned from initialize(), converting to Dart Future...',
      );
      await promise.toDart;
      print('✅ [MSAL] initialize() completed successfully');
    } catch (e, stack) {
      print('❌ [MSAL] Error during initialize(): $e');
      print('Stack: $stack');
      // Don't rethrow - initialize() might not be required in all MSAL versions
      // Continue without it and see if other methods work
    }
  }

  Future<MSALAuthResult> loginPopup(JSObject request) async {
    final promise = _instance.loginPopup(request);
    return (await promise.toDart) as MSALAuthResult;
  }

  Future<void> loginRedirect(JSObject request) async {
    final promise = _instance.loginRedirect(request);
    await promise.toDart;
  }

  Future<MSALAuthResult?> handleRedirectPromise() async {
    final promise = _instance.handleRedirectPromise();
    final result = await promise.toDart;
    return result?.isUndefinedOrNull == false ? result as MSALAuthResult : null;
  }

  Future<MSALAuthResult> acquireTokenSilent(JSObject request) async {
    final promise = _instance.acquireTokenSilent(request);
    return (await promise.toDart) as MSALAuthResult;
  }

  Future<MSALAuthResult> acquireTokenPopup(JSObject request) async {
    final promise = _instance.acquireTokenPopup(request);
    return (await promise.toDart) as MSALAuthResult;
  }

  JSArray getAllAccounts() {
    return _instance.getAllAccounts(); // Synchronous!
  }

  Future<void> logoutPopup(JSObject request) async {
    final promise = _instance.logoutPopup(request);
    await promise.toDart;
  }
}

class OutlookWebAuth {
  static OutlookWebAuth? _instance;
  static OutlookWebAuth get instance => _instance ??= OutlookWebAuth._();

  OutlookWebAuth._();

  PublicClientApplication? _msalInstance;
  bool _isInitialized = false;

  /// Check if MSAL is initialized (for external checking)
  bool get isInitialized => _isInitialized;

  Future<void> reset() async {
    _msalInstance = null;
    _isInitialized = false;
  }

  Future<void> initialize({
    required String clientId,
    required String tenantId,
    required String redirectUri,
  }) async {
    if (_isInitialized) return;

    try {
      print('✅ MSAL library loaded, creating instance...');

      // Create MSAL configuration
      final config =
          {
                'auth': {
                  'clientId': clientId,
                  'authority': 'https://login.microsoftonline.com/$tenantId',
                  'redirectUri': redirectUri,
                },
                'cache': {
                  'cacheLocation': 'localStorage',
                  'storeAuthStateInCookie': false,
                },
                'system': {
                  'allowNativeBroker': false,
                  'windowHashTimeout': 60000,
                  'iframeHashTimeout': 6000,
                  'loadFrameTimeout': 0,
                },
              }.jsify()
              as JSObject;

      // Create MSAL instance using factory constructor
      print('🔄 Creating MSAL instance...');
      final instance = MSALPublicClientApplication(config);
      print('✅ MSAL instance created');
      _msalInstance = PublicClientApplication(instance);

      // CRITICAL: MSAL v3+ requires calling initialize() before use
      print('🔄 Calling MSAL initialize...');
      await _msalInstance!.initialize();
      print('✅ MSAL initialized');

      _isInitialized = true;
      print('✅ Outlook Web Auth initialized successfully');
    } catch (e, stackTrace) {
      print('❌ Failed to initialize Outlook Web Auth: $e');
      print('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Signs in through MSAL in the browser.
  ///
  /// [forceAccountSelection] asks Microsoft for its account picker, so the
  /// user can pick an account other than the one already signed into the
  /// browser. [forceConsent] instead asks for the consent screen again.
  /// Account selection wins when both are requested.
  Future<String?> signIn({
    List<String>? scopes,
    bool useRedirect = false,
    bool forceConsent = false,
    bool forceAccountSelection = false,
    String? loginHint,
  }) async {
    if (!_isInitialized || _msalInstance == null) {
      throw Exception(
        'OutlookWebAuth not initialized. Call initialize() first.',
      );
    }

    try {
      final loginRequest =
          {
                'scopes':
                    scopes ?? ['User.Read', 'Calendars.Read', 'offline_access'],
                'prompt': forceConsent && !forceAccountSelection
                    ? 'consent'
                    : 'select_account',
                if (loginHint != null && loginHint.trim().isNotEmpty)
                  'loginHint': loginHint.trim(),
              }.jsify()
              as JSObject;

      if (useRedirect) {
        // Use redirect flow
        print('🔄 Starting Outlook login redirect...');
        await _msalInstance!.loginRedirect(loginRequest);
        // Note: This will redirect away from the app, return handled in handleRedirectPromise
        return null;
      } else {
        // Use popup flow
        print('🔄 Starting Outlook login popup...');
        final result = await _msalInstance!.loginPopup(loginRequest);
        final accessToken = result.accessToken;

        if (accessToken != null) {
          print('✅ Outlook sign-in successful');
          print('Token scopes: ${result.scopes?.toDart}');
          print('Token from cache: ${result.fromCache}');
          return accessToken;
        } else {
          print('❌ No access token received from Outlook sign-in');
          return null;
        }
      }
    } catch (e) {
      print('❌ Outlook sign-in error: $e');
      rethrow;
    }
  }

  Future<String?> getAccessToken({
    List<String>? scopes,
    bool forceRefresh = false,
  }) async {
    if (!_isInitialized || _msalInstance == null) {
      throw Exception(
        'OutlookWebAuth not initialized. Call initialize() first.',
      );
    }

    try {
      // Get all accounts (synchronous method)
      final accounts = _msalInstance!.getAllAccounts();

      if (accounts.toDart.isEmpty) {
        print('No accounts found, need to sign in first');
        return null;
      }

      // Use first account
      final account = accounts.toDart.first;

      final tokenRequest =
          {
                'scopes':
                    scopes ?? ['User.Read', 'Calendars.Read', 'offline_access'],
                'account': account,
                'forceRefresh': forceRefresh,
              }.jsify()
              as JSObject;

      if (!forceRefresh) {
        // Try silent token acquisition first
        try {
          final silentResult = await _msalInstance!.acquireTokenSilent(
            tokenRequest,
          );
          final accessToken = silentResult.accessToken;

          if (accessToken != null) {
            print('✅ Got Outlook token silently');
            return accessToken;
          }
        } catch (e) {
          print(
            'Silent token acquisition failed: $e, falling back to interactive',
          );
        }
      }

      // If silent fails, use popup
      final popupResult = await _msalInstance!.acquireTokenPopup(tokenRequest);
      final accessToken = popupResult.accessToken;

      if (accessToken != null) {
        print('✅ Got Outlook token via popup');
        return accessToken;
      }

      return null;
    } catch (e) {
      print('❌ Error getting Outlook access token: $e');
      return null;
    }
  }

  List<OutlookWebAccount> listAccounts() {
    if (!_isInitialized || _msalInstance == null) {
      return const <OutlookWebAccount>[];
    }

    final accounts = _msalInstance!.getAllAccounts().toDart;
    final results = <OutlookWebAccount>[];
    for (final account in accounts) {
      final jsAccount = account as MSALAccount;
      final username = jsAccount.username?.trim();
      if (username == null || username.isEmpty) {
        continue;
      }
      results.add(
        OutlookWebAccount(username: username, name: jsAccount.name?.trim()),
      );
    }
    return results;
  }

  Future<String?> getAccessTokenForUsername({
    required String username,
    List<String>? scopes,
    bool forceRefresh = false,
  }) async {
    if (!_isInitialized || _msalInstance == null) {
      throw Exception(
        'OutlookWebAuth not initialized. Call initialize() first.',
      );
    }

    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty) {
      return null;
    }

    try {
      final accounts = _msalInstance!.getAllAccounts().toDart;
      Object? selectedAccount;
      for (final account in accounts) {
        final jsAccount = account as MSALAccount;
        final accountUsername = jsAccount.username?.trim().toLowerCase();
        if (accountUsername == normalizedUsername) {
          selectedAccount = account;
          break;
        }
      }

      if (selectedAccount == null) {
        return null;
      }

      final tokenRequest =
          {
                'scopes':
                    scopes ?? ['User.Read', 'Calendars.Read', 'offline_access'],
                'account': selectedAccount,
                'forceRefresh': forceRefresh,
              }.jsify()
              as JSObject;

      if (!forceRefresh) {
        try {
          final silentResult = await _msalInstance!.acquireTokenSilent(
            tokenRequest,
          );
          final silentAccessToken = silentResult.accessToken;
          if (silentAccessToken != null) {
            return silentAccessToken;
          }
        } catch (_) {}
      }

      final popupResult = await _msalInstance!.acquireTokenPopup(tokenRequest);
      return popupResult.accessToken;
    } catch (e) {
      print('❌ Error getting Outlook access token: $e');
      return null;
    }
  }

  /// Call this on app startup to handle redirect callback
  Future<String?> handleRedirectCallback() async {
    if (!_isInitialized || _msalInstance == null) {
      print('⚠️ Cannot handle redirect - not initialized');
      return null;
    }

    try {
      // Log current URL to debug
      if (kIsWeb) {
        final currentUrl = web.window.location.href;
        final hasCode = currentUrl.contains('code=');
        final hasState = currentUrl.contains('state=');
        print('🔍 Current URL has code: $hasCode, has state: $hasState');
        if (hasCode) {
          print('🔍 URL contains OAuth redirect parameters');
        }
      }

      print('🔄 Calling MSAL handleRedirectPromise...');
      final result = await _msalInstance!.handleRedirectPromise();

      if (result != null) {
        print('✅ Redirect callback handled successfully');
        final accessToken = result.accessToken;
        if (accessToken != null) {
          return accessToken;
        }
      } else {
        print(
          'ℹ️ No redirect callback pending (handleRedirectPromise returned null)',
        );
      }
      return null;
    } catch (e, st) {
      print('❌ Error handling redirect: $e');
      print('Stack: $st');
      return null;
    }
  }

  Future<void> signOut() async {
    if (!_isInitialized || _msalInstance == null) return;

    try {
      // Get all accounts (synchronous method)
      final accounts = _msalInstance!.getAllAccounts();

      if (accounts.toDart.isNotEmpty) {
        final account = accounts.toDart.first;
        final logoutRequest = {'account': account}.jsify() as JSObject;

        await _msalInstance!.logoutPopup(logoutRequest);
        print('✅ Outlook sign-out successful');
      }
    } catch (e) {
      print('❌ Outlook sign-out error: $e');
    }
  }
}
