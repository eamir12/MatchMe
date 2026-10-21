import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/authenticator_app_launcher.dart';
import 'package:matchme/services/passkey_auth_service.dart';
import 'package:matchme/services/passkey_client_exception.dart';
import 'package:matchme/services/passkey_client_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/sensitive_action_reauth_service.dart';
import 'package:matchme/utils/otp_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef SensitiveActionSnackBar =
    void Function(String message, {required bool isError});
typedef SensitiveActionLogger = void Function(String message);

class SensitiveActionVerificationStatus {
  const SensitiveActionVerificationStatus({
    required this.primaryFactorId,
    required this.hasVerifiedTotp,
  });

  final String? primaryFactorId;
  final bool hasVerifiedTotp;
}

Future<bool> ensureSensitiveActionVerified({
  required BuildContext context,
  required LocalizationState l10n,
  required bool Function() isMounted,
  required String? Function() getCurrentUserEmail,
  required Future<SensitiveActionVerificationStatus> Function() loadStatus,
  required VoidCallback showProgressOverlay,
  required VoidCallback hideProgressOverlay,
  required VoidCallback refreshStatus,
  required SensitiveActionSnackBar showSnackBar,
  SensitiveActionLogger? logDebug,
}) async {
  final email = getCurrentUserEmail()?.trim();
  final hasEmailFallback = email != null && email.isNotEmpty;
  showProgressOverlay();

  try {
    final statusFuture = loadStatus();
    final isPasskeySupportedFuture = hasEmailFallback
        ? PasskeyClientService.isAuthenticationSupported()
        : Future<bool>.value(false);

    final status = await statusFuture;
    if (!isMounted()) return false;

    final factorId = status.primaryFactorId?.trim();
    final hasAuthenticator =
        status.hasVerifiedTotp && factorId != null && factorId.isNotEmpty;
    final canAttemptPasskey =
        await isPasskeySupportedFuture && hasEmailFallback;
    if (!isMounted()) return false;

    if (!hasAuthenticator && !canAttemptPasskey && !hasEmailFallback) {
      showSnackBar(
        l10n.getString('settingsSensitiveActionRequiresMfaSetup'),
        isError: true,
      );
      return false;
    }

    if (canAttemptPasskey) {
      final passkeyResult = await _verifySensitiveActionWithPasskey(
        l10n,
        email: email,
        isMounted: isMounted,
        hideProgressOverlay: hideProgressOverlay,
        showSnackBar: showSnackBar,
      );
      if (!isMounted()) return false;
      if (passkeyResult == _SensitiveActionPasskeyResult.verified) {
        refreshStatus();
        return true;
      }
    }

    hideProgressOverlay();

    if (hasAuthenticator || hasEmailFallback) {
      if (!context.mounted) return false;
      final verified =
          await showDialog<bool>(
            context: context,
            useRootNavigator: false,
            barrierDismissible: false,
            builder: (dialogContext) => SensitiveActionVerificationDialog(
              l10n: l10n,
              factorId: factorId ?? '',
              email: email,
              title: l10n.getString('settingsMfaVerifySensitiveAction'),
              body: l10n.getString('settingsMfaVerifySensitiveActionBody'),
              confirmLabel: l10n.getString('generalContinue'),
              logDebug: logDebug,
            ),
          ) ??
          false;

      if (verified) {
        refreshStatus();
      }
      return verified;
    }

    showSnackBar(
      l10n.getString('settingsSensitiveActionRequiresMfaSetup'),
      isError: true,
    );
    return false;
  } finally {
    hideProgressOverlay();
  }
}

Future<_SensitiveActionPasskeyResult> _verifySensitiveActionWithPasskey(
  LocalizationState l10n, {
  required String email,
  required bool Function() isMounted,
  required VoidCallback hideProgressOverlay,
  required SensitiveActionSnackBar showSnackBar,
}) async {
  try {
    final startResult = await PasskeyAuthService.startAuthentication(
      email: email,
    );
    if (!startResult.hasPublicKeyOptions) {
      return _SensitiveActionPasskeyResult.fallbackToAlternative;
    }

    hideProgressOverlay();
    final assertion = await PasskeyClientService.getAuthenticationAssertion(
      publicKeyOptions: startResult.publicKeyOptions!,
    );
    await PasskeyAuthService.finishAuthentication(
      assertion: assertion,
      email: email,
      requestId: startResult.requestId,
    );
    return _SensitiveActionPasskeyResult.verified;
  } catch (error) {
    final message = await _mapPasskeySensitiveActionError(
      error,
      l10n,
      email: email,
    );
    if (!isMounted()) return _SensitiveActionPasskeyResult.abort;
    if (!_shouldSilentlyFallbackFromPasskey(error)) {
      showSnackBar(message, isError: true);
    }
    return _SensitiveActionPasskeyResult.fallbackToAlternative;
  }
}

Future<String> _mapPasskeySensitiveActionError(
  Object error,
  LocalizationState l10n, {
  required String email,
}) async {
  if (error is PasskeyClientException) {
    switch (error.code) {
      case 'passkey_not_found':
        return l10n.getString('authPasskeyNotFound');
      case 'cancelled':
      case 'user_cancelled':
        return l10n.getString('authPasskeyCancelled');
      case 'not_supported':
        return l10n.getString('authPasskeyNotSupported');
      case 'security_error':
        return l10n.getString('authPasskeySecurityError');
      default:
        return error.message;
    }
  }
  if (error is PasskeyAuthException) {
    switch (error.code) {
      case 'credential_not_found':
        await PasskeyAuthService.cachePasskeyAvailabilityForEmail(email, false);
        return l10n.getString('authPasskeyNotFound');
      case 'config_invalid':
        return l10n.getString('authPasskeyNotConfigured');
      case 'bad_request':
        return error.message;
      default:
        return error.message;
    }
  }
  return l10n.getString('settingsMfaVerificationFailed');
}

bool _isPasskeySensitiveActionCancelled(Object error) {
  if (error is PasskeyClientException) {
    return error.code == 'cancelled' || error.code == 'user_cancelled';
  }
  return false;
}

bool _shouldSilentlyFallbackFromPasskey(Object error) {
  if (_isPasskeySensitiveActionCancelled(error)) {
    return true;
  }
  if (error is PasskeyClientException) {
    return error.code == 'passkey_not_found' || error.code == 'not_supported';
  }
  if (error is PasskeyAuthException) {
    return error.code == 'credential_not_found';
  }
  return false;
}

enum _SensitiveActionPasskeyResult { verified, fallbackToAlternative, abort }

class SensitiveActionVerificationDialog extends StatefulWidget {
  const SensitiveActionVerificationDialog({
    super.key,
    required this.l10n,
    required this.factorId,
    required this.email,
    required this.title,
    required this.body,
    required this.confirmLabel,
    this.logDebug,
  });

  final LocalizationState l10n;
  final String factorId;
  final String? email;
  final String title;
  final String body;
  final String confirmLabel;
  final SensitiveActionLogger? logDebug;

  @override
  State<SensitiveActionVerificationDialog> createState() =>
      _SensitiveActionVerificationDialogState();
}

class _SensitiveActionVerificationDialogState
    extends State<SensitiveActionVerificationDialog> {
  final TextEditingController _codeController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _hasSentEmailCode = false;
  String? _errorText;
  Timer? _countdownTimer;
  _SensitiveActionVerificationMethod _method =
      _SensitiveActionVerificationMethod.authenticator;

  bool get _hasAuthenticatorOption => widget.factorId.trim().isNotEmpty;
  bool get _hasEmailOption => (widget.email?.trim().isNotEmpty ?? false);

  bool get _canOpenAuthenticatorApp => !kIsWeb && _hasAuthenticatorOption;

  /// Seconds until the user may explicitly resend the email code.
  /// GoTrue only honors the LATEST nonce, so rapid resends orphan the code
  /// in the inbox; the button counts down instead.
  int get _resendCooldownRemainingSeconds {
    final lastSent = SensitiveActionReauthService.lastEmailCodeSentAt;
    if (lastSent == null) return 0;
    final elapsed = DateTime.now().difference(lastSent).inSeconds;
    final remaining =
        SensitiveActionReauthService.resendCooldown.inSeconds - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  @override
  void initState() {
    super.initState();
    _method = _preferredMethod();
    // Ticks the resend-countdown label while the dialog is open.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_method == _SensitiveActionVerificationMethod.emailCode &&
          _hasSentEmailCode &&
          SensitiveActionReauthService.lastEmailCodeSentAt != null) {
        setState(() {});
      }
    });
    if (_method == _SensitiveActionVerificationMethod.emailCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _sendEmailCode(autoTriggered: true);
        }
      });
    }
    // Do NOT prematurely mark email as sent based on a local cache window.
    // The window only tracks expiry; the actual send must go through the
    // backend so the user always receives a fresh email. Previously this
    // caused the dialog to show "enter code sent to {email}" without ever
    // triggering a network request.
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  _SensitiveActionVerificationMethod _preferredMethod({
    _SensitiveActionVerificationMethod? excluding,
  }) {
    if (excluding != _SensitiveActionVerificationMethod.authenticator &&
        _hasAuthenticatorOption) {
      return _SensitiveActionVerificationMethod.authenticator;
    }
    if (excluding != _SensitiveActionVerificationMethod.emailCode &&
        _hasEmailOption) {
      return _SensitiveActionVerificationMethod.emailCode;
    }
    return _hasAuthenticatorOption
        ? _SensitiveActionVerificationMethod.authenticator
        : _SensitiveActionVerificationMethod.emailCode;
  }

  String _switchLabelFor(_SensitiveActionVerificationMethod method) =>
      switch (method) {
        _SensitiveActionVerificationMethod.authenticator =>
          'settingsMfaUseAuthenticatorCode',
        _SensitiveActionVerificationMethod.emailCode =>
          'settingsMfaUseEmailCode',
      };

  void _switchMethod(_SensitiveActionVerificationMethod method) {
    if (_isLoading) return;
    setState(() {
      _method = method;
      _codeController.clear();
      _hasSentEmailCode = false;
      _errorText = null;
    });
    if (method == _SensitiveActionVerificationMethod.emailCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _sendEmailCode(autoTriggered: true);
        }
      });
    }
  }

  Future<void> _openAuthenticatorApp() async {
    if (!_canOpenAuthenticatorApp) return;

    final launched = await AuthenticatorAppLauncher.open();
    if (launched || !mounted) return;

    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          widget.l10n.getString('settingsMfaOpenAuthenticatorFailed'),
        ),
      ),
    );
  }

  String? get _maskedEmail => _maskEmail(widget.email);

  Future<void> _sendEmailCode({
    bool autoTriggered = false,
    bool forceResend = false,
  }) async {
    if (_isLoading) return;
    if (autoTriggered && !forceResend) {
      // Never mint a second nonce automatically: GoTrue only honors the
      // LATEST reauthentication nonce, so an automatic re-send (dialog
      // reopen, method switch) would silently invalidate the code the user
      // may already be reading in their inbox. Reuse the outstanding code
      // for the same account instead.
      final currentUser = Supabase.instance.client.auth.currentUser;
      if (SensitiveActionReauthService.hasOutstandingCodeFor(
        userId: currentUser?.id,
        email: widget.email,
      )) {
        widget.logDebug?.call(
          '[SensitiveActionVerification] Reusing outstanding email code; '
          'skipping auto re-send.',
        );
        if (!mounted) return;
        setState(() {
          _hasSentEmailCode = true;
          _errorText = null;
        });
        return;
      }
    }
    setState(() {
      _isLoading = true;
      _errorText = null;
    });
    try {
      // Get the language from the localization provider
      final language = widget.l10n.currentLocale.languageCode;
      final result = await SensitiveActionReauthService.requestEmailCode(
        forceResend: forceResend,
        language: language,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _hasSentEmailCode = true;
        _errorText = null;
      });
      widget.logDebug?.call(
        '[SensitiveActionVerification] Email code sent '
        '(auto=$autoTriggered) at ${DateTime.now().toIso8601String()} '
        'to ${_maskedEmail ?? 'user'}.',
      );

      final maskedEmail = _maskedEmail;
      if (result.sentFreshly || !autoTriggered) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              maskedEmail == null || maskedEmail.isEmpty
                  ? widget.l10n.getString('settingsPasswordReauthSentGeneric')
                  : widget.l10n.getString(
                      'settingsMfaEmailCodeSent',
                      params: {'email': maskedEmail},
                    ),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (error, stackTrace) {
      widget.logDebug?.call(
        '[SensitiveActionVerification] Email reauth send failed: '
        '$error\n$stackTrace',
      );
      if (!mounted) return;
      // Mirror password-reset error handling: use ErrorLocalizationService and
      // include the reason, and show a red snackbar (not green) like
      // password_reset does when `resetPasswordForEmail` fails.
      final key = ErrorLocalizationService.getErrorTranslationKey(error);
      final localized = widget.l10n.getString(key);
      // If mapping is generic unexpected but we have a concrete message, append it
      String errorText = localized;
      if (key == 'authUnexpectedError' &&
          error is SensitiveActionReauthException &&
          error.message.trim().isNotEmpty) {
        errorText =
            '${widget.l10n.getString('settingsMfaEmailCodeSendFailed')}: ${error.message}';
      } else if (key == 'authUnexpectedError' &&
          error.toString().trim().isNotEmpty) {
        errorText =
            '${widget.l10n.getString('settingsMfaEmailCodeSendFailed')}: $error';
      } else if (key == 'authRateLimitExceeded') {
        // Keep the rate-limit message specific so the user understands why
        errorText = localized;
      } else if (localized == widget.l10n.getString('authUnexpectedError') &&
          error is SensitiveActionReauthException) {
        errorText = '$localized: ${error.message}';
      }
      setState(() {
        _hasSentEmailCode = false;
        _errorText = errorText;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(errorText), backgroundColor: Colors.red),
      );
      if (!autoTriggered) {
        // Still rethrow so ensureSensitiveActionVerified can react, but the
        // dialog stays open and shows the inline error plus the red banner.
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      if (_method == _SensitiveActionVerificationMethod.authenticator) {
        final factorId = widget.factorId.trim();
        if (factorId.isEmpty) {
          throw StateError('Missing authenticator factor');
        }
        await Supabase.instance.client.auth.mfa.challengeAndVerify(
          factorId: factorId,
          code: OtpUtils.sanitizeCode(_codeController.text),
        );
      } else if (_method == _SensitiveActionVerificationMethod.emailCode) {
        final email = widget.email?.trim() ?? '';
        if (email.isEmpty) {
          throw StateError('Missing reauthentication email');
        }
        if (!_hasSentEmailCode) {
          await _sendEmailCode();
          return;
        }
        await SensitiveActionReauthService.verifyEmailCode(
          email: email,
          token: OtpUtils.sanitizeCode(_codeController.text),
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      final detail = error is SensitiveActionReauthException
          ? 'code=${error.code} status=${error.statusCode} '
          : '';
      widget.logDebug?.call(
        '[SensitiveActionVerification] Verification failed: '
        '$detail$error\n$stackTrace',
      );
      if (!mounted) return;
      setState(() {
        if (_method == _SensitiveActionVerificationMethod.authenticator) {
          _errorText = widget.l10n.getString('settingsMfaVerificationFailed');
        } else if (!_hasSentEmailCode) {
          _errorText = widget.l10n.getString('settingsMfaEmailCodeSendFailed');
        } else if (error is SensitiveActionReauthException &&
            (error.code == 'otp_expired' || error.code == 'invalid_code')) {
          // Distinguish expired vs incorrect via the localized auth strings
          // instead of the generic "Invalid or expired code".
          final key = ErrorLocalizationService.getErrorTranslationKey(error);
          _errorText = widget.l10n.getString(key);
        } else {
          _errorText = widget.l10n.getString(
            'settingsMfaEmailCodeVerifyFailed',
          );
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      scrollable: true,
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _method == _SensitiveActionVerificationMethod.authenticator
                  ? widget.body
                  : _hasSentEmailCode
                  ? ((_maskedEmail == null || _maskedEmail!.isEmpty)
                        ? widget.l10n.getString(
                            'settingsPasswordReauthSentGeneric',
                          )
                        : widget.l10n.getString(
                            'settingsMfaEmailCodeBody',
                            params: {'email': _maskedEmail!},
                          ))
                  : widget.l10n.getString('settingsMfaEmailCodeSendBody'),
            ),
            if (_method == _SensitiveActionVerificationMethod.authenticator &&
                _canOpenAuthenticatorApp) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _isLoading ? null : _openAuthenticatorApp,
                icon: const Icon(Icons.open_in_new),
                label: Text(
                  widget.l10n.getString('settingsMfaOpenAuthenticator'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(
                label: Text(
                  widget.l10n.getString(
                    _method == _SensitiveActionVerificationMethod.authenticator
                        ? 'settingsMfaCode'
                        : 'settingsMfaEmailCode',
                  ),
                ),
                errorText: _errorText,
              ),
              validator: (value) {
                final code = OtpUtils.sanitizeCode(value ?? '');
                if (_method ==
                    _SensitiveActionVerificationMethod.authenticator) {
                  if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                    return widget.l10n.getString('settingsMfaEnterCode');
                  }
                  return null;
                }
                if (_method == _SensitiveActionVerificationMethod.emailCode) {
                  if (!_hasSentEmailCode) {
                    return null;
                  }
                  if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                    return widget.l10n.getString('settingsMfaEmailCodeEnter');
                  }
                  return null;
                }
                return null;
              },
            ),
            if (_hasAuthenticatorOption && _hasEmailOption) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Builder(
                  builder: (context) {
                    final returnMethod = _preferredMethod(
                      excluding: _SensitiveActionVerificationMethod.emailCode,
                    );
                    final targetMethod =
                        _method == _SensitiveActionVerificationMethod.emailCode
                        ? returnMethod
                        : _SensitiveActionVerificationMethod.emailCode;
                    return TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => _switchMethod(targetMethod),
                      child: Text(
                        widget.l10n.getString(_switchLabelFor(targetMethod)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(widget.l10n.getString('generalCancel')),
        ),
        if (_method == _SensitiveActionVerificationMethod.emailCode &&
            _hasSentEmailCode)
          Builder(
            builder: (context) {
              // Cooldown: each explicit resend mints a fresh server nonce and
              // invalidates the code in the inbox, so rapid taps guarantee
              // "correct code rejected". Count down instead of re-sending.
              final remaining = _resendCooldownRemainingSeconds;
              final coolingDown = remaining > 0;
              return TextButton(
                onPressed: (_isLoading || coolingDown)
                    ? null
                    : () => _sendEmailCode(forceResend: true),
                child: Text(
                  coolingDown
                      ? widget.l10n.getPluralString(
                          'settingsMfaEmailCodeResendIn',
                          remaining,
                          countParam: 'seconds',
                        )
                      : widget.l10n.getString('settingsMfaEmailCodeResend'),
                ),
              );
            },
          ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _method == _SensitiveActionVerificationMethod.emailCode &&
                          !_hasSentEmailCode
                      ? widget.l10n.getString('settingsMfaEmailCodeSend')
                      : widget.confirmLabel,
                ),
        ),
      ],
    );
  }
}

String? _maskEmail(String? email) {
  final normalized = email?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final parts = normalized.split('@');
  if (parts.length != 2) return normalized;
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

enum _SensitiveActionVerificationMethod { authenticator, emailCode }
