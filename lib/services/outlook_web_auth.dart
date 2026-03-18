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

// PublicClientApplication dart wrapper
class PublicClientApplication {
  final MSALPublicClientApplication _instance;
  
  PublicClientApplication(this._instance);
  
  Future<void> initialize() async {
    try {
      debugPrint('🔄 [MSAL] Attempting to call initialize() on MSAL instance...');
      final promise = _instance.initialize();
      debugPrint('🔄 [MSAL] Promise returned from initialize(), converting to Dart Future...');
      await promise.toDart;
      debugPrint('✅ [MSAL] initialize() completed successfully');
    } catch (e, stack) {
      debugPrint('❌ [MSAL] Error during initialize(): $e');
      debugPrint('Stack: $stack');
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
      debugPrint('✅ MSAL library loaded, creating instance...');

      // Create MSAL configuration
      final config = {
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
      }.jsify() as JSObject;

      // Create MSAL instance using factory constructor
      debugPrint('🔄 Creating MSAL instance...');
      final instance = MSALPublicClientApplication(config);
      debugPrint('✅ MSAL instance created');
      _msalInstance = PublicClientApplication(instance);

      // CRITICAL: MSAL v3+ requires calling initialize() before use
      debugPrint('🔄 Calling MSAL initialize...');
      await _msalInstance!.initialize();
      debugPrint('✅ MSAL initialized');

      _isInitialized = true;
      debugPrint('✅ Outlook Web Auth initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('❌ Failed to initialize Outlook Web Auth: $e');
      debugPrint('Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<String?> signIn({
    List<String>? scopes,
    bool useRedirect = false,
    bool forceConsent = false,
  }) async {
    if (!_isInitialized || _msalInstance == null) {
      throw Exception('OutlookWebAuth not initialized. Call initialize() first.');
    }

    try {
      final loginRequest = {
        'scopes': scopes ?? [
          'User.Read',
          'Calendars.Read',
          'offline_access',
        ],
        'prompt': forceConsent ? 'consent' : 'select_account',
      }.jsify() as JSObject;

      if (useRedirect) {
        // Use redirect flow
        debugPrint('🔄 Starting Outlook login redirect...');
        await _msalInstance!.loginRedirect(loginRequest);
        // Note: This will redirect away from the app, return handled in handleRedirectPromise
        return null;
      } else {
        // Use popup flow
        debugPrint('🔄 Starting Outlook login popup...');
        final result = await _msalInstance!.loginPopup(loginRequest);
        final accessToken = result.accessToken;

        if (accessToken != null) {
          debugPrint('✅ Outlook sign-in successful');
          debugPrint('Token scopes: ${result.scopes?.toDart}');
          debugPrint('Token from cache: ${result.fromCache}');
          return accessToken;
        } else {
          debugPrint('❌ No access token received from Outlook sign-in');
          return null;
        }
      }
    } catch (e) {
      debugPrint('❌ Outlook sign-in error: $e');
      rethrow;
    }
  }

  Future<String?> getAccessToken({List<String>? scopes, bool forceRefresh = false}) async {
    if (!_isInitialized || _msalInstance == null) {
      throw Exception('OutlookWebAuth not initialized. Call initialize() first.');
    }

    try {
      // Get all accounts (synchronous method)
      final accounts = _msalInstance!.getAllAccounts();

      if (accounts.toDart.isEmpty) {
        debugPrint('No accounts found, need to sign in first');
        return null;
      }

      // Use first account
      final account = accounts.toDart.first;

      final tokenRequest = {
        'scopes': scopes ?? [
          'User.Read',
          'Calendars.Read',
          'offline_access',
        ],
        'account': account,
        'forceRefresh': forceRefresh,
      }.jsify() as JSObject;

      if (!forceRefresh) {
        // Try silent token acquisition first
        try {
          final silentResult = await _msalInstance!.acquireTokenSilent(tokenRequest);
          final accessToken = silentResult.accessToken;

          if (accessToken != null) {
            debugPrint('✅ Got Outlook token silently');
            return accessToken;
          }
        } catch (e) {
          debugPrint('Silent token acquisition failed: $e, falling back to interactive');
        }
      }

      // If silent fails, use popup
      final popupResult = await _msalInstance!.acquireTokenPopup(tokenRequest);
      final accessToken = popupResult.accessToken;

      if (accessToken != null) {
        debugPrint('✅ Got Outlook token via popup');
        return accessToken;
      }

      return null;
    } catch (e) {
      debugPrint('❌ Error getting Outlook access token: $e');
      return null;
    }
  }

  /// Call this on app startup to handle redirect callback
  Future<String?> handleRedirectCallback() async {
    if (!_isInitialized || _msalInstance == null) {
      debugPrint('⚠️ Cannot handle redirect - not initialized');
      return null;
    }

    try {
      // Log current URL to debug
      if (kIsWeb) {
        final currentUrl = web.window.location.href;
        final hasCode = currentUrl.contains('code=');
        final hasState = currentUrl.contains('state=');
        debugPrint('🔍 Current URL has code: $hasCode, has state: $hasState');
        if (hasCode) {
          debugPrint('🔍 URL contains OAuth redirect parameters');
        }
      }
      
      debugPrint('🔄 Calling MSAL handleRedirectPromise...');
      final result = await _msalInstance!.handleRedirectPromise();
      
      if (result != null) {
        debugPrint('✅ Redirect callback handled successfully');
        final accessToken = result.accessToken;
        if (accessToken != null) {
          return accessToken;
        }
      } else {
        debugPrint('ℹ️ No redirect callback pending (handleRedirectPromise returned null)');
      }
      return null;
    } catch (e, st) {
      debugPrint('❌ Error handling redirect: $e');
      debugPrint('Stack: $st');
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
        final logoutRequest = {
          'account': account,
        }.jsify() as JSObject;

        await _msalInstance!.logoutPopup(logoutRequest);
        debugPrint('✅ Outlook sign-out successful');
      }
    } catch (e) {
      debugPrint('❌ Outlook sign-out error: $e');
    }
  }
}

