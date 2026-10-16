import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/email_change_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/utils/otp_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/theme/app_button_styles.dart';
import 'package:matchme/widgets/safe_text.dart';

class EmailChangeScreen extends ConsumerStatefulWidget {
  const EmailChangeScreen({super.key});

  @override
  ConsumerState<EmailChangeScreen> createState() => _EmailChangeScreenState();
}

class _EmailChangeScreenState extends ConsumerState<EmailChangeScreen> {
  late TextEditingController _newEmailController;
  late TextEditingController _verificationCodeController;
  late Timer _countdownTimer;

  // Step tracking: 1 = New email input, 2 = Code verification
  int _currentStep = 1;
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;
  DateTime? _codeExpiresAt;

  // Email validation
  bool _isEmailValid = false;
  bool _isEmailAvailable = false;
  bool _isCheckingEmail = false;
  Timer? _emailValidationTimer;

  @override
  void initState() {
    super.initState();
    _newEmailController = TextEditingController();
    _verificationCodeController = TextEditingController();
    _checkMfaStatus();
    _startCountdownTimer();
    _setupEmailValidation();
  }

  @override
  void dispose() {
    _newEmailController.dispose();
    _verificationCodeController.dispose();
    _countdownTimer.cancel();
    _emailValidationTimer?.cancel();
    super.dispose();
  }

  void _setupEmailValidation() {
    _newEmailController.addListener(_onEmailChanged);
  }

  void _onEmailChanged() {
    // Cancel previous timer
    _emailValidationTimer?.cancel();

    final email = _newEmailController.text.trim();
    final currentUser = Supabase.instance.client.auth.currentUser;
    final currentEmail = currentUser?.email?.trim().toLowerCase() ?? '';

    // Check if email matches current email
    if (email.toLowerCase() == currentEmail) {
      setState(() {
        _isEmailValid = false;
        _isEmailAvailable = false;
        _isCheckingEmail = false;
      });
      return;
    }

    final isValid = _isValidEmail(email);

    setState(() {
      _isEmailValid = isValid;
      _isEmailAvailable =
          false; // Start as unavailable, only set true after check
      _isCheckingEmail = isValid; // Show checking state while validating
    });

    if (isValid && email.isNotEmpty) {
      // Debounce the availability check - wait 500ms after user stops typing
      _emailValidationTimer = Timer(const Duration(milliseconds: 500), () {
        _checkEmailAvailability(email);
      });
    }
  }

  Future<void> _checkEmailAvailability(String email) async {
    setState(() {
      _isCheckingEmail = true;
    });

    try {
      final available = await EmailChangeService.isEmailAvailable(email);
      if (mounted) {
        setState(() {
          _isEmailAvailable = available;
          _isCheckingEmail = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isCheckingEmail = false;
        });
      }
    }
  }

  void _startCountdownTimer() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _codeExpiresAt != null) {
        setState(() {
          // Trigger rebuild to update the countdown display
        });
      }
    });
  }

  void _checkMfaStatus() {
    // Verification happens in settings screen before navigating here
    // Always start at step 1 (email input)
    _currentStep = 1;
  }

  Future<void> _sendNewEmailCode() async {
    final newEmail = _newEmailController.text.trim();

    if (newEmail.isEmpty) {
      setState(
        () =>
            _errorMessage = _getTranslation('settingsChangeEmailInvalidEmail'),
      );
      return;
    }

    if (!_isValidEmail(newEmail)) {
      setState(
        () =>
            _errorMessage = _getTranslation('settingsChangeEmailInvalidEmail'),
      );
      return;
    }

    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser?.email?.toLowerCase() == newEmail.toLowerCase()) {
      setState(
        () => _errorMessage = _getTranslation('settingsChangeEmailSameEmail'),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final localization = ref.read(localizationProvider);
      final result = await EmailChangeService.requestEmailChangeCode(
        newEmail: newEmail,
        language: localization.currentLocale.languageCode,
      );

      if (mounted) {
        setState(() {
          _codeExpiresAt = result.expiresAt;
          _currentStep = 2;
          _isLoading = false;
          _successMessage = result.message;
        });
      }
    } on EmailChangeException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _verifyAndCompleteEmailChange() async {
    final code = OtpUtils.sanitizeCode(_verificationCodeController.text);
    final newEmail = _newEmailController.text.trim();

    if (code.isEmpty) {
      setState(
        () => _errorMessage = _getTranslation('settingsChangeEmailInvalidCode'),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      // Verify the code (newEmail passed explicitly so verification survives
      // app restarts and does not depend on in-memory state).
      await EmailChangeService.verifyEmailChangeCode(
        code: code,
        newEmail: newEmail,
      );

      // Complete the email change
      final result = await EmailChangeService.completeEmailChange(
        code: code,
        newEmail: newEmail,
      );

      if (mounted) {
        setState(() {
          _successMessage = result.message;
          _isLoading = false;
        });

        // Show success and close after delay
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } on EmailChangeException catch (e) {
      if (mounted) {
        final key = ErrorLocalizationService.getErrorTranslationKey(e);
        final localized = _getTranslation(key);
        setState(() {
          // Fall back to the server message only when no translation exists.
          _errorMessage = localized == key ? e.message : localized;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _resendCode() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final localization = ref.read(localizationProvider);
      final newEmail = _newEmailController.text.trim();

      final result = await EmailChangeService.requestEmailChangeCode(
        newEmail: newEmail,
        language: localization.currentLocale.languageCode,
      );

      if (mounted) {
        setState(() {
          _codeExpiresAt = result.expiresAt;
          _isLoading = false;
          _successMessage = _getTranslation('settingsChangeEmailCodeResent');
        });
      }
    } on EmailChangeException catch (e) {
      if (mounted) {
        final key = ErrorLocalizationService.getErrorTranslationKey(e);
        final localized = _getTranslation(key);
        setState(() {
          _errorMessage = localized == key ? e.message : localized;
          _isLoading = false;
        });
      }
    }
  }

  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    return emailRegex.hasMatch(email);
  }

  String _getTranslation(String key) {
    final localization = ref.read(localizationProvider);
    return localization.strings[key] ?? key;
  }

  String _getTimeRemaining() {
    if (_codeExpiresAt == null) return '';
    final remaining = _codeExpiresAt!.difference(DateTime.now());
    if (remaining.isNegative) return '';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(localizationProvider);
    final currentUser = Supabase.instance.client.auth.currentUser;

    return Scaffold(
      appBar: AppBar(title: ShrinkText(_getTranslation('settingsChangeEmailTitle'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Text(
              _getTranslation('settingsChangeEmailDescription'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            // Step 1: New Email Input
            if (_currentStep >= 1) ...[
              TextFormField(
                enabled: false,
                initialValue: currentUser?.email ?? '',
                decoration: InputDecoration(
                  labelText: _getTranslation('settingsChangeEmailCurrentEmail'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _newEmailController,
                enabled: !_isLoading && _currentStep == 1,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: _getTranslation('settingsChangeEmailNewEmail'),
                  hintText: _getTranslation('settingsChangeEmailNewEmailHint'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  suffixIcon: _buildEmailValidationIcon(),
                ),
              ),
              const SizedBox(height: 8),
              // Fixed height error text area to prevent layout jumping
              SizedBox(
                height: 20,
                child: _getEmailErrorText() != null
                    ? Text(
                        _getEmailErrorText()!,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                      )
                    : null,
              ),
              Text(
                _getTranslation('settingsChangeEmailDescription'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              ),
            ],

            // Step 2: Code Verification
            if (_currentStep >= 2) ...[
              const SizedBox(height: 24),
              Text(
                _getTranslation('settingsChangeEmailVerifyCodeTitle'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _getTranslation('settingsChangeEmailVerifyCodeDescription'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _verificationCodeController,
                enabled: !_isLoading,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: InputDecoration(
                  labelText: _getTranslation('settingsChangeEmailCode'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _getTimeRemaining().isNotEmpty
                        ? '${_getTranslation('settingsChangeEmailCodeExpires')}: ${_getTimeRemaining()}'
                        : '',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
                  ),
                  TextButton(
                    onPressed: _isLoading ? null : _resendCode,
                    child: Text(
                      _getTranslation('settingsChangeEmailResendCode'),
                    ),
                  ),
                ],
              ),
            ],

            // Error message
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade700),
                ),
              ),
            ],

            // Success message
            if (_successMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  border: Border.all(color: Colors.green.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _successMessage!,
                  style: TextStyle(color: Colors.green.shade700),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isLoading
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: AppButtonStyles.secondaryButton(context),
                    child: Text(_getTranslation('settingsChangeEmailCancel')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _getNextButtonAction(),
                    style: AppButtonStyles.primaryButton(context),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_getNextButtonLabel()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _getNextButtonAction() {
    if (_isLoading) return null;
    if (_currentStep == 1) {
      // Disable button if email is not valid or not available
      if (!_isEmailValid || !_isEmailAvailable || _isCheckingEmail) {
        return null;
      }
      return _sendNewEmailCode;
    }
    if (_currentStep == 2) return _verifyAndCompleteEmailChange;
    return null;
  }

  String _getNextButtonLabel() {
    if (_currentStep == 1) {
      return _getTranslation('settingsChangeEmailSendCode');
    }
    if (_currentStep == 2) return _getTranslation('settingsChangeEmailVerify');
    return 'Next';
  }

  Widget? _buildEmailValidationIcon() {
    final email = _newEmailController.text.trim();
    if (email.isEmpty) return null;

    if (_isCheckingEmail) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!_isEmailValid) {
      return GestureDetector(
        onTap: () => _newEmailController.clear(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(Icons.close, color: Colors.red.shade700),
        ),
      );
    }

    if (_isEmailAvailable) {
      return GestureDetector(
        onTap: () => _newEmailController.clear(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(Icons.check, color: Colors.green.shade700),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _newEmailController.clear(),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Icon(Icons.close, color: Colors.red.shade700),
      ),
    );
  }

  String? _getEmailErrorText() {
    final email = _newEmailController.text.trim();
    if (email.isEmpty) return null;

    final currentUser = Supabase.instance.client.auth.currentUser;
    final currentEmail = currentUser?.email?.trim().toLowerCase() ?? '';

    if (email.toLowerCase() == currentEmail) {
      return _getTranslation('settingsChangeEmailSameEmail');
    }

    if (!_isEmailValid) {
      return _getTranslation('settingsChangeEmailInvalidEmail');
    }

    if (_isCheckingEmail) {
      return null;
    }

    if (!_isEmailAvailable) {
      return _getTranslation('settingsChangeEmailEmailInUse');
    }

    return null;
  }
}
