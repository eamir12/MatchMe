// lib/screens/auth/auth_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/widgets/language_picker_list.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/screens/auth/signup_email_code_screen.dart';
import 'package:matchme/screens/auth/password_reset_otp_screen.dart';
import 'package:matchme/services/secure_signup_service.dart';
import 'package:matchme/services/turnstile_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/password_reset_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/passkey_auth_service.dart';
import 'package:matchme/services/passkey_client_service.dart';
import 'package:matchme/services/passkey_client_exception.dart';
import 'package:matchme/utils/passkey_suggestion.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/services/oauth_loopback_server.dart';
import 'package:matchme/utils/desktop_window_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';

final supabase = Supabase.instance.client;

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen>
    with WidgetsBindingObserver {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _passwordRequirementsKey = GlobalKey();
  bool _isLoading = false;
  String? _errorMessage;
  String? _actualErrorMessage;
  String? _errorMessageKey;
  OAuthProvider? _errorOAuthProvider;
  String? _errorRawMessage;
  bool _showingRawError = false;
  bool _isSignUp = false;
  bool _authSucceeded = false;
  bool _oAuthInProgress = false;

  int _debugTapCount = 0;
  Timer? _debugTapTimer;

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmPasswordFocusNode = FocusNode();

  // NEW: control whether the password is obscured
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // NEW: Track if password field is focused (to show/hide requirements)
  bool _isPasswordFieldFocused = false;
  bool _isCheckingSignupEmail = false;
  String? _emailFieldErrorMessage;
  bool _hasApprovedSignupEmail = false;
  Timer? _signupEmailValidationTimer;
  int _signupEmailValidationGeneration = 0;
  String _lastScreenedSignupEmail = '';

  bool _authUiMessageListenerRegistered = false;
  String? _lastAppliedAuthUiMessage;
  String? _lastConsumedBootstrapError;
  bool _didLogBuild = false;

  /// Removes the bootstrap-stored OAuth error from SharedPreferences.
  /// Should be called when the user dismisses the error (e.g. by typing, switching
  /// mode, or initiating a new auth action) so the error does not reappear on
  /// subsequent AuthScreen instances.
  void _clearBootstrapErrorPref() {
    SharedPreferences.getInstance().then(
      (prefs) => prefs.remove('oauth_bootstrap_error'),
    );
  }

  void _applyAuthUiMessage(String message) {
    final parts = message.split('|||');
    final key = parts[0];
    final rawError = parts.length > 1 ? parts[1] : null;
    final providerName = parts.length > 2 ? parts[2] : null;
    setState(() {
      _isLoading = false;
      _oAuthInProgress = false;
      _authSucceeded = false;
      if (providerName != null && providerName.isNotEmpty) {
        _errorOAuthProvider = _parseOAuthProvider(providerName);
        _errorRawMessage = rawError;
        _errorMessageKey = null;
        _errorMessage = null;
        _showingRawError = false;
      } else if (key.isNotEmpty) {
        _errorMessageKey = key;
        _actualErrorMessage = rawError;
        _errorMessage = null;
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      }
    });
  }

  void _handleIncomingAuthUiMessage(String message) {
    if (message.trim().isEmpty) return;
    if (message == _lastAppliedAuthUiMessage) {
      // Repeated OAuth failures can emit the same payload. Still unlock the UI
      // if a retry left us in a loading/disabled state.
      if (_isLoading || _oAuthInProgress) {
        setState(() {
          _isLoading = false;
          _oAuthInProgress = false;
          _authSucceeded = false;
        });
      }
      return;
    }
    _lastAppliedAuthUiMessage = message;
    _clearBootstrapErrorPref();
    _applyAuthUiMessage(message);
  }

  // Passkey availability tracking
  bool _hasPasskeyForEmail = false;
  bool _isCheckingPasskey = false;
  String _lastCheckedPasskeyEmail = '';
  String _lastServerCheckedPasskeyEmail = '';
  Set<String> _knownPasskeyEmails = <String>{};
  Timer? _passKeyCheckDebounceTimer;

  /// What this device can do with a passkey ceremony. Null until the probe
  /// returns, so the UI never advertises a flow the client would reject with
  /// `not_supported`.
  PasskeyDeviceCapability? _passkeyCapability;

  /// Copy and actions for the passkey card, given what this device can do.
  /// When no platform authenticator is enrolled (e.g. a Windows 11 PC with no
  /// Windows Hello PIN) the card explains the situation and offers no action.
  PasskeyCardPresentation get _passkeyCardPresentation =>
      resolvePasskeyCardPresentation(
        _passkeyCapability ?? PasskeyDeviceCapability.unsupported,
      );

  static const double _oauthProviderIconSize = 20;
  static const double _oauthButtonHeight = 48;

  int _failedPasswordAttempts = 0;
  String _failedPasswordAttemptsEmail = '';

  bool _passwordHasMinLength(String value) => value.length >= 8;
  bool _passwordHasUppercase(String value) => value.contains(RegExp(r'[A-Z]'));
  bool _passwordHasLowercase(String value) => value.contains(RegExp(r'[a-z]'));
  bool _passwordHasNumber(String value) => value.contains(RegExp(r'\d'));
  bool _passwordHasSpecialCharacter(String value) =>
      value.contains(RegExp(r'[@$!%*?&]'));

  bool _isSignupPasswordValid(String value) =>
      _passwordHasMinLength(value) &&
      _passwordHasUppercase(value) &&
      _passwordHasLowercase(value) &&
      _passwordHasNumber(value) &&
      _passwordHasSpecialCharacter(value);

  bool get _isSignupEmailApproved =>
      !_isSignUp ||
      (_isValidEmail(_normalizeEmail(_emailController.text)) &&
          _hasApprovedSignupEmail &&
          _emailFieldErrorMessage == null &&
          !_isCheckingSignupEmail);

  String _mapPasswordAuthError(AuthException e, LocalizationState l10n) {
    final errorKey = ErrorLocalizationService.getErrorTranslationKey(
      e,
      isSignUp: false,
    );
    return l10n.getString(errorKey);
  }

  String _oauthProviderName(OAuthProvider provider, LocalizationState l10n) {
    switch (provider) {
      case OAuthProvider.google:
        return l10n.getString('authContinueWithGoogle');
      case OAuthProvider.azure:
        return l10n.getString('authContinueWithMicrosoft');
      case OAuthProvider.apple:
        return l10n.getString('authContinueWithApple');
      case OAuthProvider.facebook:
        return l10n.getString('authContinueWithFacebook');
      default:
        return provider.name;
    }
  }

  OAuthProvider? _parseOAuthProvider(String name) {
    switch (name.toLowerCase()) {
      case 'google':
        return OAuthProvider.google;
      case 'azure':
        return OAuthProvider.azure;
      case 'apple':
        return OAuthProvider.apple;
      case 'facebook':
        return OAuthProvider.facebook;
      default:
        return null;
    }
  }

  String _buildOAuthErrorMessage(
    OAuthProvider provider,
    String originalError,
    LocalizationState l10n,
  ) {
    final providerName = _oauthProviderName(provider, l10n);
    // Device capability, not just "this account has a passkey on file": don't
    // point users at a passkey where the platform cannot run WebAuthn.
    final passkeyAvailable =
        _hasPasskeyForEmail &&
        _passkeyCapability != null &&
        _passkeyCapability != PasskeyDeviceCapability.unsupported;
    final suggestions = <String>[];

    if (passkeyAvailable) {
      suggestions.add(l10n.getString('authOAuthSuggestionPasskey'));
    }

    suggestions.add(l10n.getString('authOAuthSuggestionDifferentProvider'));
    suggestions.add(l10n.getString('authOAuthSuggestionPassword'));

    final suggestionText = suggestions.join(' ');

    final baseMessage = l10n.getString(
      'authOAuthProviderFailed',
      params: {'provider': providerName},
    );
    return '$baseMessage $suggestionText';
  }

  String _mapSecureSignupError(
    SecureSignUpException e,
    LocalizationState l10n,
  ) {
    switch (e.code) {
      case 'network_error':
        return l10n.getString('networkErrorNoInternet');
      case 'already_registered':
        return l10n.getString('authEmailAlreadyRegistered');
      case 'disposable_email_blocked':
        return l10n.getString('authDisposableEmailBlocked');
      case 'email_recent_abuse_blocked':
      case 'email_high_risk_blocked':
      case 'invalid_email_blocked':
      case 'screening_failed':
        return l10n.getString('authEmailRejected');
      case 'fraud_blocked':
      case 'device_reuse_blocked':
      case 'device_reuse_same_network_blocked':
      case 'install_reuse_blocked':
      case 'install_reuse_same_network_blocked':
      case 'existing_device_session_blocked':
        return l10n.getString('authSignUpBlocked');
      case 'turnstile_verification_failed':
      case 'captcha_failed':
        return l10n.getString('authCaptchaVerificationFailed');
      case 'config_missing':
        return l10n.getString('authCaptchaMissingConfig');
      case 'bad_request':
      case 'exception':
        return l10n.getString('authUnexpectedError');
      default:
        return e.message.trim().isNotEmpty
            ? e.message.trim()
            : l10n.getString('authUnexpectedError');
    }
  }

  String? _mapSecureSignupEmailFieldError(
    SecureSignUpException e,
    LocalizationState l10n,
  ) {
    switch (e.code) {
      case 'already_registered':
        return l10n.getString('authEmailAlreadyRegistered');
      case 'disposable_email_blocked':
        return l10n.getString('authDisposableEmailBlocked');
      case 'email_recent_abuse_blocked':
      case 'email_high_risk_blocked':
      case 'invalid_email_blocked':
      case 'screening_failed':
        return l10n.getString('authEmailRejected');
      default:
        return null;
    }
  }

  Widget _buildPasswordRequirementRow(
    BuildContext context, {
    required bool met,
    required String label,
  }) {
    final theme = Theme.of(context);
    final color = met ? Colors.green.shade700 : Colors.grey.shade600;
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

  String _normalizeEmail(String raw) => raw.trim().toLowerCase();

  // NEW: Check if email is in valid format
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
    return emailRegex.hasMatch(email.trim());
  }

  bool get _shouldShowPasskeySuggestion {
    return shouldSuggestPasskey(
      isSignUp: _isSignUp,
      hasPasskeyForEmail: _hasPasskeyForEmail,
      capability: _passkeyCapability,
      normalizedEmail: _normalizeEmail(_emailController.text),
      lastCheckedEmail: _lastCheckedPasskeyEmail,
    );
  }

  Future<void> _probePasskeySupport() async {
    PasskeyDeviceCapability capability;
    try {
      final availability = await PasskeyClientService.getDeviceAvailability();
      capability = availability.capability;
    } catch (_) {
      capability = PasskeyDeviceCapability.unsupported;
    }
    if (!mounted) return;
    setState(() {
      _passkeyCapability = capability;
    });
  }

  Future<void> _loadKnownPasskeyEmails() async {
    final knownEmails = await PasskeyAuthService.getKnownPasskeyEnabledEmails();
    if (!mounted) return;

    final normalizedEmail = _normalizeEmail(_emailController.text);
    final shouldShowForCurrentEmail =
        !_isSignUp &&
        _isValidEmail(normalizedEmail) &&
        knownEmails.contains(normalizedEmail);

    setState(() {
      _knownPasskeyEmails = knownEmails;
      if (shouldShowForCurrentEmail) {
        _hasPasskeyForEmail = true;
        _lastCheckedPasskeyEmail = normalizedEmail;
      }
    });
  }

  Future<void> _updateKnownPasskeyEmail(
    String email, {
    required bool hasPasskey,
  }) async {
    final knownEmails =
        await PasskeyAuthService.cachePasskeyAvailabilityForEmail(
          email,
          hasPasskey,
        );
    if (!mounted) return;

    setState(() {
      _knownPasskeyEmails = knownEmails;
    });
  }

  void _applyCachedPasskeyAvailability(String normalizedEmail) {
    final hasLocalPasskey = _knownPasskeyEmails.contains(normalizedEmail);
    if (hasLocalPasskey) {
      if (!_hasPasskeyForEmail || _lastCheckedPasskeyEmail != normalizedEmail) {
        setState(() {
          _hasPasskeyForEmail = true;
          _lastCheckedPasskeyEmail = normalizedEmail;
        });
      }
      return;
    }

    if (_hasPasskeyForEmail || _lastCheckedPasskeyEmail.isNotEmpty) {
      setState(() {
        _hasPasskeyForEmail = false;
        _lastCheckedPasskeyEmail = '';
      });
    }
  }

  void _resetPasskeyAvailabilityState() {
    _passKeyCheckDebounceTimer?.cancel();
    _lastServerCheckedPasskeyEmail = '';
    if (!_hasPasskeyForEmail &&
        !_isCheckingPasskey &&
        _lastCheckedPasskeyEmail.isEmpty) {
      return;
    }
    setState(() {
      _hasPasskeyForEmail = false;
      _isCheckingPasskey = false;
      _lastCheckedPasskeyEmail = '';
    });
  }

  Widget _buildPasskeySuggestionCard(
    String Function(String key) getString, {
    required bool authInteractionBlocked,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.92),
            colorScheme.surface.withValues(alpha: 0.98),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.fingerprint_rounded,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        getString(_passkeyCardPresentation.titleKey),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        getString(_passkeyCardPresentation.bodyKey),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_passkeyCardPresentation.showActionButton) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: authInteractionBlocked ? null : _signInWithPasskey,
                  icon: const Icon(Icons.verified_user_rounded),
                  label: Text(getString('authUsePasskeyNow')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // NEW: Sign in with passkey (for now, placeholder that could call Supabase passkey auth)
  Future<void> _signInWithPasskey() async {
    if (!mounted) return;

    final normalizedEmail = _normalizeEmail(_emailController.text);

    if (!_isValidEmail(normalizedEmail)) {
      final l10n = ref.read(localizationProvider);
      setState(() {
        _errorMessage = l10n.getString('authEmailInvalid');
      });
      return;
    }

    final l10n = ref.read(localizationProvider);

    _clearBootstrapErrorPref();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _actualErrorMessage = null;
      _errorMessageKey = null;
      _errorOAuthProvider = null;
      _errorRawMessage = null;
      _showingRawError = false;
    });

    try {
      // Check if passkey authentication is supported
      if (!await PasskeyClientService.isAuthenticationSupported()) {
        if (!mounted) return;
        setState(() {
          _errorMessage = l10n.getString('authPasskeyNotSupported');
          _isLoading = false;
        });
        return;
      }

      // Start authentication with the server
      final startResult = await PasskeyAuthService.startAuthentication(
        email: normalizedEmail,
      );

      if (!startResult.hasPublicKeyOptions) {
        if (!mounted) return;
        setState(() {
          _errorMessage = l10n.getString('authPasskeyNotAvailable');
          _isLoading = false;
        });
        return;
      }

      // Get assertion from the device
      final assertion = await PasskeyClientService.getAuthenticationAssertion(
        publicKeyOptions: startResult.publicKeyOptions!,
      );

      // Finish authentication and apply session
      await PasskeyAuthService.finishAuthenticationAndApplySession(
        assertion: assertion,
        email: normalizedEmail,
        requestId: startResult.requestId,
      );
      await _updateKnownPasskeyEmail(normalizedEmail, hasPasskey: true);

      if (!mounted) return;
      // Session is now applied, auth state listener will handle navigation
      setState(() {
        _isLoading = false;
        _errorMessage = l10n.getString('authPasskeySignInSuccess');
      });
    } catch (error) {
      if (!mounted) return;

      String errorMessage = l10n.getString('authPasskeySignInFailed');

      if (error is PasskeyClientException) {
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        errorMessage = l10n.getString(errorKey);
      } else if (error is PasskeyAuthException) {
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        errorMessage = l10n.getString(errorKey);
      } else {
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
        errorMessage = l10n.getString(errorKey);
      }

      setState(() {
        _errorMessage = errorMessage;
        _isLoading = false;
      });
    }
  }

  bool _isPasswordLoginCaptchaRequired() =>
      !_isSignUp && _failedPasswordAttempts >= 3;

  bool _requiresCaptchaForCurrentAction() =>
      _isSignUp || _isPasswordLoginCaptchaRequired();

  bool _isInvalidPasswordAttempt(AuthException e) {
    final lower = e.message.toLowerCase();
    return lower.contains('invalid login credentials') ||
        lower.contains('invalid credentials') ||
        (lower.contains('invalid') && lower.contains('credential'));
  }

  int _incrementFailedPasswordAttempts(String email) {
    if (email.isEmpty) return _failedPasswordAttempts;
    final sameEmail = _failedPasswordAttemptsEmail == email;
    final next = sameEmail ? _failedPasswordAttempts + 1 : 1;
    if (mounted) {
      setState(() {
        _failedPasswordAttemptsEmail = email;
        _failedPasswordAttempts = next;
      });
    } else {
      _failedPasswordAttemptsEmail = email;
      _failedPasswordAttempts = next;
    }
    return next;
  }

  Future<void> _resetFailedPasswordAttempts(String email) async {
    if (email.isEmpty) return;
    if (_failedPasswordAttemptsEmail != email && _failedPasswordAttempts == 0) {
      return;
    }
    if (mounted) {
      setState(() {
        _failedPasswordAttemptsEmail = '';
        _failedPasswordAttempts = 0;
      });
    } else {
      _failedPasswordAttemptsEmail = '';
      _failedPasswordAttempts = 0;
    }
  }

  void _syncFailedAttemptsWithCurrentEmail() {
    final email = _normalizeEmail(_emailController.text);
    if (email.isEmpty) {
      if (_failedPasswordAttempts != 0 ||
          _failedPasswordAttemptsEmail.isNotEmpty) {
        setState(() {
          _failedPasswordAttempts = 0;
          _failedPasswordAttemptsEmail = '';
        });
      }
      return;
    }

    if (_failedPasswordAttemptsEmail.isNotEmpty &&
        _failedPasswordAttemptsEmail != email &&
        _failedPasswordAttempts != 0) {
      setState(() {
        _failedPasswordAttempts = 0;
        _failedPasswordAttemptsEmail = '';
      });
    }
  }

  void _switchAuthMode(bool signUp) {
    if (_isSignUp == signUp) return;
    _clearBootstrapErrorPref();
    _confirmPasswordController.clear();
    setState(() {
      _isSignUp = signUp;
      _errorMessage = null;
      _actualErrorMessage = null;
      _errorMessageKey = null;
      _errorOAuthProvider = null;
      _errorRawMessage = null;
      _showingRawError = false;
      _obscureConfirmPassword = true;
    });
    _syncFailedAttemptsWithCurrentEmail();
    _checkPasskeyAvailabilityDebounced();
  }

  void _scrollPasswordGuidanceIntoView() {
    if (!_isSignUp || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _passwordRequirementsKey.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    });
  }

  void _handlePasswordFocusChange() {
    setState(() {
      _isPasswordFieldFocused = _passwordFocusNode.hasFocus;
    });
    if (_passwordFocusNode.hasFocus) {
      _scrollPasswordGuidanceIntoView();
    }
  }

  Future<void> _handleEmailFocusChange() async {
    if (!mounted) return;

    if (_emailFocusNode.hasFocus) {
      if (_emailFieldErrorMessage != null) {
        setState(() {
          _emailFieldErrorMessage = null;
        });
      }
      if (_hasApprovedSignupEmail) {
        setState(() {
          _hasApprovedSignupEmail = false;
        });
      }
      return;
    }

    if (!_isSignUp || _isLoading) return;

    await _validateSignupEmail(
      forceShowInvalidFormat: true,
      requestGeneration: ++_signupEmailValidationGeneration,
    );
  }

  void _scheduleSignupEmailValidation() {
    _signupEmailValidationTimer?.cancel();
    if (!_isSignUp) return;

    final normalizedEmail = _normalizeEmail(_emailController.text);
    if (normalizedEmail.isEmpty || !_isValidEmail(normalizedEmail)) {
      return;
    }

    final requestGeneration = ++_signupEmailValidationGeneration;
    _signupEmailValidationTimer = Timer(
      const Duration(milliseconds: 500),
      () => _validateSignupEmail(
        forceShowInvalidFormat: false,
        requestGeneration: requestGeneration,
      ),
    );
  }

  Future<void> _validateSignupEmail({
    required bool forceShowInvalidFormat,
    required int requestGeneration,
  }) async {
    if (!mounted || !_isSignUp || _isLoading) return;

    final normalizedEmail = _normalizeEmail(_emailController.text);
    if (normalizedEmail.isEmpty) return;
    if (!_isValidEmail(normalizedEmail)) {
      if (!forceShowInvalidFormat) return;
      setState(() {
        _hasApprovedSignupEmail = false;
        _emailFieldErrorMessage = ref
            .read(localizationProvider)
            .getString('authEmailInvalid');
      });
      return;
    }

    if (_lastScreenedSignupEmail == normalizedEmail &&
        (_hasApprovedSignupEmail || _emailFieldErrorMessage != null)) {
      return;
    }

    setState(() {
      _isCheckingSignupEmail = true;
      _hasApprovedSignupEmail = false;
      _emailFieldErrorMessage = null;
    });

    try {
      await SecureSignupService.screenEmail(email: normalizedEmail);
      if (!mounted || requestGeneration != _signupEmailValidationGeneration) {
        return;
      }
      if (_normalizeEmail(_emailController.text) != normalizedEmail) {
        return;
      }
      setState(() {
        _lastScreenedSignupEmail = normalizedEmail;
        _hasApprovedSignupEmail = true;
        _emailFieldErrorMessage = null;
      });
    } on SecureSignUpException catch (error) {
      if (!mounted || requestGeneration != _signupEmailValidationGeneration) {
        return;
      }
      if (_normalizeEmail(_emailController.text) != normalizedEmail) {
        return;
      }
      setState(() {
        _lastScreenedSignupEmail = normalizedEmail;
        _hasApprovedSignupEmail = false;
        _emailFieldErrorMessage =
            _mapSecureSignupEmailFieldError(
              error,
              ref.read(localizationProvider),
            ) ??
            _mapSecureSignupError(error, ref.read(localizationProvider));
      });
    } finally {
      if (mounted && requestGeneration == _signupEmailValidationGeneration) {
        setState(() {
          _isCheckingSignupEmail = false;
        });
      }
    }
  }

  Future<String?> _prepareCaptchaTokenIfNeeded(LocalizationState l10n) async {
    if (!_requiresCaptchaForCurrentAction()) {
      return '';
    }

    final action = _isSignUp
        ? TurnstileAuthAction.signUp
        : TurnstileAuthAction.passwordLogin;
    final normalizedEmail = _normalizeEmail(_emailController.text);

    try {
      final token = await TurnstileService.requestToken(
        context: context,
        l10n: l10n,
        action: action,
      );
      if (token == null || token.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = l10n.getString('authCaptchaCancelled');
          });
        }
        return null;
      }
      if (action == TurnstileAuthAction.signUp) {
        return token;
      }
      await TurnstileService.verifyToken(
        token: token,
        action: action,
        l10n: l10n,
      );
      if (action == TurnstileAuthAction.passwordLogin) {
        await _resetFailedPasswordAttempts(normalizedEmail);
      }
      return token;
    } catch (e) {
      if (mounted) {
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        setState(() {
          _errorMessage = l10n.getString(errorKey);
        });
      }
      return null;
    }
  }

  Widget _buildOAuthButton({
    required OAuthProvider provider,
    required String label,
    required String assetPath,
    required bool authInteractionBlocked,
  }) {
    final icon = SizedBox(
      width: _oauthProviderIconSize,
      height: _oauthProviderIconSize,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return const SizedBox.shrink();
        },
      ),
    );
    final text = Text(label);
    final spacer = const SizedBox(width: 12);

    return OutlinedButton(
      onPressed: authInteractionBlocked
          ? null
          : () => _signInWithOAuth(provider),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(_oauthButtonHeight),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [text, spacer, icon],
      ),
    );
  }

  /// True on the desktop targets, where a custom-scheme OAuth redirect cannot
  /// come back to the app and the RFC 8252 loopback listener must be used.
  ///
  /// macOS is included: its `Info.plist` declares no `CFBundleURLSchemes`, so
  /// Microsoft/Apple/Facebook are just as stuck there as they are on Windows.
  /// (Google still prefers the native SDK on macOS and never reaches here.)
  bool get _useLoopbackRedirect =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Upper bound on how long the loopback flow waits for the browser to come
  /// back with a code. Generous because the user is completing a consent screen
  /// by hand; [didChangeAppLifecycleState] normally ends the wait much sooner
  /// if they abandon the flow.
  static const Duration _loopbackCallbackTimeout = Duration(minutes: 5);

  /// Grace period after the user returns to the app before a pending loopback
  /// attempt is treated as abandoned. Covers the case where the browser fires the
  /// loopback request and focus returns at effectively the same moment.
  static const Duration _loopbackResumeGrace = Duration(seconds: 2);

  /// Signals the in-flight loopback attempt that the user came back without a
  /// callback, so the flow can stop waiting instead of hanging on a spinner.
  _LoopbackCancellation? _loopbackCancellation;

  /// Whether the app has actually been backgrounded during the current loopback
  /// attempt. Guards against the transient focus bounce Windows emits while the
  /// system browser is being launched, which would otherwise look like the user
  /// returning and cancel a sign-in that is still in flight.
  bool _sawBackgroundDuringLoopback = false;

  /// Whether the Google SDK is usable on this platform.
  ///
  /// `google_sign_in` 7.x ships no Windows or Linux implementation, so
  /// `GoogleSignInPlatform.instance` is the placeholder, whose
  /// `supportsAuthenticate()` throws [UnimplementedError] rather than returning
  /// false. Probed defensively so tapping Google on Windows does not crash.
  bool get _googleSdkSupportsAuthenticate {
    try {
      return GoogleSignIn.instance.supportsAuthenticate();
    } catch (error) {
      debugPrint(
        '⚠️ [GoogleSignIn] supportsAuthenticate() unavailable on this platform: $error',
      );
      return false;
    }
  }

  String? _oauthScopesFor(OAuthProvider provider) => switch (provider) {
    OAuthProvider.google =>
      'openid email profile '
          'https://www.googleapis.com/auth/calendar.readonly '
          'https://www.googleapis.com/auth/calendar.events.readonly',
    OAuthProvider.azure =>
      'openid email profile offline_access User.Read Calendars.Read',
    OAuthProvider.apple => 'name email',
    OAuthProvider.facebook => 'email public_profile',
    _ => null,
  };

  /// Desktop sign-in: open the system browser against a loopback redirect the
  /// app owns, then exchange the returned PKCE code for a session.
  ///
  /// This is the only path that works on Windows and Linux, where the Google
  /// SDK does not exist and no protocol handler is registered for
  /// `com.example.matchme://`.
  Future<void> _signInWithOAuthLoopback(OAuthProvider provider) async {
    if (!mounted) return;

    final l10n = ref.read(localizationProvider);

    _authSucceeded = false;
    // Deliberately not set: the existing resume handler would clear the spinner
    // out from under this flow, which manages its own cancellation.
    _oAuthInProgress = false;
    _lastAppliedAuthUiMessage = null;
    _lastConsumedBootstrapError = null;
    ref.read(authUiMessageProvider.notifier).clear();
    _clearBootstrapErrorPref();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _errorOAuthProvider = null;
      _errorRawMessage = null;
      _showingRawError = false;
    });

    final listener = OAuthLoopbackServer.instance;
    void reportError(String raw) {
      if (!mounted) return;
      unawaited(
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        ),
      );
      setState(() {
        _isLoading = false;
        _oAuthInProgress = false;
        _authSucceeded = false;
        _errorOAuthProvider = provider;
        _errorRawMessage = raw;
        _showingRawError = false;
      });
    }

    try {
      // Bind first, so `redirectTo` is known before we ever open a browser.
      final Uri redirectUri;
      try {
        redirectUri = await listener.listen();
      } on OAuthLoopbackException catch (e) {
        reportError(l10n.getString('authOAuthFailed'));
        debugPrint('🔴 [OAuth] loopback unavailable: ${e.failure.name}');
        return;
      }

      _loopbackCancellation = _LoopbackCancellation();
      _sawBackgroundDuringLoopback = false;

      // Record the provider so callback/error handlers can name it, and so
      // auth_provider's PKCE-failure branch has context.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('pending_oauth_provider', provider.name);
      } catch (_) {}

      // Generates and persists the PKCE code verifier, then opens the browser.
      final launched = await supabase.auth.signInWithOAuth(
        provider,
        redirectTo: redirectUri.toString(),
        scopes: _oauthScopesFor(provider),
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!launched) {
        reportError(l10n.getString('authOAuthFailed'));
        return;
      }

      // Wait for the browser's callback, but do not sit on the spinner forever if
      // the user abandons the flow and comes back to the app.
      final OAuthLoopbackCallback callback;
      try {
        callback = await Future.any<OAuthLoopbackCallback>([
          listener.waitForCallback(_loopbackCallbackTimeout),
          _abandonLoopbackAfterResume(_loopbackCancellation),
        ]);
      } on _LoopbackAbandoned {
        // The user came back without the browser delivering a code, and the
        // grace period lapsed. Cancelled, not failed.
        debugPrint('ℹ️ [OAuth] loopback sign-in abandoned by user');
        unawaited(
          SharedPreferences.getInstance().then(
            (prefs) => prefs.remove('pending_oauth_provider'),
          ),
        );
        if (mounted) {
          setState(() {
            _isLoading = false;
            _oAuthInProgress = false;
            _authSucceeded = false;
          });
        }
        return;
      } on OAuthLoopbackException catch (e) {
        debugPrint('🔴 [OAuth] loopback callback failed: ${e.failure.name}');
        reportError(l10n.getString('authOAuthFailed'));
        return;
      }

      if (!callback.isSuccess) {
        final key = _isOAuthAccessDenied(callback.error)
            ? 'authOAuthAccessDenied'
            : 'authOAuthFailed';
        reportError(
          callback.errorDescription?.isNotEmpty == true
              ? '${l10n.getString(key)} (${callback.errorDescription})'
              : l10n.getString(key),
        );
        return;
      }

      final response = await supabase.auth.exchangeCodeForSession(
        callback.code!,
      );
      debugPrint(
        '🔵 [OAuth] loopback sign-in succeeded for ${response.session.user.id}',
      );

      // Keep the spinner up; onAuthStateChange navigates away.
      _authSucceeded = true;
    } on AuthException catch (e) {
      debugPrint('🔴 [OAuth] loopback AuthException: ${e.message}');
      reportError(
        e.message.toLowerCase().contains('access_denied')
            ? l10n.getString('authOAuthAccessDenied')
            : l10n.getString('authOAuthFailed'),
      );
    } catch (e, st) {
      debugPrint('🔴 [OAuth] loopback unexpected error: $e\n$st');
      reportError(l10n.getString('authOAuthFailed'));
    } finally {
      _loopbackCancellation = null;
      await listener.close();
      // The provider sent the user out to the system browser and that browser is
      // still in front of us. The OAuth tab cannot be closed from script, so
      // raise our own window instead - otherwise the user has to alt-tab back
      // out of a browser tab that only says "Signed in".
      unawaited(focusAppWindow());
    }
  }

  /// Fails with [_LoopbackAbandoned] once the user has been back in the app for
  /// [grace] without the browser having delivered a code.
  ///
  /// The grace period exists because the browser hitting the loopback URL and
  /// focus returning to the app can land within milliseconds of each other.
  static Future<OAuthLoopbackCallback> _abandonLoopbackAfterResume(
    _LoopbackCancellation? cancellation,
  ) async {
    if (cancellation == null) {
      // Nothing can ever cancel; park forever so the real timeout governs.
      return Completer<OAuthLoopbackCallback>().future;
    }
    await cancellation.future;
    await Future<void>.delayed(_loopbackResumeGrace);
    throw const _LoopbackAbandoned();
  }

  /// Whether a provider error string means the user declined consent, which is
  /// a cancellation rather than a failure.
  static bool _isOAuthAccessDenied(String? error) {
    if (error == null) return false;
    final normalized = error.toLowerCase().replaceAll('_', '');
    return normalized == 'accessdenied' || normalized.contains('userdeclined');
  }

  Future<void> _signInWithOAuth(OAuthProvider provider) async {
    if (!mounted) return;

    // Clear any stale pending provider from a previous OAuth attempt
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_oauth_provider');
    } catch (_) {}

    // Use native Google Sign-In (popup on web, native SDK on mobile) +
    // signInWithIdToken instead of redirect-based OAuth which opens Chrome.
    // Google SDK handles popup cancellation natively, so we don't track _oAuthInProgress.
    //
    // google_sign_in only ships Android, iOS, macOS and web implementations, so
    // on Windows/Linux the probe above reports unavailable and Google falls
    // through to the loopback redirect below.
    if (provider == OAuthProvider.google && _googleSdkSupportsAuthenticate) {
      print(
        '🔵 [GoogleSignIn] Delegating to _signInWithGoogle (platform=${defaultTargetPlatform.name}, isWeb=$kIsWeb)',
      );
      await _signInWithGoogle();
      print('🔵 [GoogleSignIn] _signInWithGoogle returned');
      return;
    }

    // Desktop has no custom URL scheme to return through: this project registers
    // no protocol handler on Windows/Linux, and macOS declares no
    // CFBundleURLSchemes. A `com.example.matchme://` redirect therefore dead-ends
    // in the browser and the flow times out. Use the RFC 8252 section 7.3
    // loopback listener instead, which the app owns outright.
    if (_useLoopbackRedirect) {
      await _signInWithOAuthLoopback(provider);
      return;
    }

    // Save the provider before redirect so callback handlers can include it in error messages
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_oauth_provider', provider.name);
    } catch (_) {}

    _authSucceeded = false;
    _oAuthInProgress = true;
    _lastAppliedAuthUiMessage = null;
    _lastConsumedBootstrapError = null;
    ref.read(authUiMessageProvider.notifier).clear();
    _clearBootstrapErrorPref();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _errorOAuthProvider = null;
      _errorRawMessage = null;
      _showingRawError = false;
    });

    try {
      const mobileRedirectTo = 'com.example.matchme://login-callback';
      final redirectTo = kIsWeb
          ? '${Uri.base.origin}/auth/callback'
          : mobileRedirectTo;
      final scopes = _oauthScopesFor(provider);

      await supabase.auth
          .signInWithOAuth(
            provider,
            redirectTo: redirectTo,
            scopes: scopes,
            authScreenLaunchMode: LaunchMode.platformDefault,
          )
          .timeout(const Duration(seconds: 90));

      // Redirect initiated successfully — keep spinner until onAuthStateChange navigates away
      _authSucceeded = true;
    } on TimeoutException {
      if (!mounted) return;
      try {
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        );
      } catch (_) {}
      setState(() {
        _errorOAuthProvider = provider;
        _errorRawMessage =
            'OAuth timed out — popup may have been blocked or closed';
        _showingRawError = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      try {
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        );
      } catch (_) {}
      setState(() {
        _errorOAuthProvider = provider;
        _errorRawMessage = e.message;
        _showingRawError = false;
      });
    } catch (e) {
      if (!mounted) return;
      try {
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        );
      } catch (_) {}
      setState(() {
        _errorOAuthProvider = provider;
        _errorRawMessage = e.toString();
        _showingRawError = false;
      });
    } finally {
      _oAuthInProgress = false;
      if (mounted && !_authSucceeded) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Signs in with Google using the native SDK (popup on web, native UI on mobile).
  /// No Chrome window is opened — the credential is exchanged with Supabase via
  /// signInWithIdToken directly.
  Future<void> _signInWithGoogle() async {
    if (!mounted) return;
    print('🔵 [GoogleSignIn] _signInWithGoogle started');
    _authSucceeded = false;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Resolve platform-appropriate client IDs.
      // Web: just the web client ID.
      // Android: Android client ID + web client ID as serverClientId.
      // iOS: iOS client ID + web client ID as serverClientId.
      final envWebId = const String.fromEnvironment(
        'GOOGLE_CLIENT_ID',
        defaultValue: '',
      ).trim();
      final envAndroidId = const String.fromEnvironment(
        'GOOGLE_ANDROID_CLIENT_ID',
        defaultValue: '',
      ).trim();
      final envIosId = const String.fromEnvironment(
        'GOOGLE_IOS_CLIENT_ID',
        defaultValue: '',
      ).trim();
      final dotWebId = (dotenv.env['GOOGLE_CLIENT_ID'] ?? '').trim();
      final dotAndroidId = (dotenv.env['GOOGLE_ANDROID_CLIENT_ID'] ?? '')
          .trim();
      final dotIosId = (dotenv.env['GOOGLE_IOS_CLIENT_ID'] ?? '').trim();

      final webClientId = envWebId.isNotEmpty ? envWebId : dotWebId;
      final androidClientId = envAndroidId.isNotEmpty
          ? envAndroidId
          : dotAndroidId;
      final iosClientId = envIosId.isNotEmpty ? envIosId : dotIosId;

      String clientId;
      String? serverClientId;

      if (kIsWeb) {
        clientId = webClientId;
        serverClientId = null;
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        clientId = androidClientId.isNotEmpty ? androidClientId : webClientId;
        serverClientId = webClientId.isNotEmpty ? webClientId : null;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        clientId = iosClientId.isNotEmpty ? iosClientId : webClientId;
        serverClientId = webClientId.isNotEmpty ? webClientId : null;
      } else {
        clientId = webClientId;
        serverClientId = null;
      }

      if (clientId.isEmpty) {
        throw Exception('Google Client ID not configured for this platform');
      }

      await WebCalendarService.ensureGoogleSignInInitialized(
        clientId: clientId,
        serverClientId: serverClientId,
      );

      // Open native Google sign-in (popup on web, system UI on mobile).
      // The native UI auto-closes after account selection — no Chrome tab.
      print('🔵 [GoogleSignIn] Calling authenticate()...');
      final googleUser = await GoogleSignIn.instance.authenticate();
      print('🔵 [GoogleSignIn] authenticate() returned successfully');

      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;
      print(
        '🔵 [GoogleSignIn] idToken received: ${idToken != null}, length=${idToken?.length}',
      );

      if (idToken == null) {
        throw Exception('No ID token received from Google');
      }

      // Obtain access token via authorization client (separate step in v7.x API).
      // Must pass at least one scope — Android throws "requestedScopes cannot be
      // null or empty" for an empty list. 'openid' is always available.
      final authClient = googleUser.authorizationClient;
      final authorization = await authClient.authorizationForScopes(['openid']);
      final accessToken = authorization?.accessToken;
      print(
        '🔵 [GoogleSignIn] accessToken received: ${accessToken != null}, length=${accessToken?.length}',
      );

      print('🔵 [GoogleSignIn] Calling signInWithIdToken...');
      final authResponse = await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      print(
        '🔵 [GoogleSignIn] signInWithIdToken succeeded. User: ${authResponse.user?.id}, Session: ${authResponse.session != null}',
      );

      // Auth succeeded — leave the spinner visible so the login form doesn't
      // flash before onAuthStateChange triggers navigation.
      _authSucceeded = true;
    } on GoogleSignInException catch (e) {
      // Only treat explicit cancellation as non-error.
      // unknownError (e.g. "requestedScopes cannot be null or empty") is a real bug.
      if (e.code == GoogleSignInExceptionCode.canceled) {
        print('🟡 [GoogleSignIn] User canceled');
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }
      print('🔴 [GoogleSignIn] GoogleSignInException (${e.code}): $e');
      if (!mounted) return;
      unawaited(
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        ),
      );
      setState(() {
        _errorOAuthProvider = OAuthProvider.google;
        _errorRawMessage = e.toString();
        _showingRawError = false;
      });
    } on AuthException catch (e) {
      print('🔴 [GoogleSignIn] AuthException: ${e.message}');
      if (!mounted) return;
      unawaited(
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        ),
      );
      setState(() {
        _errorOAuthProvider = OAuthProvider.google;
        _errorRawMessage = e.message;
        _showingRawError = false;
      });
    } catch (e, st) {
      print('🔴 [GoogleSignIn] Unexpected error: $e\n$st');
      if (!mounted) return;
      unawaited(
        SharedPreferences.getInstance().then(
          (prefs) => prefs.remove('pending_oauth_provider'),
        ),
      );
      setState(() {
        _errorOAuthProvider = OAuthProvider.google;
        _errorRawMessage = e.toString();
        _showingRawError = false;
      });
    } finally {
      // If auth succeeded, keep the spinner visible — onAuthStateChange will
      // navigate away momentarily. Only reset loading on error/cancel.
      if (mounted && !_authSucceeded) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _performAuth() async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;

    final l10n = ref.read(localizationProvider);
    final normalizedEmail = _normalizeEmail(_emailController.text);
    final captchaToken = await _prepareCaptchaTokenIfNeeded(l10n);
    if (_requiresCaptchaForCurrentAction() &&
        (captchaToken == null || captchaToken.isEmpty)) {
      return;
    }

    _clearBootstrapErrorPref();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _errorOAuthProvider = null;
      _errorRawMessage = null;
      _showingRawError = false;
    });
    try {
      // Get the localization provider reference BEFORE async operations
      // (ref becomes unsafe after widget unmounts due to navigation)
      final localizationNotifier = ref.read(localizationProvider.notifier);

      if (_isSignUp) {
        await SecureSignupService.signUp(
          email: normalizedEmail,
          password: _passwordController.text.trim(),
          captchaToken: captchaToken ?? '',
          language: l10n.currentLocale.languageCode,
        );
        if (!mounted) return;
        _passwordController.clear();
        _confirmPasswordController.clear();
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SignupEmailCodeScreen(email: normalizedEmail),
          ),
        );
      } else {
        await supabase.auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );

        await _resetFailedPasswordAttempts(normalizedEmail);

        // Register session on the server with retry logic
        final user = supabase.auth.currentUser;
        if (user != null) {
          final platformText = _detectPlatform();

          // Wait a moment for JWT token to be fully available
          await Future.delayed(const Duration(milliseconds: 500));

          // Try to register session with retry logic
          bool sessionRegistered = false;
          int retryCount = 0;
          const maxRetries = 3;

          while (!sessionRegistered && retryCount < maxRetries) {
            try {
              sessionRegistered = await SessionService.registerSession(
                user.id,
                platform: platformText,
              );
              if (sessionRegistered) {
                print(
                  '✅ Session registration successful (attempt ${retryCount + 1})',
                );
              } else {
                retryCount++;
                print(
                  '⚠️ Session registration did not create an active session (attempt $retryCount/$maxRetries)',
                );
                if (retryCount < maxRetries) {
                  await Future.delayed(const Duration(milliseconds: 1000));
                }
              }
            } catch (e) {
              retryCount++;
              if (retryCount < maxRetries) {
                print(
                  '⚠️ Session registration failed, retrying ($retryCount/$maxRetries): $e',
                );
                await Future.delayed(const Duration(milliseconds: 1000));
              } else {
                print(
                  '❌ Session registration failed after $maxRetries attempts: $e',
                );
                // Log the error but don't block login
              }
            }
          }

          if (sessionRegistered) {
            await UserActivityService.instance.pingIfDue(
              user.id,
              force: true,
              source: 'auth-login',
            );
            print('✅ User activity updated successfully');
          } else {
            print(
              '⚠️ Skipping online heartbeat because session registration failed',
            );
          }

          // Sync language preference to database after login
          // This ensures the language selected on login screen is persisted to DB
          // Note: We got the notifier reference before login to avoid ref issues after navigation
          try {
            await localizationNotifier.syncLanguageAfterLogin();
          } catch (e) {
            print('syncLanguageAfterLogin failed: $e');
          }

          _passwordController.clear();
        }
      }
    } on SecureSignUpException catch (e) {
      if (!mounted) return;
      final emailFieldMessage = _mapSecureSignupEmailFieldError(
        e,
        ref.read(localizationProvider),
      );
      _clearBootstrapErrorPref();
      setState(() {
        if (emailFieldMessage != null) {
          _emailFieldErrorMessage = emailFieldMessage;
          _errorMessage = null;
        } else {
          _errorMessage = _mapSecureSignupError(
            e,
            ref.read(localizationProvider),
          );
        }
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      var message = _mapPasswordAuthError(e, ref.read(localizationProvider));
      if (!_isSignUp && _isInvalidPasswordAttempt(e)) {
        _incrementFailedPasswordAttempts(normalizedEmail);
        if (!mounted) return;
      }
      _clearBootstrapErrorPref();
      setState(() {
        _errorMessage = message;
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      });
    } catch (e) {
      if (!mounted) return;
      final l10n = ref.read(localizationProvider);
      final errorKey = ErrorLocalizationService.getErrorTranslationKey(
        e,
        isSignUp: _isSignUp,
      );
      _clearBootstrapErrorPref();
      setState(() {
        _errorMessage = l10n.getString(errorKey);
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track whether we actually went away. Launching the system browser is
    // itself what backgrounds the app, and Windows emits a brief focus bounce
    // during that hand-off - treating that stray `resumed` as "the user came
    // back" would cancel a sign-in that is still in progress.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _sawBackgroundDuringLoopback = true;
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    // A loopback sign-in parks the user in the system browser. If they come back
    // to the app, release the pending attempt so the spinner doesn't hang for
    // the full callback timeout. Signalled before the checks below because this
    // must fire regardless of whether a session happens to exist.
    if (_sawBackgroundDuringLoopback) {
      _sawBackgroundDuringLoopback = false;
      _loopbackCancellation?.cancel();
    }

    if (supabase.auth.currentSession != null) return;

    if (_oAuthInProgress && !_authSucceeded) {
      _oAuthInProgress = false;
      setState(() {
        _isLoading = false;
      });
      return;
    }

    // Redirect-based OAuth keeps _isLoading true until an error arrives. If the
    // deep-link handler is delayed or emits a duplicate message, unlock the UI
    // once the user returns unsigned-in.
    if (_isLoading && _authSucceeded) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        if (supabase.auth.currentSession != null) return;
        if (!_isLoading) return;
        setState(() {
          _isLoading = false;
          _oAuthInProgress = false;
          _authSucceeded = false;
        });
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _scrollController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    _passKeyCheckDebounceTimer?.cancel();
    _signupEmailValidationTimer?.cancel();
    _debugTapTimer?.cancel();
    super.dispose();
  }

  String _detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadKnownPasskeyEmails();
    unawaited(_probePasskeySupport());
    _emailController.addListener(_onEmailChanged);
    _passwordController.addListener(_onPasswordChanged);
    _confirmPasswordController.addListener(_onConfirmPasswordChanged);
    _emailFocusNode.addListener(_handleEmailFocusChange);
    _passwordFocusNode.addListener(_handlePasswordFocusChange);
    // Request focus after first frame so the view is "served" and keyboard shows correctly (avoids showSoftInput ignored)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPasskeyAvailabilityDebounced();
    });
    // Refresh the disposable-email blocklist cache in the background (UX-only;
    // server always re-checks). Never awaited — must not block auth startup.
    unawaited(SecureSignupService.refreshDisposableBlocklistCache());
    // Clear error message when user starts typing
    _emailController.addListener(() {
      if ((_errorMessage != null || _errorOAuthProvider != null) &&
          _emailController.text.isNotEmpty) {
        _clearBootstrapErrorPref();
        setState(() {
          _errorMessage = null;
          _actualErrorMessage = null;
          _errorMessageKey = null;
          _errorOAuthProvider = null;
          _errorRawMessage = null;
          _showingRawError = false;
        });
      }
    });

    _passwordController.addListener(() {
      if ((_errorMessage != null || _errorOAuthProvider != null) &&
          _passwordController.text.isNotEmpty) {
        _clearBootstrapErrorPref();
        setState(() {
          _errorMessage = null;
          _actualErrorMessage = null;
          _errorMessageKey = null;
          _errorOAuthProvider = null;
          _errorRawMessage = null;
          _showingRawError = false;
        });
      }
    });
  }

  void _onEmailChanged() {
    _signupEmailValidationTimer?.cancel();

    // Clear error message when user starts typing
    if (_errorMessage != null || _errorOAuthProvider != null) {
      _clearBootstrapErrorPref();
      setState(() {
        _errorMessage = null;
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      });
    }
    if (_emailFieldErrorMessage != null) {
      setState(() {
        _emailFieldErrorMessage = null;
      });
    }
    if (_hasApprovedSignupEmail) {
      setState(() {
        _hasApprovedSignupEmail = false;
      });
    }
    if (_isCheckingSignupEmail) {
      setState(() {
        _isCheckingSignupEmail = false;
      });
    }
    _lastScreenedSignupEmail = '';
    _syncFailedAttemptsWithCurrentEmail();
    _checkPasskeyAvailabilityDebounced();
    _scheduleSignupEmailValidation();
  }

  void _checkPasskeyAvailabilityDebounced() {
    // Cancel previous debounce timer
    _passKeyCheckDebounceTimer?.cancel();

    final normalizedEmail = _normalizeEmail(_emailController.text);

    // If email is empty or invalid, reset passkey state
    if (_isSignUp ||
        normalizedEmail.isEmpty ||
        !_isValidEmail(normalizedEmail)) {
      _resetPasskeyAvailabilityState();
      return;
    }

    // Use only the local cache to check passkey availability.
    // Calling startAuthentication() on every keystroke triggers the WebAuthn
    // protocol, which on Android may auto-complete a passkey sign-in via
    // Credential Manager — logging the user into whatever account has a
    // passkey on this device, regardless of which email they intended to use.
    // The server call (and its WebAuthn challenge) must only happen when the
    // user explicitly taps "Sign in with passkey".
    _applyCachedPasskeyAvailability(normalizedEmail);

    // If this email was already confirmed with the server during this screen
    // session, keep the current UI and skip another lookup.
    if (_lastServerCheckedPasskeyEmail == normalizedEmail &&
        !_isCheckingPasskey) {
      return;
    }

    // Debounce server call to check passkey availability after user stops typing
    // This will update the cache and show the passkey suggestion if available
    _passKeyCheckDebounceTimer = Timer(
      const Duration(milliseconds: 800),
      () => _checkPasskeyAvailabilityWithServer(normalizedEmail),
    );
  }

  Future<void> _checkPasskeyAvailabilityWithServer(
    String normalizedEmail,
  ) async {
    if (!mounted || _isSignUp || _isCheckingPasskey) {
      return;
    }

    // Double-check that the email hasn't changed
    if (_normalizeEmail(_emailController.text) != normalizedEmail) {
      return;
    }

    // If we already checked this email with the server, skip
    if (_lastServerCheckedPasskeyEmail == normalizedEmail) {
      return;
    }

    setState(() {
      _isCheckingPasskey = true;
    });

    try {
      final startResult = await PasskeyAuthService.startAuthentication(
        email: normalizedEmail,
      );

      if (!mounted) return;

      // Update the cache with the server response
      await _updateKnownPasskeyEmail(
        normalizedEmail,
        hasPasskey: startResult.hasPublicKeyOptions,
      );

      if (!mounted) return;

      setState(() {
        _hasPasskeyForEmail = startResult.hasPublicKeyOptions;
        _lastCheckedPasskeyEmail = normalizedEmail;
        _lastServerCheckedPasskeyEmail = normalizedEmail;
        _isCheckingPasskey = false;
      });
    } catch (e) {
      // On error, fall back to cached state
      if (!mounted) return;
      setState(() {
        _isCheckingPasskey = false;
      });
    }
  }

  void _onPasswordChanged() {
    if (_isSignUp) {
      setState(() {});
      return;
    }

    // Clear error message when user starts typing
    if (_errorMessage != null || _errorOAuthProvider != null) {
      _clearBootstrapErrorPref();
      setState(() {
        _errorMessage = null;
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      });
    }
  }

  void _onConfirmPasswordChanged() {
    if (_isSignUp) {
      // Rebuild so the confirm validator reflects the latest password value.
      setState(() {});
      return;
    }
    if (_errorMessage != null || _errorOAuthProvider != null) {
      _clearBootstrapErrorPref();
      setState(() {
        _errorMessage = null;
        _errorOAuthProvider = null;
        _errorRawMessage = null;
        _showingRawError = false;
      });
    }
  }

  Future<void> _showOfflineLanguageUnavailableDialog() async {
    final l10n = ref.read(localizationProvider);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        icon: const Icon(
          Icons.cloud_off_rounded,
          size: 32,
          color: Colors.orange,
        ),
        title: Text(l10n.getString('offlineLanguageUnavailableTitle')),
        content: Text(l10n.getString('offlineLanguageUnavailableMessage')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.getString('offlineOkButton')),
          ),
        ],
      ),
    );
  }

  List<AppLanguage> _fallbackPickerLanguages(
    List<AppLanguage> supportedLanguages,
  ) {
    if (supportedLanguages.isNotEmpty) {
      return supportedLanguages;
    }

    return [
      AppLanguage(code: 'en', displayName: 'English'),
      AppLanguage(code: 'es', displayName: 'Español'),
      AppLanguage(code: 'fr', displayName: 'Français'),
      AppLanguage(code: 'de', displayName: 'Deutsch'),
      AppLanguage(code: 'it', displayName: 'Italiano'),
      AppLanguage(code: 'pt', displayName: 'Português'),
      AppLanguage(code: 'ru', displayName: 'Русский'),
      AppLanguage(code: 'ja', displayName: '日本語'),
      AppLanguage(code: 'ko', displayName: '한국어'),
      AppLanguage(code: 'zh', displayName: '中文'),
      AppLanguage(
        code: 'ar',
        displayName: 'العربية',
        direction: TextDirection.rtl,
      ),
      AppLanguage(
        code: 'he',
        displayName: 'עברית',
        direction: TextDirection.rtl,
      ),
      AppLanguage(code: 'hi', displayName: 'हिन्दी'),
      AppLanguage(code: 'tr', displayName: 'Türkçe'),
      AppLanguage(code: 'nl', displayName: 'Nederlands'),
      AppLanguage(code: 'pl', displayName: 'Polski'),
    ];
  }

  void _showLanguagePicker(
    BuildContext context,
    List<AppLanguage> supportedLanguages,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = ref.watch(localizationProvider);
        final languageOptionsAsync = ref.watch(languageOptionsProvider);
        final isOffline = !(ref.watch(connectivityProvider).value ?? true);
        final fallbackLanguages = _fallbackPickerLanguages(supportedLanguages);

        Widget buildFallbackList() {
          final currentLanguageCode = l10n.currentLocale.languageCode
              .toLowerCase();
          return LanguagePickerList(
            entries: [
              for (final lang in fallbackLanguages)
                LanguagePickerEntry(
                  code: lang.code,
                  displayName: lang.displayName,
                  canUseNow:
                      !isOffline ||
                      lang.code == currentLanguageCode ||
                      lang.code == 'en',
                ),
            ],
            onSelected: (entry) async {
              Navigator.of(dialogContext).pop();
              await ref
                  .read(localizationProvider.notifier)
                  .setLocale(entry.code, fallbackLanguages);
            },
            onUnavailable: (_) async {
              Navigator.of(dialogContext).pop();
              if (mounted) {
                await _showOfflineLanguageUnavailableDialog();
              }
            },
          );
        }

        return AlertDialog(
          scrollable: true,
          title: Text(l10n.getString('authSelectLanguage')),
          // No `SizedBox(width: double.maxFinite)` here: the dialog sizes its
          // content intrinsically, so an infinite width left the tile subtree
          // unlaid-out (size: MISSING) and the rows could not be hit-tested —
          // the language list was visible but not selectable.
          content: languageOptionsAsync.when(
            data: (languages) => LanguagePickerList(
              entries: [
                for (final lang in languages)
                  LanguagePickerEntry(
                    code: lang['code'] as String,
                    displayName: lang['display'] as String,
                    canUseNow:
                        !(lang['offline'] as bool? ?? false) ||
                        ((lang['availableOffline'] as bool?) ??
                            (lang['cached'] as bool? ?? true)),
                  ),
              ],
              onSelected: (entry) async {
                final selectedLanguage = supportedLanguages.firstWhere(
                  (language) => language.code == entry.code,
                  orElse: () => supportedLanguages.firstWhere(
                    (language) =>
                        language.code == l10n.currentLocale.languageCode,
                    orElse: () => supportedLanguages.first,
                  ),
                );

                Navigator.of(dialogContext).pop();
                await ref
                    .read(localizationProvider.notifier)
                    .setLocale(selectedLanguage.code, supportedLanguages);
              },
              onUnavailable: (_) async {
                Navigator.of(dialogContext).pop();
                if (mounted) {
                  await _showOfflineLanguageUnavailableDialog();
                }
              },
            ),
            loading: buildFallbackList,
            error: (_, stackTrace) => buildFallbackList(),
          ),
        );
      },
    );
  }

  void _showForgotPasswordDialog() {
    final outerContext = context;
    final emailController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isLoading = false;

    showDialog(
      context: outerContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogBuildContext, setState) {
            final l10n = ref.watch(localizationProvider);
            String getString(String key) => l10n.getString(key);

            return AlertDialog(
              scrollable: true,
              title: Text(getString('authResetPasswordTitle')),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(getString('authResetPasswordMessage')),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: emailController,
                      decoration: InputDecoration(
                        labelText: getString('authEmail'),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        if (v == null || v.isEmpty) {
                          return getString('authEmailRequired');
                        }
                        final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
                        if (!emailRegex.hasMatch(v.trim())) {
                          return getString('authEmailInvalid');
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(getString('generalCancel')),
                ),
                ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setState(() => isLoading = true);

                          final email = emailController.text.trim();
                          final navigator = Navigator.of(dialogContext);
                          final scaffoldMessenger = ScaffoldMessenger.of(
                            dialogContext,
                          );
                          final l10nRead = ref.read(localizationProvider);

                          String errorText;
                          try {
                            await PasswordResetService.requestPasswordResetOtp(
                              email: email,
                              language: l10nRead.currentLocale.languageCode,
                            );
                            // Close dialog and navigate to OTP screen (OTP, not link)
                            navigator.pop();
                            if (!mounted) return;
                            final masked = email.length > 3
                                ? '${email[0]}***@${email.split('@').last}'
                                : email;
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10nRead.getString(
                                    'authResetPasswordOtpSent',
                                    params: {'email': masked},
                                  ),
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                            await Navigator.of(outerContext).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    PasswordResetOtpScreen(email: email),
                              ),
                            );
                          } catch (e) {
                            // Surface real error for debugging, then localize
                            debugPrint('[password-reset] request failed: $e');
                            final key =
                                ErrorLocalizationService.getErrorTranslationKey(
                                  e,
                                );
                            // If mapping is generic unexpected, show underlying message for diagnosis
                            if (key == 'authUnexpectedError' &&
                                e is PasswordResetException &&
                                e.message.isNotEmpty) {
                              errorText = e.message;
                            } else if (key == 'authUnexpectedError' &&
                                e is FunctionException) {
                              errorText =
                                  (e.details is Map &&
                                      (e.details as Map)['message'] != null)
                                  ? (e.details as Map)['message'].toString()
                                  : e.toString();
                            } else {
                              errorText = l10nRead.getString(key);
                            }
                            if (errorText ==
                                    l10nRead.getString('authUnexpectedError') &&
                                e is PasswordResetException) {
                              errorText =
                                  '${l10nRead.getString('authUnexpectedError')}: ${e.message}';
                            }
                            navigator.pop();
                            if (mounted) {
                              scaffoldMessenger.showSnackBar(
                                SnackBar(
                                  content: Text(errorText),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => isLoading = false);
                            }
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(getString('authSendResetPassword')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _onDebugLogoTap() {
    _debugTapCount++;
    _debugTapTimer?.cancel();
    _debugTapTimer = Timer(const Duration(seconds: 3), () {
      _debugTapCount = 0;
    });
    if (_debugTapCount >= 7) {
      _debugTapCount = 0;
      _debugTapTimer?.cancel();
      _showDebugSignOutReasonDialog();
    }
  }

  Future<void> _showDebugSignOutReasonDialog() async {
    final reason = await SessionService.getLastSignOutReason();
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('🔧 ${l10n.getString('authDebugLastSignOut')}'),
        content: Text(
          reason != null
              ? '${l10n.getString('authDebugReason')}: ${reason['reason']}\n'
                    '${l10n.getString('authDebugSource')}: ${reason['source']}\n'
                    '${l10n.getString('authDebugTime')}: ${reason['timestamp']}'
              : l10n.getString('authDebugNoSignOutReason'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              SessionService.clearPersistedSupabaseSessionSnapshot();
              Navigator.of(ctx).pop();
            },
            child: Text(l10n.getString('authClearSession')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.getString('generalClose')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_didLogBuild) {
      _didLogBuild = true;
      debugPrint('🔐🔐🔐 AuthScreen build');
    }
    final l10n = ref.watch(localizationProvider);
    // Watch authUiMessageProvider so the widget rebuilds when an OAuth error is
    // set (even if the ref.listen below was already registered and missed the
    // initial value). The watched value also prevents the spinner from blocking
    // the error message when _isLoading is still true.
    final authUiMessage = ref.watch(authUiMessageProvider);
    final authInteractionBlocked = _isLoading && authUiMessage == null;
    String getString(String key) => l10n.getString(key);
    String? displayErrorMessage;
    final rawErrorForDoubleTap = _errorRawMessage ?? _actualErrorMessage;
    if (authUiMessage != null) {
      final parts = authUiMessage.split('|||');
      final key = parts[0];
      final rawError = parts.length > 1 ? parts[1] : null;
      final providerName = parts.length > 2 ? parts[2] : null;
      if (providerName != null && providerName.isNotEmpty) {
        final provider = _parseOAuthProvider(providerName);
        if (provider != null) {
          displayErrorMessage = _buildOAuthErrorMessage(
            provider,
            rawError ?? '',
            l10n,
          );
        }
      }
      if (displayErrorMessage == null && key.isNotEmpty) {
        displayErrorMessage = getString(key);
      }
    } else if (_showingRawError && rawErrorForDoubleTap != null) {
      displayErrorMessage = rawErrorForDoubleTap;
    } else if (_errorOAuthProvider != null) {
      displayErrorMessage = _buildOAuthErrorMessage(
        _errorOAuthProvider!,
        _errorRawMessage ?? '',
        l10n,
      );
    } else if (_errorMessageKey != null) {
      displayErrorMessage = getString(_errorMessageKey!);
    } else {
      displayErrorMessage = _errorMessage;
    }
    // Fallback when setMessage arrives before ref.listen is registered.
    if (authUiMessage != null && authUiMessage != _lastAppliedAuthUiMessage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleIncomingAuthUiMessage(authUiMessage);
        ref.read(authUiMessageProvider.notifier).clear();
      });
    }
    final showIncorrectPasswordState =
        !_isSignUp && displayErrorMessage == getString('authIncorrectPassword');
    final incorrectPasswordBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: Colors.red.shade400, width: 1.6),
    );

    if (!_authUiMessageListenerRegistered) {
      ref.listen<String?>(authUiMessageProvider, (previous, next) {
        if (next == null || next.trim().isEmpty) return;
        if (!mounted) return;
        _handleIncomingAuthUiMessage(next);
        ref.read(authUiMessageProvider.notifier).clear();
      });
      _authUiMessageListenerRegistered = true;
    }

    // Check SharedPreferences for a bootstrap-stored OAuth error (processed
    // during the bootstrap phase before the widget tree existed).
    if (mounted &&
        _errorMessage == null &&
        _errorOAuthProvider == null &&
        _errorMessageKey == null) {
      SharedPreferences.getInstance().then((prefs) async {
        if (!mounted) return;
        final bootError = prefs.getString('oauth_bootstrap_error');
        if (bootError == null ||
            bootError.isEmpty ||
            bootError == _lastConsumedBootstrapError) {
          return;
        }
        if (!mounted) return;
        _lastConsumedBootstrapError = bootError;
        _handleIncomingAuthUiMessage(bootError);
      });
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leadingWidth: 120,
        leading: Consumer(
          builder: (context, ref, child) {
            // Use the interpreted connectivity status so the auth badge follows
            // the same resume/reconnect grace logic as the rest of the app.
            final healthAsync = ref.watch(connectivityHealthProvider);

            final isOffline = healthAsync.when(
              data: (health) =>
                  health.status == ConnectivityHealthStatus.offline,
              loading: () => false,
              error: (e, st) => false,
            );

            if (!isOffline) {
              return const SizedBox.shrink();
            }

            final l10n = ref.watch(localizationProvider);
            final color = Theme.of(context).colorScheme.error;

            return Padding(
              padding: const EdgeInsets.only(left: 8.0, right: 4.0),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  decoration: BoxDecoration(
                    color: color.withAlpha((0.1 * 255).round()),
                    borderRadius: BorderRadius.circular(16.0),
                    border: Border.all(
                      color: color.withAlpha((0.2 * 255).round()),
                      width: 1,
                    ),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Text(
                    l10n.getString('youAreOffline'),
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ),
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: getString('authSelectLanguage'),
            onPressed: () =>
                _showLanguagePicker(context, l10n.supportedLanguages),
          ),
        ],
      ),
      body: authInteractionBlocked
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/images/logo.png', height: 100),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                ],
              ),
            )
          : Center(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(24.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GestureDetector(
                        onTap: _onDebugLogoTap,
                        child: Image.asset(
                          'assets/images/logo.png',
                          height: 100,
                          width: 100,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 40),
                      Text(
                        _isSignUp
                            ? getString('authSignUp')
                            : getString('authLogin'),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: authInteractionBlocked
                                      ? null
                                      : () => _switchAuthMode(false),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _isSignUp
                                        ? Colors.transparent
                                        : Theme.of(context).colorScheme.primary,
                                    foregroundColor: _isSignUp
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onPrimary,
                                    elevation: _isSignUp ? 0 : null,
                                  ),
                                  child: Text(getString('authLogin')),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton(
                                  onPressed: authInteractionBlocked
                                      ? null
                                      : () => _switchAuthMode(true),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _isSignUp
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                    foregroundColor: _isSignUp
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                    elevation: _isSignUp ? null : 0,
                                  ),
                                  child: Text(getString('authSignUp')),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _isSignUp
                                    ? Icons.login_rounded
                                    : Icons.person_add_alt_1_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _isSignUp
                                      ? getString(
                                          'authAlreadyHaveAccountPrompt',
                                        )
                                      : getString('authNewHerePrompt'),
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 10),
                              TextButton(
                                onPressed: authInteractionBlocked
                                    ? null
                                    : () => _switchAuthMode(!_isSignUp),
                                child: Text(
                                  _isSignUp
                                      ? getString('authLogin')
                                      : getString('authSignUp'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      TextFormField(
                        controller: _emailController,
                        focusNode: _emailFocusNode,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [],
                        ),
                        decoration: InputDecoration(
                          labelText: getString('authEmail'),
                          prefixIcon: const Icon(Icons.email),
                          helperText: _isSignUp && !_isSignupEmailApproved
                              ? getString(
                                  'authPasswordLockedUntilEmailApproved',
                                )
                              : null,
                          suffixIcon: _isSignUp && _isCheckingSignupEmail
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) {
                          if (_isSignUp && !_isSignupEmailApproved) {
                            FocusScope.of(context).unfocus();
                            return;
                          }
                          FocusScope.of(
                            context,
                          ).requestFocus(_passwordFocusNode);
                        },
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return getString('authEmailRequired');
                          }
                          final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
                          if (!emailRegex.hasMatch(v.trim())) {
                            return getString('authEmailInvalid');
                          }
                          return null;
                        },
                      ),
                      if (_isSignUp && _emailFieldErrorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _emailFieldErrorMessage!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                                height: 1.35,
                              ),
                        ),
                      ],
                      if (_shouldShowPasskeySuggestion) ...[
                        const SizedBox(height: 16),
                        _buildPasskeySuggestionCard(
                          getString,
                          authInteractionBlocked: authInteractionBlocked,
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        focusNode: _passwordFocusNode,
                        readOnly: _isSignUp && !_isSignupEmailApproved,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [],
                        ),
                        decoration: InputDecoration(
                          labelText: getString('authPassword'),
                          prefixIcon: const Icon(Icons.lock),
                          filled: showIncorrectPasswordState,
                          fillColor: showIncorrectPasswordState
                              ? Colors.red.shade50
                              : null,
                          enabledBorder: showIncorrectPasswordState
                              ? incorrectPasswordBorder
                              : null,
                          focusedBorder: showIncorrectPasswordState
                              ? incorrectPasswordBorder.copyWith(
                                  borderSide: BorderSide(
                                    color: Colors.red.shade600,
                                    width: 2,
                                  ),
                                )
                              : null,
                          // suffix icon toggles password visibility
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                            tooltip: _obscurePassword
                                ? getString('authShowPassword')
                                : getString('authHidePassword'),
                          ),
                        ),
                        obscureText: _obscurePassword,
                        onTap: () {
                          if (_isSignUp && !_isSignupEmailApproved) {
                            FocusScope.of(context).unfocus();
                            return;
                          }
                          _scrollPasswordGuidanceIntoView();
                        },
                        textInputAction: _isSignUp
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (authInteractionBlocked) return;
                          if (_isSignUp) {
                            FocusScope.of(
                              context,
                            ).requestFocus(_confirmPasswordFocusNode);
                            return;
                          }
                          // validate first; if valid, unfocus and submit
                          final isValid =
                              _formKey.currentState?.validate() ?? false;
                          if (isValid) {
                            FocusScope.of(context).unfocus();
                            _performAuth();
                          } else {
                            // keep focus on password so user can correct it
                            FocusScope.of(
                              context,
                            ).requestFocus(_passwordFocusNode);
                          }
                        },
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return getString('authPasswordRequired');
                          }
                          if (_isSignUp && !_isSignupPasswordValid(v)) {
                            return getString('authPasswordRequirementsTitle');
                          }
                          return null;
                        },
                      ),
                      if (_isSignUp &&
                          _isPasswordFieldFocused &&
                          _hasApprovedSignupEmail &&
                          _emailFieldErrorMessage == null) ...[
                        const SizedBox(height: 12),
                        DecoratedBox(
                          key: _passwordRequirementsKey,
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
                                  getString('authPasswordRequirementsTitle'),
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 10),
                                _buildPasswordRequirementRow(
                                  context,
                                  met: _passwordHasMinLength(
                                    _passwordController.text,
                                  ),
                                  label: getString('authPasswordRuleMinLength'),
                                ),
                                const SizedBox(height: 6),
                                _buildPasswordRequirementRow(
                                  context,
                                  met: _passwordHasUppercase(
                                    _passwordController.text,
                                  ),
                                  label: getString('authPasswordRuleUppercase'),
                                ),
                                const SizedBox(height: 6),
                                _buildPasswordRequirementRow(
                                  context,
                                  met: _passwordHasLowercase(
                                    _passwordController.text,
                                  ),
                                  label: getString('authPasswordRuleLowercase'),
                                ),
                                const SizedBox(height: 6),
                                _buildPasswordRequirementRow(
                                  context,
                                  met: _passwordHasNumber(
                                    _passwordController.text,
                                  ),
                                  label: getString('authPasswordRuleNumber'),
                                ),
                                const SizedBox(height: 6),
                                _buildPasswordRequirementRow(
                                  context,
                                  met: _passwordHasSpecialCharacter(
                                    _passwordController.text,
                                  ),
                                  label: getString('authPasswordRuleSpecial'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (_isSignUp) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          focusNode: _confirmPasswordFocusNode,
                          readOnly: !_isSignupEmailApproved,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontFeatures: const []),
                          decoration: InputDecoration(
                            labelText: getString('authConfirmPassword'),
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirmPassword
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureConfirmPassword =
                                      !_obscureConfirmPassword;
                                });
                              },
                              tooltip: _obscureConfirmPassword
                                  ? getString('authShowPassword')
                                  : getString('authHidePassword'),
                            ),
                          ),
                          obscureText: _obscureConfirmPassword,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (authInteractionBlocked) return;
                            final isValid =
                                _formKey.currentState?.validate() ?? false;
                            if (isValid) {
                              FocusScope.of(context).unfocus();
                              _performAuth();
                            } else {
                              FocusScope.of(
                                context,
                              ).requestFocus(_confirmPasswordFocusNode);
                            }
                          },
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return getString('authConfirmPasswordRequired');
                            }
                            if (v != _passwordController.text) {
                              return getString('authPasswordsDoNotMatch');
                            }
                            return null;
                          },
                        ),
                      ],
                      const SizedBox(height: 30),
                      ElevatedButton(
                        onPressed: _isSignUp && !_isSignupEmailApproved
                            ? null
                            : () => _performAuth(),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(inherit: false),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _isSignUp
                                ? getString('authSignUp')
                                : getString('authLogin'),
                            key: ValueKey(_isSignUp),
                            style: const TextStyle(inherit: false),
                          ),
                        ),
                      ),
                      if (displayErrorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16.0),
                          child: GestureDetector(
                            onDoubleTap: () {
                              final raw =
                                  _errorRawMessage ?? _actualErrorMessage;
                              if (raw != null) {
                                setState(() {
                                  _showingRawError = !_showingRawError;
                                });
                              }
                            },
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.red.shade200),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.shade100.withValues(
                                      alpha: 0.6,
                                    ),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.error_outline,
                                      color: Colors.red.shade700,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        displayErrorMessage,
                                        style: TextStyle(
                                          color: Colors.red.shade800,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                            ),
                            child: Text(getString('authOr')),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildOAuthButton(
                        provider: OAuthProvider.google,
                        label: getString('authContinueWithGoogle'),
                        assetPath: 'assets/images/providers/google.png',
                        authInteractionBlocked: authInteractionBlocked,
                      ),
                      const SizedBox(height: 12),
                      _buildOAuthButton(
                        provider: OAuthProvider.azure,
                        label: getString('authContinueWithMicrosoft'),
                        assetPath: 'assets/images/providers/microsoft.png',
                        authInteractionBlocked: authInteractionBlocked,
                      ),
                      const SizedBox(height: 12),
                      _buildOAuthButton(
                        provider: OAuthProvider.apple,
                        label: getString('authContinueWithApple'),
                        assetPath: 'assets/images/providers/apple.png',
                        authInteractionBlocked: authInteractionBlocked,
                      ),
                      const SizedBox(height: 12),
                      _buildOAuthButton(
                        provider: OAuthProvider.facebook,
                        label: getString('authContinueWithFacebook'),
                        assetPath: 'assets/images/providers/facebook.png',
                        authInteractionBlocked: authInteractionBlocked,
                      ),
                      const SizedBox(height: 20),
                      TextButton(
                        onPressed: authInteractionBlocked
                            ? null
                            : () => _switchAuthMode(!_isSignUp),
                        child: Text(
                          _isSignUp
                              ? getString('authToggleToSignIn')
                              : getString('authToggleToSignUp'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: authInteractionBlocked
                            ? null
                            : _showForgotPasswordDialog,
                        child: Text(getString('authForgotPassword')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Completes when the user returns to the app during a loopback OAuth attempt.
/// See [_AuthScreenState._abandonLoopbackAfterResume].
class _LoopbackCancellation {
  final Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Internal signal: the user left the browser without completing the flow.
class _LoopbackAbandoned implements Exception {
  const _LoopbackAbandoned();

  @override
  String toString() => '_LoopbackAbandoned';
}
