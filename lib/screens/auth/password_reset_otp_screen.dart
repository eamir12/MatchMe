import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/password_reset_service.dart';
import 'package:matchme/utils/otp_utils.dart';
import 'package:matchme/widgets/safe_text.dart';

class PasswordResetOtpScreen extends ConsumerStatefulWidget {
  const PasswordResetOtpScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<PasswordResetOtpScreen> createState() =>
      _PasswordResetOtpScreenState();
}

class _PasswordResetOtpScreenState
    extends ConsumerState<PasswordResetOtpScreen> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final GlobalKey<FormState> _otpFormKey = GlobalKey<FormState>();
  final GlobalKey<FormState> _passwordFormKey = GlobalKey<FormState>();

  bool _isVerifying = false;
  bool _isResending = false;
  bool _isUpdating = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorText;
  bool _otpVerified = false;
  DateTime? _lastResendAt;
  Timer? _cooldownTimer;

  /// Supabase mints a fresh recovery OTP on every request and only the
  /// latest verifies, so rapid resends orphan the code in the inbox.
  /// Enforce a 60s cooldown between explicit resends.
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

  bool _passwordHasMinLength(String v) => v.length >= 8;
  bool _passwordHasUppercase(String v) => v.contains(RegExp(r'[A-Z]'));
  bool _passwordHasLowercase(String v) => v.contains(RegExp(r'[a-z]'));
  bool _passwordHasNumber(String v) => v.contains(RegExp(r'\d'));
  bool _passwordHasSpecialCharacter(String v) =>
      v.contains(RegExp(r'[@$!%*?&]'));

  bool _isPasswordValid(String v) =>
      _passwordHasMinLength(v) &&
      _passwordHasUppercase(v) &&
      _passwordHasLowercase(v) &&
      _passwordHasNumber(v) &&
      _passwordHasSpecialCharacter(v);

  String get _normalizedEmail => widget.email.trim().toLowerCase();

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Widget _buildPasswordRequirementRow(
    BuildContext context, {
    required bool met,
    required String label,
  }) {
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Future<void> _verifyOtp() async {
    if (!_otpFormKey.currentState!.validate()) return;
    setState(() {
      _isVerifying = true;
      _errorText = null;
    });
    final l10n = ref.read(localizationProvider);
    try {
      await PasswordResetService.verifyRecoveryOtp(
        email: _normalizedEmail,
        code: _codeController.text,
      );
      if (!mounted) return;
      setState(() {
        _otpVerified = true;
        _errorText = null;
      });
    } on PasswordResetException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = _mapVerificationError(error, l10n);
      });
    } catch (error) {
      if (!mounted) return;
      final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
      setState(() {
        _errorText = ref.read(localizationProvider).getString(errorKey);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _updatePassword() async {
    if (!_passwordFormKey.currentState!.validate()) return;
    final l10n = ref.read(localizationProvider);
    setState(() {
      _isUpdating = true;
      _errorText = null;
    });
    try {
      await PasswordResetService.updatePassword(
        newPassword: _passwordController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('authPasswordResetSuccessMessage')),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on PasswordResetException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = _mapVerificationError(error, l10n);
      });
    } catch (error) {
      if (!mounted) return;
      final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
      setState(() {
        _errorText = ref.read(localizationProvider).getString(errorKey);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _resendCode() async {
    setState(() {
      _isResending = true;
      _errorText = null;
    });

    final l10n = ref.read(localizationProvider);

    try {
      final lang = ref.read(localizationProvider).currentLocale.languageCode;
      await PasswordResetService.resendPasswordResetOtp(
        email: _normalizedEmail,
        language: lang,
      );
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
    } on PasswordResetException catch (error) {
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
    PasswordResetException error,
    LocalizationState l10n,
  ) {
    switch (error.code) {
      case 'otp_expired':
        return l10n.getString('authSignupCodeExpired');
      case 'invalid_otp':
      case 'bad_code_verifier':
      case 'bad_otp':
        return l10n.getString('authSignupCodeInvalid');
      case 'user_not_found':
        return l10n.getString('authUserNotFound');
      default:
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        return l10n.getString(errorKey);
    }
  }

  String _mapResendError(PasswordResetException error, LocalizationState l10n) {
    switch (error.code) {
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
      case 'rate_limited':
        return l10n.getString('authSignupCodeRateLimited');
      default:
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        return l10n.getString(errorKey);
    }
  }

  String _maskedEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return email;
    final local = parts[0];
    final domain = parts[1];
    if (local.length <= 2) return '${local[0]}*@$domain';
    return '${local[0]}${'*' * (local.length - 2)}${local[local.length - 1]}@$domain';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(l10n.getString('authResetPasswordTitle')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_otpVerified) {
              setState(() {
                _otpVerified = false;
                _errorText = null;
              });
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _otpVerified
                  ? _buildPasswordStage(l10n)
                  : _buildOtpStage(l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOtpStage(LocalizationState l10n) {
    return Form(
      key: _otpFormKey,
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
            l10n.getString('authResetPasswordOtpTitle'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.getString(
              'authResetPasswordOtpBody',
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
              prefixIcon: const Icon(Icons.pin_outlined),
            ),
            onFieldSubmitted: (_) => _verifyOtp(),
            validator: (value) {
              final code = OtpUtils.sanitizeCode(value ?? '');
              if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                return l10n.getString('authSignupCodeEnterPrompt');
              }
              return null;
            },
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 16),
            _buildErrorBox(_errorText!),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _isVerifying || _isResending ? null : _verifyOtp,
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
                      params: {'seconds': '$_resendCooldownRemainingSeconds'},
                    ),
                  )
                : Text(l10n.getString('authSignupCodeResend')),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isVerifying || _isResending
                ? null
                : () => Navigator.of(context).maybePop(),
            child: Text(l10n.getString('generalCancel')),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordStage(LocalizationState l10n) {
    return Form(
      key: _passwordFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.lock_reset_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            l10n.getString('authSetNewPassword'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.getString('authSetNewPasswordMessage'),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 24),
          // Show verified badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.check_circle,
                  color: Colors.green.shade700,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '${l10n.getString('authSignupCodeVerify')} ✓',
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: l10n.getString('authNewPassword'),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              if (v == null || v.isEmpty) {
                return l10n.getString('authPasswordRequired');
              }
              if (!_isPasswordValid(v)) {
                return l10n.getString('authPasswordRequirementsTitle');
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString('authPasswordRequirementsTitle'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildPasswordRequirementRow(
                    context,
                    met: _passwordHasMinLength(_passwordController.text),
                    label: l10n.getString('authPasswordRuleMinLength'),
                  ),
                  const SizedBox(height: 6),
                  _buildPasswordRequirementRow(
                    context,
                    met: _passwordHasUppercase(_passwordController.text),
                    label: l10n.getString('authPasswordRuleUppercase'),
                  ),
                  const SizedBox(height: 6),
                  _buildPasswordRequirementRow(
                    context,
                    met: _passwordHasLowercase(_passwordController.text),
                    label: l10n.getString('authPasswordRuleLowercase'),
                  ),
                  const SizedBox(height: 6),
                  _buildPasswordRequirementRow(
                    context,
                    met: _passwordHasNumber(_passwordController.text),
                    label: l10n.getString('authPasswordRuleNumber'),
                  ),
                  const SizedBox(height: 6),
                  _buildPasswordRequirementRow(
                    context,
                    met: _passwordHasSpecialCharacter(_passwordController.text),
                    label: l10n.getString('authPasswordRuleSpecial'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirm,
            decoration: InputDecoration(
              labelText: l10n.getString('settingsConfirmNewPassword'),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
            validator: (v) {
              if (v != _passwordController.text) {
                return l10n.getString('settingsPasswordMismatch');
              }
              return null;
            },
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 16),
            _buildErrorBox(_errorText!),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _isUpdating ? null : _updatePassword,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            child: _isUpdating
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.getString('authResetPassword')),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isUpdating
                ? null
                : () => Navigator.of(context).maybePop(),
            child: Text(l10n.getString('generalCancel')),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBox(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
