import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/signup_email_otp_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/utils/otp_utils.dart';
import 'package:matchme/widgets/safe_text.dart';

class SignupEmailCodeScreen extends ConsumerStatefulWidget {
  const SignupEmailCodeScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<SignupEmailCodeScreen> createState() =>
      _SignupEmailCodeScreenState();
}

class _SignupEmailCodeScreenState extends ConsumerState<SignupEmailCodeScreen> {
  final TextEditingController _codeController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorText;
  DateTime? _lastResendAt;
  Timer? _cooldownTimer;

  /// Supabase mints a fresh OTP on every resend and only the latest verifies,
  /// so rapid resends orphan the code in the inbox. Enforce a 60s cooldown.
  static const int _resendCooldownSeconds = 60;

  int get _resendCooldownRemainingSeconds {
    final last = _lastResendAt;
    if (last == null) return 0;
    final remaining =
        _resendCooldownSeconds - DateTime.now().difference(last).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  bool get _canResend =>
      !_isVerifying && !_isResending && _resendCooldownRemainingSeconds == 0;

  @override
  void initState() {
    super.initState();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_resendCooldownRemainingSeconds > 0) setState(() {});
    });
  }

  String get _normalizedEmail => widget.email.trim().toLowerCase();

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verifyCode() async {
    if (!_formKey.currentState!.validate()) return;

    final l10n = ref.read(localizationProvider);

    setState(() {
      _isVerifying = true;
      _errorText = null;
    });

    try {
      await SignupEmailOtpService.verifySignupCode(
        email: _normalizedEmail,
        code: _codeController.text,
      );

      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on SignupEmailOtpException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = _mapVerificationError(error, l10n);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = l10n.getString('authSignupCodeVerifyFailed');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _resendCode() async {
    final l10n = ref.read(localizationProvider);

    setState(() {
      _isResending = true;
      _errorText = null;
    });

    try {
      await SignupEmailOtpService.resendSignupCode(email: _normalizedEmail);
      if (!mounted) return;
      setState(() {
        _lastResendAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'authSignupCodeResent',
              params: {'email': _maskedEmail(_normalizedEmail)},
            ),
          ),
          backgroundColor: Colors.green,
        ),
      );
    } on SignupEmailOtpException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = _mapResendError(error, l10n);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = l10n.getString('authSignupCodeResendFailed');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isResending = false;
        });
      }
    }
  }

  String _mapVerificationError(
    SignupEmailOtpException error,
    LocalizationState l10n,
  ) {
    switch (error.code) {
      case 'otp_expired':
        return l10n.getString('authSignupCodeExpired');
      case 'invalid_otp':
      case 'bad_code_verifier':
      case 'bad_otp':
        return l10n.getString('authSignupCodeInvalid');
      default:
        // Map generic error to localization key
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        return l10n.getString(errorKey);
    }
  }

  String _mapResendError(
    SignupEmailOtpException error,
    LocalizationState l10n,
  ) {
    switch (error.code) {
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
      case 'rate_limited':
        return l10n.getString('authSignupCodeRateLimited');
      default:
        // Map generic error to localization key
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        return l10n.getString(errorKey);
    }
  }

  String _maskedEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return email;

    final local = parts[0];
    final domain = parts[1];
    if (local.length <= 2) {
      return '${local[0]}*@$domain';
    }

    return '${local[0]}${'*' * (local.length - 2)}${local[local.length - 1]}@$domain';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('authSignupCodeTitle'))),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.mark_email_read_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.getString('authSignupCodeTitle'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.getString(
                        'authSignupCodeBody',
                        params: {'email': _maskedEmail(_normalizedEmail)},
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.getString('authSignupCodeLabel'),
                        hintText: l10n.getString('authSignupCodeHint'),
                        errorText: _errorText,
                      ),
                      onFieldSubmitted: (_) => _verifyCode(),
                      validator: (value) {
                        final code = OtpUtils.sanitizeCode(value ?? '');
                        if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                          return l10n.getString('authSignupCodeEnterPrompt');
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _isVerifying || _isResending
                          ? null
                          : _verifyCode,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: _isVerifying
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.getString('authSignupCodeVerify')),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _canResend ? _resendCode : null,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: _isResending
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : _resendCooldownRemainingSeconds > 0
                          ? Text(
                              l10n.getString(
                                'settingsMfaEmailCodeResendIn',
                                params: {
                                  'seconds': '$_resendCooldownRemainingSeconds',
                                },
                              ),
                            )
                          : Text(l10n.getString('authSignupCodeResend')),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _isVerifying || _isResending
                          ? null
                          : () => Navigator.of(context).maybePop(),
                      child: Text(l10n.getString('authSignupCodeBackToLogin')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
