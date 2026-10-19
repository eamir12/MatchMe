import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/settings/email_change_screen.dart';
import 'package:matchme/screens/settings/sensitive_action_verification.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/safe_text.dart';

class AccountManagementScreen extends ConsumerStatefulWidget {
  const AccountManagementScreen({super.key});

  @override
  ConsumerState<AccountManagementScreen> createState() =>
      _AccountManagementScreenState();
}

class _AccountManagementScreenState
    extends ConsumerState<AccountManagementScreen>
    with WidgetsBindingObserver {
  static const Duration _mfaStatusTimeout = Duration(seconds: 8);
  _MfaStatus _lastKnownMfaStatus = const _MfaStatus(
    hasVerifiedTotp: false,
    currentSessionVerified: false,
    primaryFactorId: null,
    recoveryCodesRemaining: 0,
  );
  Future<_MfaStatus>? _mfaStatusRequest;
  OverlayEntry? _mfaProgressOverlay;

  bool _passwordHasMinLength(String value) => value.length >= 8;
  bool _passwordHasUppercase(String value) => value.contains(RegExp(r'[A-Z]'));
  bool _passwordHasLowercase(String value) => value.contains(RegExp(r'[a-z]'));
  bool _passwordHasNumber(String value) => value.contains(RegExp(r'\d'));
  bool _passwordHasSpecialCharacter(String value) =>
      value.contains(RegExp(r'[@$!%*?&]'));

  bool _isValidNewPassword(String value) =>
      _passwordHasMinLength(value) &&
      _passwordHasUppercase(value) &&
      _passwordHasLowercase(value) &&
      _passwordHasNumber(value) &&
      _passwordHasSpecialCharacter(value);

  Widget _buildPasswordRequirementRow(
    BuildContext context, {
    required bool met,
    required String label,
  }) {
    final theme = Theme.of(context);
    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final color = met
        ? (isDarkTheme ? Colors.green.shade300 : Colors.green.shade700)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(
          met ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) {
        switch (data.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.userUpdated:
          case AuthChangeEvent.mfaChallengeVerified:
            if (mounted) _refreshMfaStatus();
            break;
          default:
            break;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[ACCOUNT] Auth stream error: $error');
      },
    );
  }

  StreamSubscription<AuthState>? _authSubscription;

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
    _mfaStatusRequest = null;
  }

  _MfaStatus _fallbackMfaStatus() {
    return _MfaStatus(
      hasVerifiedTotp: _lastKnownMfaStatus.hasVerifiedTotp,
      currentSessionVerified: _readAccessTokenClaim('aal') == 'aal2',
      primaryFactorId: _lastKnownMfaStatus.primaryFactorId,
      recoveryCodesRemaining: _lastKnownMfaStatus.recoveryCodesRemaining,
    );
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

  String? _currentUserEmail() {
    final email = Supabase.instance.client.auth.currentUser?.email?.trim();
    if (email == null || email.isEmpty) return null;
    return email;
  }

  Future<_MfaStatus> _loadMfaStatus({bool forceRefresh = false}) {
    if (!forceRefresh && _mfaStatusRequest != null) {
      return _mfaStatusRequest!;
    }

    final request = () async {
      try {
        final factors = await Supabase.instance.client.auth.mfa
            .listFactors()
            .timeout(_mfaStatusTimeout);
        Object? recoveryStatus;
        try {
          recoveryStatus = await Supabase.instance.client
              .rpc('get_mfa_recovery_code_status')
              .timeout(_mfaStatusTimeout);
        } catch (error) {
          print(
            'AccountManagement MFA recovery status refresh skipped: $error',
          );
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
        print('AccountManagement MFA status refresh skipped: $error');
        return _fallbackMfaStatus();
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
      logDebug: (message) => print(message),
    );
  }

  Future<bool> _ensureOnlineForAccountAction(LocalizationState l10n) async {
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

  Future<void> _showChangePasswordDialog(LocalizationState l10n) async {
    final isOnline = await _ensureOnlineForAccountAction(l10n);
    if (!isOnline || !mounted) return;
    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isLoading = false;
    bool obscureNew = true;
    bool obscureConfirm = true;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: MediaQuery.of(context).size.width * 0.6,
                  maxWidth: MediaQuery.of(context).size.width * 0.95,
                ),
                child: AlertDialog(
                  title: Text(l10n.getString('settingsChangePassword')),
                  content: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.75,
                      ),
                      child: Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              l10n.getString('settingsPasswordReauthBody'),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: newPasswordController,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFeatures: const []),
                              decoration: InputDecoration(
                                label: Text(
                                  l10n.getString('settingsNewPassword'),
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    obscureNew
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                  onPressed: () =>
                                      setState(() => obscureNew = !obscureNew),
                                ),
                              ),
                              onChanged: (_) => setState(() {}),
                              obscureText: obscureNew,
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return l10n.getString('authPasswordRequired');
                                }
                                if (!_isValidNewPassword(v)) {
                                  return l10n.getString(
                                    'authPasswordRequirementsTitle',
                                  );
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l10n.getString(
                                        'authPasswordRequirementsTitle',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    _buildPasswordRequirementRow(
                                      context,
                                      met: _passwordHasMinLength(
                                        newPasswordController.text,
                                      ),
                                      label: l10n.getString(
                                        'authPasswordRuleMinLength',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildPasswordRequirementRow(
                                      context,
                                      met: _passwordHasUppercase(
                                        newPasswordController.text,
                                      ),
                                      label: l10n.getString(
                                        'authPasswordRuleUppercase',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildPasswordRequirementRow(
                                      context,
                                      met: _passwordHasLowercase(
                                        newPasswordController.text,
                                      ),
                                      label: l10n.getString(
                                        'authPasswordRuleLowercase',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildPasswordRequirementRow(
                                      context,
                                      met: _passwordHasNumber(
                                        newPasswordController.text,
                                      ),
                                      label: l10n.getString(
                                        'authPasswordRuleNumber',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildPasswordRequirementRow(
                                      context,
                                      met: _passwordHasSpecialCharacter(
                                        newPasswordController.text,
                                      ),
                                      label: l10n.getString(
                                        'authPasswordRuleSpecial',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: confirmPasswordController,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFeatures: const []),
                              decoration: InputDecoration(
                                label: Text(
                                  l10n.getString('settingsConfirmNewPassword'),
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    obscureConfirm
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                  onPressed: () => setState(
                                    () => obscureConfirm = !obscureConfirm,
                                  ),
                                ),
                              ),
                              obscureText: obscureConfirm,
                              validator: (v) {
                                if (v != newPasswordController.text) {
                                  return l10n.getString(
                                    'settingsPasswordMismatch',
                                  );
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(l10n.getString('generalCancel')),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: isLoading
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              setState(() => isLoading = true);
                              try {
                                await Supabase.instance.client.auth.updateUser(
                                  UserAttributes(
                                    password: newPasswordController.text,
                                  ),
                                );
                                if (!mounted) return;
                                Navigator.of(context).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.getString('settingsPasswordChanged'),
                                    ),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              } catch (_) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.getString(
                                        'settingsPasswordChangeFailed',
                                      ),
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              } finally {
                                if (mounted) setState(() => isLoading = false);
                              }
                            },
                      child: isLoading
                          ? const CircularProgressIndicator()
                          : Text(l10n.getString('generalSave')),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showDeleteAccountDialog(LocalizationState l10n) async {
    final isOnline = await _ensureOnlineForAccountAction(l10n);
    if (!isOnline || !mounted) return;
    final canProceed = await _ensureMfaVerifiedForSensitiveAction(l10n);
    if (!canProceed || !mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.getString('settingsDeleteAccount')),
          content: Text(l10n.getString('settingsDeleteAccountConfirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () async {
                final currentContext = context;
                final currentL10n = l10n;
                Navigator.pop(dialogContext);

                final currentUser = Supabase.instance.client.auth.currentUser;
                if (currentUser == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(currentContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          currentL10n.getString('settingsDeleteAccountFailed'),
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                  return;
                }

                final session = Supabase.instance.client.auth.currentSession;
                if (session == null || session.accessToken.isEmpty) {
                  if (mounted) {
                    ScaffoldMessenger.of(currentContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          currentL10n.getString('settingsDeleteAccountFailed'),
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                  return;
                }

                try {
                  final response = await Supabase.instance.client.functions
                      .invoke(
                        'delete-account',
                        headers: {
                          'Authorization': 'Bearer ${session.accessToken}',
                        },
                      );

                  if (response.status == 200 || response.status == 404) {
                    try {
                      SessionService.markExplicitUserSignOut();
                      await CalendarSyncService.clearPersistedCalendarCredentials();
                      // Revoke the account's sessions while the token is still
                      // valid, then sign out locally. The SDK's own server-side
                      // revocation is fired but not awaited so a dropped
                      // connection can never stall the post-deletion cleanup.
                      final user = Supabase.instance.client.auth.currentUser;
                      if (user != null) {
                        try {
                          await Supabase.instance.client
                              .rpc(
                                'revoke_all_user_sessions',
                                params: {'p_user_id': user.id},
                              )
                              .timeout(const Duration(seconds: 4));
                        } catch (e) {
                          print('revoke_all_user_sessions failed: $e');
                        }
                      }
                      try {
                        unawaited(
                          SessionService.deleteFcmToken(),
                        );
                      } catch (_) {}
                      try {
                        unawaited(
                          Supabase.instance.client.auth
                              .signOut(scope: SignOutScope.local)
                              .timeout(const Duration(seconds: 3))
                              .catchError((Object error) {}),
                        );
                      } catch (_) {}
                      final localDb = await LocalDbService.instance;
                      await localDb.clearDatabase();
                    } catch (clearError) {}

                    if (mounted) {
                      final message = response.status == 200
                          ? l10n.getString('settingsAccountDeleted')
                          : l10n.getString('settingsAccountAlreadyDeleted');
                      ScaffoldMessenger.of(currentContext).showSnackBar(
                        SnackBar(
                          content: Text(message),
                          backgroundColor: Colors.green,
                        ),
                      );
                      Navigator.of(
                        currentContext,
                      ).popUntil((route) => route.isFirst);
                    }
                  } else {
                    final errorMessage =
                        response.data?['error'] ??
                        'Unknown error (status: ${response.status})';
                    throw Exception(errorMessage);
                  }
                } catch (e) {
                  if (mounted) {
                    final errorKey =
                        ErrorLocalizationService.getErrorTranslationKey(e);
                    ScaffoldMessenger.of(currentContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${currentL10n.getString('settingsDeleteAccountFailed')}: ${currentL10n.getString(errorKey)}',
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: Text(l10n.getString('settingsDeleteAccount')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isOnline = ref.watch(
      connectivityProvider.select((state) => state.value ?? true),
    );

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('settingsAccountManagement'))),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: theme.shadowColor.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isOnline
                        ? () => _showChangePasswordDialog(l10n)
                        : null,
                    icon: const Icon(Icons.edit),
                    label: Text(l10n.getString('settingsChangePassword')),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isOnline
                        ? () async {
                            final navigator = Navigator.of(context);
                            final online = await _ensureOnlineForAccountAction(
                              l10n,
                            );
                            if (!online || !mounted) return;
                            final canProceed =
                                await _ensureMfaVerifiedForSensitiveAction(
                                  l10n,
                                );
                            if (!canProceed || !mounted) return;
                            await navigator.push(
                              MaterialPageRoute(
                                builder: (context) => const EmailChangeScreen(),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.email),
                    label: Text(l10n.getString('settingsChangeEmailTitle')),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isOnline
                        ? () => _showDeleteAccountDialog(l10n)
                        : null,
                    icon: const Icon(Icons.delete_forever),
                    label: Text(l10n.getString('settingsDeleteAccount')),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                if (!isOnline) ...[
                  const SizedBox(height: 12),
                  Builder(
                    builder: (context) {
                      return SensitiveActionsOfflineNotice(
                        message: l10n.getString(
                          'offlineSensitiveActionsRequireInternet',
                        ),
                      );
                    },
                  ),
                ],
              ],
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
}
