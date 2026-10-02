import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/authenticator_app_launcher.dart';
import 'package:matchme/services/passkey_auth_service.dart';
import 'package:matchme/services/passkey_client_exception.dart';
import 'package:matchme/services/passkey_client_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/screens/settings/sensitive_action_verification.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/theme/app_button_styles.dart';

class SecurityCenterScreen extends ConsumerStatefulWidget {
  const SecurityCenterScreen({super.key});

  @override
  ConsumerState<SecurityCenterScreen> createState() =>
      _SecurityCenterScreenState();
}

void _logSecurityCenter(String message) {
  print(message);
}

class _SecurityCenterScreenState extends ConsumerState<SecurityCenterScreen>
    with WidgetsBindingObserver {
  static const Duration _mfaStatusTimeout = Duration(seconds: 8);
  static const String _securityCenterSnapshotKeyPrefix =
      'security_center_snapshot:';

  late Future<_MfaStatus> _mfaStatusFuture;
  late Future<String?> _currentAuthMethodFuture;
  late Future<PasskeyAvailabilityState> _passkeyEnrollmentStateFuture;
  late Future<bool> _userHasPasskeysFuture;
  Future<_MfaStatus>? _mfaStatusRequest;
  _MfaStatus _lastKnownMfaStatus = const _MfaStatus(
    hasVerifiedTotp: false,
    currentSessionVerified: false,
    primaryFactorId: null,
    recoveryCodesRemaining: 0,
  );
  StreamSubscription<AuthState>? _authSubscription;
  bool _isEnrollingPasskey = false;
  bool _isRevokingPasskeys = false;
  bool _hasAddedPasskeyThisSession = false;
  bool? _lastKnownOnlineState;
  OverlayEntry? _mfaProgressOverlay;
  _SecurityCenterSnapshot? _cachedSnapshot;
  int _securitySnapshotRequestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Hydrate cached snapshot immediately for fast UI display
    unawaited(_hydrateCachedSnapshot());
    // Then fetch fresh data in background and sync with cache
    _assignSecurityDataFutures();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) {
        switch (data.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.userUpdated:
          case AuthChangeEvent.mfaChallengeVerified:
            if (mounted) {
              _refreshMfaStatus();
              _refreshCurrentAuthMethod();
              _refreshPasskeyEnrollmentState();
            }
            break;
          default:
            break;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[SECURITY] Auth stream error: $error');
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshSecurityCenterData(forceRefreshMfa: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _hideMfaProgressOverlay();
    super.dispose();
  }

  void _showSnackBar(String message, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  void _showMfaProgressOverlay(LocalizationState l10n) {
    if (!mounted || _mfaProgressOverlay != null) return;
    final overlayState = Overlay.of(context, rootOverlay: true);

    _mfaProgressOverlay = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return Stack(
          children: [
            ModalBarrier(
              dismissible: false,
              color: Colors.black.withValues(alpha: 0.35),
            ),
            Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: theme.shadowColor.withValues(alpha: 0.18),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        l10n.getString('settingsMfaVerifySensitiveAction'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.getString('generalLoadingDots'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurface.withValues(alpha: 0.74),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(_mfaProgressOverlay!);
  }

  void _hideMfaProgressOverlay() {
    _mfaProgressOverlay?.remove();
    _mfaProgressOverlay = null;
  }

  void _refreshMfaStatus() {
    _refreshSecurityCenterData(forceRefreshMfa: true);
  }

  void _refreshPasskeyEnrollmentState() {
    _refreshSecurityCenterData();
  }

  void _refreshCurrentAuthMethod() {
    _refreshSecurityCenterData();
  }

  void _refreshSecurityCenterData({bool forceRefreshMfa = false}) {
    if (!mounted) {
      _assignSecurityDataFutures(forceRefreshMfa: forceRefreshMfa);
      return;
    }
    setState(() {
      _assignSecurityDataFutures(forceRefreshMfa: forceRefreshMfa);
    });
  }

  void _assignSecurityDataFutures({bool forceRefreshMfa = false}) {
    final mfaFuture = _loadMfaStatus(forceRefresh: forceRefreshMfa);
    final passkeyFuture = _loadPasskeyEnrollmentState();
    final authMethodFuture = _loadCurrentAuthMethod();
    final hasPasskeysFuture = _loadUserHasPasskeys();

    _mfaStatusFuture = mfaFuture;
    _passkeyEnrollmentStateFuture = passkeyFuture;
    _currentAuthMethodFuture = authMethodFuture;
    _userHasPasskeysFuture = hasPasskeysFuture;

    final requestVersion = ++_securitySnapshotRequestVersion;
    unawaited(
      _cacheResolvedSnapshot(
        requestVersion: requestVersion,
        mfaFuture: mfaFuture,
        passkeyFuture: passkeyFuture,
        authMethodFuture: authMethodFuture,
        hasPasskeysFuture: hasPasskeysFuture,
      ),
    );
  }

  String? _securityCenterSnapshotKey() {
    final userId = Supabase.instance.client.auth.currentUser?.id.trim();
    if (userId == null || userId.isEmpty) return null;
    return '$_securityCenterSnapshotKeyPrefix$userId';
  }

  Future<String?> _readCachedSnapshotJson(String key) async {
    try {
      final stored = await SecureStorageService.instance.read(key);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {}
    // Legacy plain SharedPreferences fallback.
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {}
    return null;
  }

  Future<void> _writeCachedSnapshotJson(String key, String value) async {
    try {
      await SecureStorageService.instance.write(key, value);
    } catch (_) {}
    // Remove legacy plain copy.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) await prefs.remove(key);
    } catch (_) {}
  }

  Future<void> _hydrateCachedSnapshot() async {
    try {
      final key = _securityCenterSnapshotKey();
      if (key == null || key.isEmpty) return;
      final raw = (await _readCachedSnapshotJson(key))?.trim();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final snapshot = _SecurityCenterSnapshot.fromJson(decoded);
      _lastKnownMfaStatus = snapshot.mfaStatus;
      if (!mounted) return;
      setState(() {
        _cachedSnapshot = snapshot;
      });
    } catch (error) {
      print('⚠️ [SecurityCenter] Failed to hydrate cached snapshot: $error');
    }
  }

  Future<void> _cacheResolvedSnapshot({
    required int requestVersion,
    required Future<_MfaStatus> mfaFuture,
    required Future<PasskeyAvailabilityState> passkeyFuture,
    required Future<String?> authMethodFuture,
    required Future<bool> hasPasskeysFuture,
  }) async {
    try {
      final results = await Future.wait<Object?>([
        mfaFuture,
        passkeyFuture,
        authMethodFuture,
        hasPasskeysFuture,
      ]);

      final snapshot = _SecurityCenterSnapshot(
        mfaStatus: results[0] as _MfaStatus,
        passkeyState: results[1] as PasskeyAvailabilityState,
        authMethod: results[2] as String?,
        hasPasskeys: results[3] as bool,
      );
      _lastKnownMfaStatus = snapshot.mfaStatus;

      final key = _securityCenterSnapshotKey();
      // Always save the resolved snapshot to cache when all futures complete successfully
      // This ensures we have the most recent data available for offline use
      if (key != null && key.isNotEmpty) {
        try {
          final oldJson = await _readCachedSnapshotJson(key);
          final newJson = jsonEncode(snapshot.toJson());

          // Check if data has changed
          if (oldJson != newJson) {
            await _writeCachedSnapshotJson(key, newJson);
            print(
              '✅ [SecurityCenter] Synced fresh data to local cache (data changed)',
            );
          } else {
            print(
              '✅ [SecurityCenter] Local cache already up-to-date with Supabase',
            );
          }
        } catch (cacheError) {
          print(
            '⚠️ [SecurityCenter] Failed to save snapshot to cache: $cacheError',
          );
        }
      }

      if (!mounted || requestVersion != _securitySnapshotRequestVersion) {
        return;
      }

      setState(() {
        _cachedSnapshot = snapshot;
      });
    } catch (error) {
      print('⚠️ [SecurityCenter] Failed to sync fresh data: $error');
    }
  }

  _MfaStatus _cachedMfaStatus() {
    final cachedStatus = _cachedSnapshot?.mfaStatus;
    final currentSessionVerified = _readAccessTokenClaim('aal') == 'aal2';
    if (cachedStatus != null) {
      return cachedStatus.copyWith(
        currentSessionVerified: currentSessionVerified,
      );
    }
    return _fallbackMfaStatus();
  }

  PasskeyAvailabilityState _cachedPasskeyState() {
    return _cachedSnapshot?.passkeyState ??
        const PasskeyAvailabilityState(
          isEnabled: true,
          isPlatformSupported: false,
          isRuntimeConfigured: false,
        );
  }

  String? _cachedAuthMethod() {
    return _cachedSnapshot?.authMethod;
  }

  bool _cachedHasPasskeys() {
    return _cachedSnapshot?.hasPasskeys ?? false;
  }

  Future<String?> _loadCurrentAuthMethod() async {
    try {
      // Always try to fetch fresh data from Supabase
      return await SessionService.getCurrentSessionAuthMethod() ??
          _cachedAuthMethod();
    } catch (error) {
      // Network error - use cached data as fallback
      print(
        '⚠️ [SecurityCenter] Auth method fetch failed (using cache): $error',
      );
      return _cachedAuthMethod();
    }
  }

  _MfaStatus _fallbackMfaStatus() {
    return _MfaStatus(
      hasVerifiedTotp: _lastKnownMfaStatus.hasVerifiedTotp,
      currentSessionVerified: _readAccessTokenClaim('aal') == 'aal2',
      primaryFactorId: _lastKnownMfaStatus.primaryFactorId,
      recoveryCodesRemaining: _lastKnownMfaStatus.recoveryCodesRemaining,
    );
  }

  Future<PasskeyAvailabilityState> _loadPasskeyEnrollmentState() async {
    try {
      // Always try to fetch fresh data from Supabase
      return await PasskeyAuthService.loadRegistrationAvailability();
    } catch (error) {
      // Network error - use cached data as fallback
      print(
        '⚠️ [SecurityCenter] Passkey availability fetch failed (using cache): $error',
      );
      return _cachedPasskeyState();
    }
  }

  Future<bool> _loadUserHasPasskeys() async {
    try {
      // Always try to fetch fresh data from Supabase
      return await PasskeyAuthService.currentUserHasRegisteredPasskeys();
    } catch (error) {
      // Network error - use cached data as fallback
      print(
        '⚠️ [SecurityCenter] Passkey registration check failed (using cache): $error',
      );
      return _cachedHasPasskeys();
    }
  }

  void _refreshPasskeyStateAfterReconnect() {
    unawaited(() async {
      try {
        await appConfigService.refresh();
      } catch (error) {
        print(
          '⚠️ [SecurityCenter] Failed to refresh app config after reconnect: $error',
        );
      }

      if (!mounted) return;
      _refreshPasskeyEnrollmentState();
    }());
  }

  String _authMethodLabel(String? method, LocalizationState l10n) {
    switch ((method ?? '').trim().toLowerCase()) {
      case 'passkey':
        return l10n.getString('settingsAuthMethodPasskey');
      case 'password':
        return l10n.getString('settingsAuthMethodPassword');
      case 'email_otp':
        return l10n.getString('settingsAuthMethodEmailOtp');
      case 'sms_otp':
        return l10n.getString('settingsAuthMethodSmsOtp');
      case 'oauth_google':
        return l10n.getString('settingsAuthMethodGoogle');
      case 'oauth_azure':
      case 'oauth_azuread':
      case 'oauth_microsoft':
        return l10n.getString('settingsAuthMethodMicrosoft');
      case 'oauth_apple':
        return l10n.getString('settingsAuthMethodApple');
      case 'oauth_facebook':
        return l10n.getString('settingsAuthMethodFacebook');
      default:
        return l10n.getString('settingsAuthMethodUnknown');
    }
  }

  bool _isPasskeyAuthMethod(String? method) {
    return (method ?? '').trim().toLowerCase() == 'passkey';
  }

  String _mapPasskeyEnrollmentError(Object error, LocalizationState l10n) {
    if (error is PasskeyClientException) {
      switch (error.code) {
        case 'cancelled':
          return '';
        case 'not_supported':
          return l10n.getString('authPasskeyUnsupported');
        case 'security_error':
          return l10n.getString('authPasskeySecurityError');
        case 'passkey_already_registered':
          return l10n.getString('settingsPasskeyAlreadyRegistered');
        case 'invalid_options':
        case 'invalid_state':
        case 'authenticator_unavailable':
          return l10n.getString('settingsPasskeyAddFailed');
      }
    }

    if (error is PasskeyAuthException) {
      switch (error.code) {
        case 'bad_request':
          return l10n.getString('settingsPasskeyAddFailed');
        case 'config_invalid':
          return l10n.getString('authPasskeySetupRequired');
        case 'timeout':
        case 'network_error':
          return l10n.getString('authNetworkIssue');
        case 'session_missing':
        case 'invalid_response':
        case 'session_apply_failed':
          return l10n.getString('settingsPasskeyAddFailed');
      }
    }

    return l10n.getString('settingsPasskeyAddFailed');
  }

  Future<void> _handlePasskeyEnrollment(LocalizationState l10n) async {
    if (_isEnrollingPasskey) return;

    final isOnline = await _ensureOnlineForSensitiveAction(l10n);
    if (!isOnline || !mounted) return;

    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;

    _logSecurityCenter('[SecurityCenter] Starting passkey enrollment');

    setState(() {
      _isEnrollingPasskey = true;
    });

    try {
      if (!await PasskeyClientService.isRegistrationSupported()) {
        throw const PasskeyClientException(
          code: 'not_supported',
          message: 'Passkey registration is not supported on this platform.',
        );
      }

      final challenge = await PasskeyAuthService.startRegistration();
      if (!challenge.hasPublicKeyOptions) {
        throw const PasskeyAuthException(
          code: 'invalid_response',
          message:
              'Passkey registration options were missing from the server response.',
        );
      }

      final attestation = await PasskeyClientService.getRegistrationAttestation(
        publicKeyOptions: challenge.publicKeyOptions!,
      );
      final result = await PasskeyAuthService.finishRegistrationAndApplySession(
        attestation: attestation,
        requestId: challenge.requestId,
      );

      if (!mounted) return;
      setState(() {
        _hasAddedPasskeyThisSession =
            _hasAddedPasskeyThisSession ||
            (result.credentialId?.isNotEmpty ?? true);
      });
      _showSnackBar(l10n.getString('settingsPasskeyAdded'), isError: false);
      _refreshCurrentAuthMethod();
      _refreshPasskeyEnrollmentState();
    } catch (error) {
      _logSecurityCenter('[SecurityCenter] Passkey enrollment error: $error');

      if (!mounted) return;
      final message = _mapPasskeyEnrollmentError(error, l10n);
      if (message.isNotEmpty) {
        _showSnackBar(message, isError: true);
      }
    } finally {
      await SessionService.setPendingAuthMethod(null);
      if (mounted) {
        setState(() {
          _isEnrollingPasskey = false;
        });
      }
    }
  }

  Future<void> _handlePasskeyRevocation(LocalizationState l10n) async {
    if (_isRevokingPasskeys) return;

    final isOnline = await _ensureOnlineForSensitiveAction(l10n);
    if (!isOnline || !mounted) return;

    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final isRtl = Directionality.of(dialogContext) == TextDirection.rtl;
            final actions = [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                style: AppButtonStyles.tertiaryButton(context),
                child: Text(l10n.getString('generalCancel')),
              ),
              ElevatedButton(
                style: AppButtonStyles.destructiveButton(context),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l10n.getString('settingsPasskeyRevoke')),
              ),
            ];
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              actionsAlignment: MainAxisAlignment.end,
              actionsOverflowAlignment: OverflowBarAlignment.end,
              actionsOverflowButtonSpacing: 8,
              actionsOverflowDirection: VerticalDirection.down,
              title: Text(l10n.getString('settingsPasskeyRevoke')),
              content: Text(l10n.getString('settingsPasskeyRevokeConfirm')),
              actions: isRtl ? actions.reversed.toList() : actions,
            );
          },
        ) ??
        false;

    if (!confirmed || !mounted) return;

    setState(() {
      _isRevokingPasskeys = true;
    });

    try {
      await PasskeyAuthService.revokeAllPasskeys();

      final currentEmail = _currentUserEmail();
      if (currentEmail != null) {
        await PasskeyAuthService.cachePasskeyAvailabilityForEmail(
          currentEmail,
          false,
        );
      }

      if (!mounted) return;
      setState(() {
        _hasAddedPasskeyThisSession = false;
      });
      _showSnackBar(l10n.getString('settingsPasskeyRevoked'), isError: false);
      _refreshCurrentAuthMethod();
      _refreshPasskeyEnrollmentState();
    } catch (error) {
      _logSecurityCenter('[SecurityCenter] Passkey revocation error: $error');

      if (!mounted) return;
      _showSnackBar(
        l10n.getString('settingsPasskeyRevokeFailed'),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRevokingPasskeys = false;
        });
      }
    }
  }

  String _readAccessTokenClaim(String claim) {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) return '';
      final parts = token.split('.');
      if (parts.length != 3) return '';
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (payload is! Map<String, dynamic>) return '';
      final value = payload[claim];
      return value?.toString().trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _normalizeFactorStatus(dynamic status) {
    return status?.toString().split('.').last.toLowerCase().trim() ?? '';
  }

  int _readRecoveryCodeCount(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  List<String> _parseRecoveryCodes(dynamic value) {
    if (value is! List) return const <String>[];
    final codes = <String>[];
    for (final item in value) {
      if (item is String && item.trim().isNotEmpty) {
        codes.add(item.trim());
        continue;
      }
      if (item is Map) {
        final code = item['code']?.toString().trim();
        if (code != null && code.isNotEmpty) {
          codes.add(code);
        }
      }
    }
    return codes;
  }

  String? _currentUserEmail() {
    final email = Supabase.instance.client.auth.currentUser?.email?.trim();
    if (email == null || email.isEmpty) return null;
    return email;
  }

  String _maskEmail(String email) {
    final parts = email.trim().split('@');
    if (parts.length != 2) return email;
    final localPart = parts.first;
    final domainPart = parts.last;
    final safeLocal = localPart.length <= 2
        ? '${localPart.substring(0, 1)}*'
        : '${localPart.substring(0, 1)}${'*' * (localPart.length - 2)}${localPart.substring(localPart.length - 1)}';
    final domainSegments = domainPart.split('.');
    if (domainSegments.isEmpty) return '$safeLocal@$domainPart';
    final domainName = domainSegments.first;
    final safeDomain = domainName.length <= 2
        ? '${domainName.substring(0, 1)}*'
        : '${domainName.substring(0, 1)}${'*' * (domainName.length - 2)}${domainName.substring(domainName.length - 1)}';
    final suffix = domainSegments.length > 1
        ? '.${domainSegments.skip(1).join('.')}'
        : '';
    return '$safeLocal@$safeDomain$suffix';
  }

  Future<_MfaStatus> _loadMfaStatus({bool forceRefresh = false}) {
    if (!forceRefresh && _mfaStatusRequest != null) {
      return _mfaStatusRequest!;
    }

    final request = () async {
      try {
        // Always try to fetch fresh data from Supabase
        final factors = await Supabase.instance.client.auth.mfa
            .listFactors()
            .timeout(_mfaStatusTimeout);
        Object? recoveryStatus;
        try {
          recoveryStatus = await Supabase.instance.client
              .rpc('get_mfa_recovery_code_status')
              .timeout(_mfaStatusTimeout);
        } catch (error) {
          print('Security Center MFA recovery status refresh skipped: $error');
        }
        final verifiedTotp = factors.totp
            .where((factor) {
              return _normalizeFactorStatus((factor as dynamic).status) ==
                  'verified';
            })
            .toList(growable: false);
        final primaryFactor = verifiedTotp.isNotEmpty
            ? verifiedTotp.first as dynamic
            : null;
        final primaryFactorId = primaryFactor?.id?.toString().trim();
        final recoveryCodesRemaining = recoveryStatus is Map
            ? _readRecoveryCodeCount(recoveryStatus['available_count'])
            : 0;

        final status = _MfaStatus(
          hasVerifiedTotp: verifiedTotp.isNotEmpty,
          currentSessionVerified: _readAccessTokenClaim('aal') == 'aal2',
          primaryFactorId: primaryFactorId != null && primaryFactorId.isNotEmpty
              ? primaryFactorId
              : null,
          recoveryCodesRemaining: recoveryCodesRemaining,
        );
        _lastKnownMfaStatus = status;
        return status;
      } catch (error) {
        // Network error - use cached data as fallback
        print(
          '⚠️ [SecurityCenter] MFA status fetch failed (using cache): $error',
        );
        return _cachedMfaStatus();
      }
    }();

    _mfaStatusRequest = request.whenComplete(() {
      if (identical(_mfaStatusRequest, request)) {
        _mfaStatusRequest = null;
      }
    });
    return _mfaStatusRequest!;
  }

  Future<bool> _ensureMfaVerifiedForSensitiveAction(
    LocalizationState l10n,
  ) async {
    return ensureSensitiveActionVerified(
      context: context,
      l10n: l10n,
      isMounted: () => mounted,
      getCurrentUserEmail: _currentUserEmail,
      loadStatus: () async {
        final status = await _loadMfaStatus(forceRefresh: true);
        return SensitiveActionVerificationStatus(
          primaryFactorId: status.primaryFactorId,
          hasVerifiedTotp: status.hasVerifiedTotp,
        );
      },
      showProgressOverlay: () => _showMfaProgressOverlay(l10n),
      hideProgressOverlay: _hideMfaProgressOverlay,
      refreshStatus: _refreshMfaStatus,
      showSnackBar: _showSnackBar,
      logDebug: _logSecurityCenter,
    );
  }

  Future<bool> _ensureOnlineForSensitiveAction(LocalizationState l10n) async {
    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (isOnline) return true;

    await showOfflineFeatureDialog(
      context,
      title: '',
      message: l10n.getString('offlineSensitiveActionsRequireInternet'),
      ref: ref,
    );
    return false;
  }

  Future<void> _showMfaEnrollmentDialog(LocalizationState l10n) async {
    final isOnline = await _ensureOnlineForSensitiveAction(l10n);
    if (!isOnline || !mounted) return;

    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;

    final enrolled =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _MfaEnrollDialog(l10n: l10n),
        ) ??
        false;

    if (!enrolled) return;

    _refreshMfaStatus();
    _showSnackBar(
      l10n.getString('settingsMfaEnrollmentSuccess'),
      isError: false,
    );
  }

  Future<void> _disableMfa(LocalizationState l10n) async {
    final isOnline = await _ensureOnlineForSensitiveAction(l10n);
    if (!isOnline || !mounted) return;

    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final isRtl = Directionality.of(dialogContext) == TextDirection.rtl;
            final actions = [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.getString('generalCancel')),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l10n.getString('settingsMfaDisable')),
              ),
            ];
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              actionsAlignment: MainAxisAlignment.end,
              actionsOverflowAlignment: OverflowBarAlignment.end,
              actionsOverflowButtonSpacing: 8,
              actionsOverflowDirection: VerticalDirection.down,
              title: Text(l10n.getString('settingsMfaDisable')),
              content: Text(l10n.getString('settingsMfaDisableConfirm')),
              actions: isRtl ? actions.reversed.toList() : actions,
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    try {
      final factors = await Supabase.instance.client.auth.mfa.listFactors();
      final verifiedTotp = factors.totp
          .where((factor) {
            return _normalizeFactorStatus((factor as dynamic).status) ==
                'verified';
          })
          .toList(growable: false);

      for (final factor in verifiedTotp) {
        final factorId = (factor as dynamic).id?.toString().trim();
        if (factorId == null || factorId.isEmpty) continue;
        await Supabase.instance.client.auth.mfa.unenroll(factorId);
      }

      await Supabase.instance.client.rpc('clear_mfa_recovery_codes');
      _refreshMfaStatus();
      _showSnackBar(
        l10n.getString('settingsMfaDisableSuccess'),
        isError: false,
      );
    } catch (_) {
      _showSnackBar(l10n.getString('settingsMfaDisableFailed'), isError: true);
    }
  }

  Future<void> _generateRecoveryCodes(LocalizationState l10n) async {
    final isOnline = await _ensureOnlineForSensitiveAction(l10n);
    if (!isOnline || !mounted) return;

    final status = await _loadMfaStatus(forceRefresh: true);
    if (!mounted || !status.hasVerifiedTotp) return;

    final hasExistingCodes = status.recoveryCodesRemaining > 0;
    if (hasExistingCodes) {
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              final isRtl =
                  Directionality.of(dialogContext) == TextDirection.rtl;
              final actions = [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.getString('generalCancel')),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(
                    l10n.getString('settingsMfaRecoveryCodesRegenerate'),
                  ),
                ),
              ];
              return AlertDialog(
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                actionsAlignment: MainAxisAlignment.end,
                actionsOverflowAlignment: OverflowBarAlignment.end,
                actionsOverflowButtonSpacing: 8,
                actionsOverflowDirection: VerticalDirection.down,
                title: Text(
                  l10n.getString('settingsMfaRecoveryCodesRegenerate'),
                ),
                content: Text(
                  l10n.getString('settingsMfaRecoveryCodesRegenerateConfirm'),
                ),
                actions: isRtl ? actions.reversed.toList() : actions,
              );
            },
          ) ??
          false;
      if (!confirmed || !mounted) return;
    }

    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;

    try {
      final response = await Supabase.instance.client.rpc(
        'generate_mfa_recovery_codes',
        params: {'p_replace_existing': true},
      );
      final codes = _parseRecoveryCodes(response);
      if (codes.isEmpty) {
        throw StateError('No recovery codes generated');
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _MfaRecoveryCodesDialog(
          l10n: l10n,
          codes: codes,
          regenerated: hasExistingCodes,
        ),
      );
      _refreshMfaStatus();
      _showSnackBar(
        l10n.getString(
          hasExistingCodes
              ? 'settingsMfaRecoveryCodesRegenerated'
              : 'settingsMfaRecoveryCodesGenerated',
        ),
        isError: false,
      );
    } catch (_) {
      _showSnackBar(
        l10n.getString('settingsMfaRecoveryCodesGenerateFailed'),
        isError: true,
      );
    }
  }

  String _securityLevelKey({
    required bool hasPasskeys,
    required bool passkeyReady,
    required bool hasMfa,
  }) {
    if (hasPasskeys && hasMfa) return 'securityLevelMaximum';
    if (hasPasskeys || (hasMfa && passkeyReady)) return 'securityLevelHigh';
    return 'securityLevelBasic';
  }

  Color _securityLevelColor({
    required bool hasPasskeys,
    required bool hasMfa,
    required ColorScheme colors,
  }) {
    if (hasPasskeys && hasMfa) return Colors.green.shade700;
    if (hasPasskeys || hasMfa) return colors.primary;
    return colors.secondary;
  }

  String _securityHeadlineKey({
    required bool hasPasskeys,
    required bool hasMfa,
  }) {
    return hasPasskeys && hasMfa
        ? 'securityCenterHeroTitleStrong'
        : 'securityCenterHeroTitleSetup';
  }

  String _securityBodyKey({required bool hasPasskeys, required bool hasMfa}) {
    return hasPasskeys && hasMfa
        ? 'securityCenterHeroBodyStrong'
        : 'securityCenterHeroBodySetup';
  }

  String _mfaPrimaryTextKey({required bool hasMfa}) {
    if (!hasMfa) return 'securityCenterAuthenticatorPrimaryOff';
    return 'securityCenterAuthenticatorPrimaryOn';
  }

  String _mfaSecondaryTextKey({
    required bool hasMfa,
    required int recoveryCodesRemaining,
  }) {
    if (!hasMfa) return 'securityCenterAuthenticatorSecondaryOff';
    if (recoveryCodesRemaining > 0) {
      return 'securityCenterAuthenticatorSecondaryRecoveryReady';
    }
    return 'securityCenterAuthenticatorSecondaryRecoveryMissing';
  }

  String _passkeyPrimaryTextKey({
    required bool hasPasskeys,
    required bool isPasskeySession,
    required bool justAdded,
  }) {
    if (hasPasskeys && isPasskeySession) {
      return 'securityCenterPasskeyPrimarySignedIn';
    }
    if (hasPasskeys || justAdded) {
      return 'securityCenterPasskeyPrimaryReady';
    }
    return 'securityCenterPasskeyPrimaryOff';
  }

  String _passkeySecondaryTextKey({
    required bool platformSupported,
    required bool runtimeConfigured,
    required bool hasPasskeys,
  }) {
    if (!platformSupported) return 'securityCenterPasskeySecondaryUnsupported';
    if (!runtimeConfigured) {
      return 'securityCenterPasskeySecondarySetupRequired';
    }
    if (hasPasskeys) return 'securityCenterPasskeySecondaryProtected';
    return 'securityCenterPasskeySecondaryReady';
  }

  String _passkeySessionTextKey({
    required bool hasPasskeys,
    required bool isPasskeySession,
  }) {
    if (isPasskeySession) {
      return 'securityCenterPasskeySessionPasskey';
    }
    if (hasPasskeys) {
      return 'securityCenterPasskeySessionReady';
    }
    return 'securityCenterPasskeySessionOther';
  }

  Widget _buildMetric({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionWrap(List<Widget> actions) {
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final singleColumn = constraints.maxWidth < 560;
        final itemWidth = singleColumn
            ? constraints.maxWidth
            : (constraints.maxWidth - 10) / 2;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final action in actions)
              SizedBox(width: itemWidth, height: 48, child: action),
          ],
        );
      },
    );
  }

  Widget _buildOverviewCard(
    LocalizationState l10n, {
    required _MfaStatus mfaStatus,
    required PasskeyAvailabilityState passkeyState,
    required bool hasPasskeys,
    required String? authMethod,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final securityColor = _securityLevelColor(
      hasPasskeys: hasPasskeys,
      hasMfa: mfaStatus.hasVerifiedTotp,
      colors: colors,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            securityColor.withValues(alpha: 0.18),
            colors.primary.withValues(alpha: 0.10),
            colors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: securityColor.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: securityColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  hasPasskeys && mfaStatus.hasVerifiedTotp
                      ? Icons.verified_user_rounded
                      : Icons.shield_outlined,
                  color: securityColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.getString(
                        _securityLevelKey(
                          hasPasskeys: hasPasskeys,
                          passkeyReady: passkeyState.canUse,
                          hasMfa: mfaStatus.hasVerifiedTotp,
                        ),
                      ),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: securityColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.getString(
                        _securityHeadlineKey(
                          hasPasskeys: hasPasskeys,
                          hasMfa: mfaStatus.hasVerifiedTotp,
                        ),
                      ),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.getString(
              _securityBodyKey(
                hasPasskeys: hasPasskeys,
                hasMfa: mfaStatus.hasVerifiedTotp,
              ),
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurface.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildMetric(
                icon: Icons.login_rounded,
                color: colors.primary,
                label: l10n.getString('securityCenterMetricSignInMethod'),
                value: _authMethodLabel(authMethod, l10n),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _SecurityBadge(
                icon: mfaStatus.hasVerifiedTotp
                    ? Icons.shield_rounded
                    : Icons.shield_outlined,
                label: l10n.getString(
                  mfaStatus.hasVerifiedTotp
                      ? 'securityCenterBadgeAuthenticatorOn'
                      : 'securityCenterBadgeAuthenticatorOff',
                ),
                color: mfaStatus.hasVerifiedTotp
                    ? Colors.green.shade700
                    : colors.onSurfaceVariant,
              ),
              _SecurityBadge(
                icon: hasPasskeys ? Icons.key_rounded : Icons.key_off_outlined,
                label: l10n.getString(
                  hasPasskeys
                      ? 'securityCenterBadgePasskeyOn'
                      : 'securityCenterBadgePasskeyOff',
                ),
                color: hasPasskeys ? colors.primary : colors.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAuthenticatorCard(
    LocalizationState l10n, {
    required _MfaStatus status,
    required bool canManageSensitiveActions,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasMfa = status.hasVerifiedTotp;
    final recoveryCodesRemaining = status.recoveryCodesRemaining;
    final accent = hasMfa ? Colors.green.shade700 : colors.secondary;

    return _SecurityFeatureCard(
      accent: accent,
      icon: Icons.shield_rounded,
      title: l10n.getString('settingsMfaTitle'),
      statusLabel: l10n.getString(
        hasMfa
            ? 'securityCenterStatusActive'
            : 'securityCenterStatusRecommended',
      ),
      body: l10n.getString(_mfaPrimaryTextKey(hasMfa: hasMfa)),
      secondaryBody: l10n.getString(
        _mfaSecondaryTextKey(
          hasMfa: hasMfa,
          recoveryCodesRemaining: recoveryCodesRemaining,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildMetric(
                icon: recoveryCodesRemaining > 0
                    ? Icons.key_rounded
                    : Icons.key_off_outlined,
                color: recoveryCodesRemaining > 0
                    ? Colors.green.shade700
                    : colors.onSurfaceVariant,
                label: l10n.getString('securityCenterMetricBackupCodes'),
                value: recoveryCodesRemaining > 0
                    ? l10n.getString(
                        'settingsMfaRecoveryCodesCount',
                        params: {
                          'count': l10n.formatCount(recoveryCodesRemaining),
                        },
                      )
                    : l10n.getString('settingsMfaRecoveryCodesMissing'),
              ),
            ],
          ),

          const SizedBox(height: 12),
          _buildActionWrap([
            if (!hasMfa)
              FilledButton.icon(
                style: AppButtonStyles.primaryButton(context),
                onPressed: canManageSensitiveActions
                    ? () => _showMfaEnrollmentDialog(l10n)
                    : null,
                icon: const Icon(Icons.shield_outlined),
                label: Text(
                  l10n.getString('securityCenterAuthenticatorCtaEnable'),
                ),
              ),
            if (hasMfa)
              OutlinedButton.icon(
                style: AppButtonStyles.secondaryButton(context),
                onPressed: canManageSensitiveActions
                    ? () => _generateRecoveryCodes(l10n)
                    : null,
                icon: const Icon(Icons.key_outlined),
                label: Text(
                  recoveryCodesRemaining > 0
                      ? l10n.getString(
                          'securityCenterAuthenticatorCtaRefreshCodes',
                        )
                      : l10n.getString(
                          'securityCenterAuthenticatorCtaCreateCodes',
                        ),
                ),
              ),
            if (hasMfa)
              OutlinedButton.icon(
                style: AppButtonStyles.destructiveButton(context),
                onPressed: canManageSensitiveActions
                    ? () => _disableMfa(l10n)
                    : null,
                icon: const Icon(Icons.remove_moderator_outlined),
                label: Text(
                  l10n.getString('securityCenterAuthenticatorCtaTurnOff'),
                ),
              ),
          ]),
          if (!canManageSensitiveActions) ...[
            const SizedBox(height: 12),
            SensitiveActionsOfflineNotice(
              message: l10n.getString('offlineSensitiveActionsRequireInternet'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmailVerificationCard(LocalizationState l10n) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final recoveryEmail = _currentUserEmail();
    final maskedRecoveryEmail = recoveryEmail == null
        ? null
        : _maskEmail(recoveryEmail);

    if (maskedRecoveryEmail == null) {
      return const SizedBox.shrink();
    }

    return _SecurityFeatureCard(
      accent: colors.primary,
      icon: Icons.mail_outline_rounded,
      title: l10n.getString('settingsEmailVerification'),
      statusLabel: l10n.getString('securityCenterStatusAvailable'),
      body: l10n.getString('securityCenterEmailVerificationBody'),
      secondaryBody: l10n.getString(
        'securityCenterEmailVerificationSecondary',
        params: {'email': maskedRecoveryEmail},
      ),
      child: const SizedBox.shrink(),
    );
  }

  Widget _buildPasskeyCard(
    LocalizationState l10n, {
    required PasskeyAvailabilityState state,
    required bool hasPasskeys,
    required String? authMethod,
    required bool canManageSensitiveActions,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isPasskeySession = _isPasskeyAuthMethod(authMethod);
    final hasAvailablePasskeys = hasPasskeys || _hasAddedPasskeyThisSession;
    final platformSupported = state.isPlatformSupported;
    final runtimeConfigured = state.isRuntimeConfigured;
    final accent = hasAvailablePasskeys
        ? colors.primary
        : platformSupported && runtimeConfigured
        ? Colors.green.shade700
        : colors.secondary;
    final canAddPasskey =
        state.isEnabled &&
        platformSupported &&
        runtimeConfigured &&
        canManageSensitiveActions &&
        !_isEnrollingPasskey;

    return _SecurityFeatureCard(
      accent: accent,
      icon: Icons.key_rounded,
      title: l10n.getString('settingsPasskeyTitle'),
      statusLabel: l10n.getString(
        hasAvailablePasskeys
            ? 'securityCenterStatusActive'
            : platformSupported && runtimeConfigured
            ? 'securityCenterStatusReady'
            : 'securityCenterStatusAttention',
      ),
      body: l10n.getString(
        _passkeyPrimaryTextKey(
          hasPasskeys: hasAvailablePasskeys,
          isPasskeySession: isPasskeySession,
          justAdded: _hasAddedPasskeyThisSession,
        ),
      ),
      secondaryBody: l10n.getString(
        _passkeySecondaryTextKey(
          platformSupported: platformSupported,
          runtimeConfigured: runtimeConfigured,
          hasPasskeys: hasAvailablePasskeys,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildMetric(
                icon: platformSupported
                    ? Icons.devices_outlined
                    : Icons.phonelink_erase_outlined,
                color: platformSupported
                    ? Colors.green.shade700
                    : colors.onSurfaceVariant,
                label: l10n.getString('securityCenterMetricDevice'),
                value: l10n.getString(
                  platformSupported
                      ? 'securityCenterMetricDeviceSupported'
                      : 'securityCenterMetricDeviceUnsupported',
                ),
              ),
              const SizedBox(width: 10),
              _buildMetric(
                icon: runtimeConfigured
                    ? Icons.cloud_done_outlined
                    : Icons.settings_ethernet_outlined,
                color: runtimeConfigured
                    ? Colors.green.shade700
                    : colors.secondary,
                label: l10n.getString('securityCenterMetricServer'),
                value: l10n.getString(
                  runtimeConfigured
                      ? 'securityCenterMetricServerReady'
                      : 'securityCenterMetricServerSetup',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isPasskeySession
                  ? Colors.green.withValues(alpha: 0.08)
                  : colors.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  isPasskeySession
                      ? Icons.fingerprint_rounded
                      : Icons.login_rounded,
                  color: isPasskeySession
                      ? Colors.green.shade700
                      : colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.getString(
                      _passkeySessionTextKey(
                        hasPasskeys: hasAvailablePasskeys,
                        isPasskeySession: isPasskeySession,
                      ),
                      params: isPasskeySession
                          ? null
                          : {'method': _authMethodLabel(authMethod, l10n)},
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildActionWrap([
            FilledButton.icon(
              style: AppButtonStyles.primaryButton(context),
              onPressed: canAddPasskey
                  ? () => _handlePasskeyEnrollment(l10n)
                  : null,
              icon: _isEnrollingPasskey
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colors.onPrimary,
                        ),
                      ),
                    )
                  : const Icon(Icons.add_link_rounded),
              label: Text(
                l10n.getString(
                  hasAvailablePasskeys
                      ? 'securityCenterPasskeyCtaAddAnother'
                      : 'securityCenterPasskeyCtaCreate',
                ),
              ),
            ),
            if (hasAvailablePasskeys)
              OutlinedButton.icon(
                style: AppButtonStyles.destructiveButton(context),
                onPressed: !canManageSensitiveActions || _isRevokingPasskeys
                    ? null
                    : () => _handlePasskeyRevocation(l10n),
                icon: _isRevokingPasskeys
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            colors.primary,
                          ),
                        ),
                      )
                    : const Icon(Icons.delete_outline_rounded),
                label: Text(
                  l10n.getString('securityCenterPasskeyCtaRemoveAll'),
                ),
              ),
          ]),
          if (!canManageSensitiveActions) ...[
            const SizedBox(height: 12),
            SensitiveActionsOfflineNotice(
              message: l10n.getString('offlineSensitiveActionsRequireInternet'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    final canManageSensitiveActions = isOnline;
    final hasConnectivityChanged = _lastKnownOnlineState != isOnline;
    final cameBackOnline = _lastKnownOnlineState == false && isOnline;

    if (hasConnectivityChanged) {
      _lastKnownOnlineState = isOnline;
      if (cameBackOnline) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _refreshPasskeyStateAfterReconnect();
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.getString('securityCenterTitle'))),
      body: FutureBuilder<List<Object?>>(
        initialData: _cachedSnapshot?.toFutureBuilderData(),
        future: Future.wait<Object?>([
          _mfaStatusFuture,
          _passkeyEnrollmentStateFuture,
          _currentAuthMethodFuture,
          _userHasPasskeysFuture,
        ]),
        builder: (context, snapshot) {
          // Use fresh data if available, otherwise use cached data
          final resolvedData =
              snapshot.data ?? _cachedSnapshot?.toFutureBuilderData();
          final isLoading =
              snapshot.connectionState == ConnectionState.waiting &&
              resolvedData == null;
          final hasError = snapshot.hasError && resolvedData == null;

          final mfaStatus = resolvedData != null && resolvedData.isNotEmpty
              ? resolvedData[0] as _MfaStatus
              : _fallbackMfaStatus();
          final passkeyState = resolvedData != null && resolvedData.length > 1
              ? resolvedData[1] as PasskeyAvailabilityState
              : const PasskeyAvailabilityState(
                  isEnabled: true,
                  isPlatformSupported: false,
                  isRuntimeConfigured: false,
                );
          final authMethod = resolvedData != null && resolvedData.length > 2
              ? resolvedData[2] as String?
              : null;
          final hasPasskeys = resolvedData != null && resolvedData.length > 3
              ? resolvedData[3] as bool
              : false;

          return RefreshIndicator(
            onRefresh: () async {
              _refreshMfaStatus();
              _refreshCurrentAuthMethod();
              _refreshPasskeyEnrollmentState();
              await Future.wait<void>([
                _mfaStatusFuture.then((_) {}),
                _passkeyEnrollmentStateFuture.then((_) {}),
                _currentAuthMethodFuture.then((_) {}),
                _userHasPasskeysFuture.then((_) {}),
              ]);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              children: [
                if (isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (hasError)
                  _SecurityFeatureCard(
                    accent: Theme.of(context).colorScheme.error,
                    icon: Icons.error_outline_rounded,
                    eyebrow: l10n.getString('generalError'),
                    title: l10n.getString('securityCenterLoadFailedTitle'),
                    statusLabel: l10n.getString(
                      'securityCenterStatusAttention',
                    ),
                    body: l10n.getString('securityCenterLoadFailedBody'),
                    secondaryBody: l10n.getString(
                      'securityCenterLoadFailedHint',
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonal(
                        onPressed: () {
                          _refreshMfaStatus();
                          _refreshCurrentAuthMethod();
                          _refreshPasskeyEnrollmentState();
                        },
                        child: Text(l10n.getString('generalRetry')),
                      ),
                    ),
                  )
                else ...[
                  _buildOverviewCard(
                    l10n,
                    mfaStatus: mfaStatus,
                    passkeyState: passkeyState,
                    hasPasskeys: hasPasskeys || _hasAddedPasskeyThisSession,
                    authMethod: authMethod,
                  ),
                  if (passkeyState.isEnabled)
                    _buildPasskeyCard(
                      l10n,
                      state: passkeyState,
                      hasPasskeys: hasPasskeys,
                      authMethod: authMethod,
                      canManageSensitiveActions: canManageSensitiveActions,
                    ),
                  if (passkeyState.isEnabled) const SizedBox(height: 10),
                  _buildAuthenticatorCard(
                    l10n,
                    status: mfaStatus,
                    canManageSensitiveActions: canManageSensitiveActions,
                  ),
                  const SizedBox(height: 10),
                  _buildEmailVerificationCard(l10n),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SecurityFeatureCard extends StatelessWidget {
  const _SecurityFeatureCard({
    required this.accent,
    required this.icon,
    required this.title,
    required this.statusLabel,
    required this.body,
    required this.secondaryBody,
    required this.child,
    this.eyebrow,
  });

  final Color accent;
  final IconData icon;
  final String? eyebrow;
  final String title;
  final String statusLabel;
  final String body;
  final String secondaryBody;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(color: accent.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null) ...[
                      Text(
                        eyebrow!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              _SecurityBadge(
                icon: Icons.bolt_rounded,
                label: statusLabel,
                color: accent,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            secondaryBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurface.withValues(alpha: 0.76),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SecurityBadge extends StatelessWidget {
  const _SecurityBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaStatus {
  const _MfaStatus({
    required this.hasVerifiedTotp,
    required this.currentSessionVerified,
    required this.primaryFactorId,
    required this.recoveryCodesRemaining,
  });

  final bool hasVerifiedTotp;
  final bool currentSessionVerified;
  final String? primaryFactorId;
  final int recoveryCodesRemaining;

  _MfaStatus copyWith({
    bool? hasVerifiedTotp,
    bool? currentSessionVerified,
    String? primaryFactorId,
    int? recoveryCodesRemaining,
  }) {
    return _MfaStatus(
      hasVerifiedTotp: hasVerifiedTotp ?? this.hasVerifiedTotp,
      currentSessionVerified:
          currentSessionVerified ?? this.currentSessionVerified,
      primaryFactorId: primaryFactorId ?? this.primaryFactorId,
      recoveryCodesRemaining:
          recoveryCodesRemaining ?? this.recoveryCodesRemaining,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'hasVerifiedTotp': hasVerifiedTotp,
      'currentSessionVerified': currentSessionVerified,
      'primaryFactorId': primaryFactorId,
      'recoveryCodesRemaining': recoveryCodesRemaining,
    };
  }

  factory _MfaStatus.fromJson(Map<String, dynamic> json) {
    return _MfaStatus(
      hasVerifiedTotp: json['hasVerifiedTotp'] == true,
      currentSessionVerified: json['currentSessionVerified'] == true,
      primaryFactorId: json['primaryFactorId'] as String?,
      recoveryCodesRemaining: _parseInt(json['recoveryCodesRemaining']),
    );
  }
}

class _SecurityCenterSnapshot {
  const _SecurityCenterSnapshot({
    required this.mfaStatus,
    required this.passkeyState,
    required this.authMethod,
    required this.hasPasskeys,
  });

  final _MfaStatus mfaStatus;
  final PasskeyAvailabilityState passkeyState;
  final String? authMethod;
  final bool hasPasskeys;

  List<Object?> toFutureBuilderData() {
    return [mfaStatus, passkeyState, authMethod, hasPasskeys];
  }

  Map<String, dynamic> toJson() {
    return {
      'mfaStatus': mfaStatus.toJson(),
      'passkeyState': {
        'isEnabled': passkeyState.isEnabled,
        'isPlatformSupported': passkeyState.isPlatformSupported,
        'isRuntimeConfigured': passkeyState.isRuntimeConfigured,
      },
      'authMethod': authMethod,
      'hasPasskeys': hasPasskeys,
    };
  }

  factory _SecurityCenterSnapshot.fromJson(Map<String, dynamic> json) {
    final mfaStatusJson = json['mfaStatus'];
    final passkeyStateJson = json['passkeyState'];

    return _SecurityCenterSnapshot(
      mfaStatus: mfaStatusJson is Map<String, dynamic>
          ? _MfaStatus.fromJson(mfaStatusJson)
          : const _MfaStatus(
              hasVerifiedTotp: false,
              currentSessionVerified: false,
              primaryFactorId: null,
              recoveryCodesRemaining: 0,
            ),
      passkeyState: passkeyStateJson is Map<String, dynamic>
          ? PasskeyAvailabilityState(
              isEnabled: passkeyStateJson['isEnabled'] != false,
              isPlatformSupported:
                  passkeyStateJson['isPlatformSupported'] == true,
              isRuntimeConfigured:
                  passkeyStateJson['isRuntimeConfigured'] == true,
            )
          : const PasskeyAvailabilityState(
              isEnabled: true,
              isPlatformSupported: false,
              isRuntimeConfigured: false,
            ),
      authMethod: json['authMethod'] as String?,
      hasPasskeys: json['hasPasskeys'] == true,
    );
  }
}

int _parseInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

class _MfaRecoveryCodesDialog extends StatelessWidget {
  const _MfaRecoveryCodesDialog({
    required this.l10n,
    required this.codes,
    required this.regenerated,
  });

  final LocalizationState l10n;
  final List<String> codes;
  final bool regenerated;

  Future<void> _copyCodes(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: codes.join('\n')));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.getString('settingsMfaRecoveryCodesCopied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      title: Text(l10n.getString('settingsMfaRecoveryCodesDialogTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.getString(
                regenerated
                    ? 'settingsMfaRecoveryCodesDialogRegeneratedBody'
                    : 'settingsMfaRecoveryCodesDialogBody',
              ),
            ),
            const SizedBox(height: 16),
            ...codes.map(
              (code) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(
                  code,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _copyCodes(context),
          child: Text(l10n.getString('settingsMfaRecoveryCodesCopy')),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.getString('generalContinue')),
        ),
      ],
    );
  }
}

class _MfaEnrollDialog extends StatefulWidget {
  const _MfaEnrollDialog({required this.l10n});

  final LocalizationState l10n;

  @override
  State<_MfaEnrollDialog> createState() => _MfaEnrollDialogState();
}

class _MfaEnrollDialogState extends State<_MfaEnrollDialog> {
  final TextEditingController _codeController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _isInitializing = true;
  bool _isSubmitting = false;
  bool _completed = false;
  String? _factorId;
  String? _secret;
  String? _qrCodeSvg;
  String? _errorText;

  String get _accountLabel {
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email?.trim();
    if (email != null && email.isNotEmpty) {
      return email.replaceAll(':', ' ');
    }
    final phone = user?.phone?.trim();
    if (phone != null && phone.isNotEmpty) {
      return phone.replaceAll(':', ' ');
    }
    return (user?.id ?? 'user').replaceAll(':', ' ');
  }

  String? get _otpauthUri {
    final secret = _secret?.trim();
    if (secret == null || secret.isEmpty) return null;
    final issuer = Uri.encodeQueryComponent('MatchMe');
    final label = Uri.encodeComponent('MatchMe:$_accountLabel');
    final normalizedSecret = secret.replaceAll(' ', '');
    return 'otpauth://totp/$label?secret=$normalizedSecret&issuer=$issuer&algorithm=SHA1&digits=6&period=30';
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_startEnrollment);
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _startEnrollment() async {
    try {
      final response = await Supabase.instance.client.auth.mfa.enroll(
        factorType: FactorType.totp,
        issuer: 'MatchMe',
        friendlyName: 'MatchMe',
      );
      if (!mounted) return;
      final secret = response.totp?.secret;
      if (secret == null || secret.isEmpty) {
        throw StateError('Missing TOTP secret');
      }
      setState(() {
        _factorId = response.id;
        _secret = secret;
        _qrCodeSvg = response.totp?.qrCode;
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = widget.l10n.getString('settingsMfaEnrollmentFailed');
        _isInitializing = false;
      });
    }
  }

  Future<void> _cancel() async {
    final factorId = _factorId;
    if (!_completed && factorId != null && factorId.isNotEmpty) {
      try {
        await Supabase.instance.client.auth.mfa.unenroll(factorId);
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  Future<void> _copySecret() async {
    final secret = _secret;
    if (secret == null || secret.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.l10n.getString('settingsMfaCopied'))),
    );
  }

  Future<void> _openAuthenticatorApp() async {
    final otpauthUri = _otpauthUri;
    if (otpauthUri == null || otpauthUri.isEmpty) return;

    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(otpauthUri),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }

    if (!launched) {
      launched = await AuthenticatorAppLauncher.open();
    }

    if (launched || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.l10n.getString('settingsMfaOpenAuthenticatorFailed'),
        ),
      ),
    );
  }

  Future<void> _verify() async {
    if (!_formKey.currentState!.validate()) return;
    final factorId = _factorId;
    if (factorId == null || factorId.isEmpty) {
      setState(() {
        _errorText = widget.l10n.getString('settingsMfaEnrollmentFailed');
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      await Supabase.instance.client.auth.mfa.challengeAndVerify(
        factorId: factorId,
        code: _codeController.text.trim(),
      );
      _completed = true;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = widget.l10n.getString('settingsMfaVerificationFailed');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showDirectOpenButton = !kIsWeb;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      scrollable: true,
      title: Text(widget.l10n.getString('settingsMfaSetupTitle')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: _isInitializing
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_errorText != null && (_secret ?? '').isEmpty) ...[
                        Text(
                          _errorText!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ] else ...[
                        Text(widget.l10n.getString('settingsMfaSetupBody')),
                        if (showDirectOpenButton) ...[
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            onPressed: _openAuthenticatorApp,
                            icon: const Icon(Icons.open_in_new),
                            label: Text(
                              widget.l10n.getString(
                                'settingsMfaOpenAuthenticator',
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.l10n.getString(
                              'settingsMfaOpenAuthenticatorBody',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if ((_qrCodeSvg ?? '').isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Text(
                            widget.l10n.getString('settingsMfaQrTitle'),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.dividerColor),
                              borderRadius: BorderRadius.circular(16),
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.35),
                            ),
                            child: Center(
                              child: SvgPicture.string(
                                _qrCodeSvg!,
                                width: 180,
                                height: 180,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.l10n.getString('settingsMfaQrBody'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          widget.l10n.getString('settingsMfaManualEntryTitle'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.l10n.getString('settingsMfaManualEntryBody'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.l10n.getString('settingsMfaSecret'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: theme.dividerColor),
                            borderRadius: BorderRadius.circular(12),
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                          ),
                          child: SelectableText(_secret ?? ''),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _copySecret,
                          icon: const Icon(Icons.copy),
                          label: Text(
                            widget.l10n.getString('settingsMfaCopySecret'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _codeController,
                          keyboardType: TextInputType.number,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          decoration: InputDecoration(
                            label: Text(
                              widget.l10n.getString('settingsMfaCode'),
                            ),
                            errorText: _errorText,
                          ),
                          validator: (value) {
                            final code = value?.trim() ?? '';
                            if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                              return widget.l10n.getString(
                                'settingsMfaEnterCode',
                              );
                            }
                            return null;
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : _cancel,
          child: Text(widget.l10n.getString('generalCancel')),
        ),
        ElevatedButton(
          onPressed: _isInitializing || _isSubmitting || (_secret ?? '').isEmpty
              ? null
              : _verify,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.l10n.getString('generalContinue')),
        ),
      ],
    );
  }
}
