// lib/screens/auth/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:matchme/services/session_service.dart';

final supabase = Supabase.instance.client;

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;
  bool _isSignUp = false;

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  // NEW: control whether the password is obscured
  bool _obscurePassword = true;

  bool _authUiMessageListenerRegistered = false;

  static const double _oauthProviderIconSize = 20;
  static const double _oauthButtonHeight = 48;

  String _mapPasswordAuthError(AuthException e, LocalizationState l10n) {
    final msg = e.message;
    final lower = msg.toLowerCase();
    if (lower.contains('invalid login credentials') ||
        lower.contains('invalid credentials') ||
        lower.contains('invalid') && lower.contains('credentials')) {
      return '${l10n.getString('authInvalidCredentials')} ${l10n.getString('authInvalidCredentialsTryOAuth')}';
    }
    return msg;
  }

  String _mapOAuthAuthError(AuthException e, LocalizationState l10n) {
    final msg = e.message;
    final lower = msg.toLowerCase();
    if (lower.contains('cancel') || lower.contains('canceled')) {
      return l10n.getString('authOAuthCancelled');
    }
    if (lower.contains('already registered') ||
        lower.contains('already exists') ||
        lower.contains('user already registered')) {
      return l10n.getString('authOAuthAccountExists');
    }
    return msg.isNotEmpty ? msg : l10n.getString('authOAuthFailed');
  }

  Widget _buildOAuthButton({
    required OAuthProvider provider,
    required String label,
    required String assetPath,
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
      onPressed: _isLoading ? null : () => _signInWithOAuth(provider),
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

  Future<void> _signInWithOAuth(OAuthProvider provider) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      const mobileRedirectTo = 'com.example.matchme://login-callback';
      final redirectTo = kIsWeb ? '${Uri.base.origin}/auth/callback' : mobileRedirectTo;
      final scopes = switch (provider) {
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

      await supabase.auth.signInWithOAuth(
        provider,
        redirectTo: redirectTo,
        scopes: scopes,
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _mapOAuthAuthError(e, ref.read(localizationProvider));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            '${ref.read(localizationProvider).getString('authUnexpectedError')}: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _performAuth(String checkEmailMessage) async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      // Get the localization provider reference BEFORE async operations
      // (ref becomes unsafe after widget unmounts due to navigation)
      final localizationNotifier = ref.read(localizationProvider.notifier);
      
      if (_isSignUp) {
        await supabase.auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(checkEmailMessage), backgroundColor: Colors.green),
        );
        _emailController.clear();
        _passwordController.clear();
        setState(() {
          _isSignUp = false;
        });
      } else {
        await supabase.auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );

        // Register session on the server (best effort, non-blocking)
        final user = supabase.auth.currentUser;
        if (user != null) {
          final platformText = _detectPlatform();
          try {
            await SessionService.registerSession(user.id, platform: platformText);
          } catch (e) {
            debugPrint('registerSession failed: $e');
          }

          // Sync language preference to database after login
          // This ensures the language selected on login screen is persisted to DB
          // Note: We got the notifier reference before login to avoid ref issues after navigation
          try {
            await localizationNotifier.syncLanguageAfterLogin();
          } catch (e) {
            debugPrint('syncLanguageAfterLogin failed: $e');
          }
        }
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _mapPasswordAuthError(e, ref.read(localizationProvider));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '${ref.read(localizationProvider).getString('authUnexpectedError')}: ${e.toString()}';
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
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
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
    _emailController.addListener(_onEmailChanged);
    _passwordController.addListener(_onPasswordChanged);
    // Request focus after first frame so the view is "served" and keyboard shows correctly (avoids showSoftInput ignored)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _emailFocusNode.canRequestFocus) {
        _emailFocusNode.requestFocus();
      }
    });
    // Clear error message when user starts typing
    _emailController.addListener(() {
      if (_errorMessage != null && _emailController.text.isNotEmpty) {
        setState(() {
          _errorMessage = null;
        });
      }
    });
    
    _passwordController.addListener(() {
      if (_errorMessage != null && _passwordController.text.isNotEmpty) {
        setState(() {
          _errorMessage = null;
        });
      }
    });
  }

  void _onEmailChanged() {
    // Clear error message when user starts typing
    if (_errorMessage != null) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  void _onPasswordChanged() {
    // Clear error message when user starts typing
    if (_errorMessage != null) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  void _showLanguagePicker(BuildContext context, List<AppLanguage> supportedLanguages) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(ref.watch(localizationProvider).getString('authSelectLanguage')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: supportedLanguages.length,
              itemBuilder: (context, index) {
                final lang = supportedLanguages[index];
                return ListTile(
                  title: Text(lang.displayName),
                  onTap: () {
                    ref.read(localizationProvider.notifier).setLocale(lang.code);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showForgotPasswordDialog() {
    final emailController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final l10n = ref.watch(localizationProvider);
            String getString(String key) => l10n.getString(key);

            return AlertDialog(
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
                      decoration: InputDecoration(labelText: getString('authEmail')),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        if (v == null || v.isEmpty) return getString('authEmailRequired');
                        final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
                        if (!emailRegex.hasMatch(v.trim())) return getString('authEmailInvalid');
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
                          
                          // Capture everything we need before any async operations
                          final navigator = Navigator.of(dialogContext);
                          final scaffoldMessenger = ScaffoldMessenger.of(dialogContext);
                          final successMessage = getString('authResetPasswordSent');
                          final errorMessage = getString('authResetPasswordFailed');
                          
                          // Perform async operation
                          bool success = false;
                          try {
                            await supabase.auth.resetPasswordForEmail(emailController.text.trim());
                            success = true;
                          } catch (e) {
                            success = false;
                          }
                          
                          // Close dialog using captured navigator
                          navigator.pop();
                          
                          // Handle UI updates using captured scaffoldMessenger
                          if (mounted) {
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text(success ? successMessage : errorMessage),
                                backgroundColor: success ? Colors.green : Colors.red,
                              ),
                            );
                            setState(() => isLoading = false);
                          }
                        },
                  child: isLoading ? const CircularProgressIndicator() : Text(getString('authSendResetPassword')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    String getString(String key) => l10n.getString(key);

    if (!_authUiMessageListenerRegistered) {
      ref.listen<String?>(authUiMessageProvider, (previous, next) {
        if (next == null || next.trim().isEmpty) return;
        if (!mounted) return;
        setState(() {
          _errorMessage = next;
        });
        ref.read(authUiMessageProvider.notifier).clear();
      });
      _authUiMessageListenerRegistered = true;
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: getString('authSelectLanguage'),
            onPressed: () => _showLanguagePicker(context, l10n.supportedLanguages),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Image.asset(
                  'assets/images/logo.png',
                  height: 100,
                  width: 100,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 40),
                Text(
                  _isSignUp ? getString('authSignUp') : getString('authLogin'),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
                TextFormField(
                  controller: _emailController,
                  focusNode: _emailFocusNode,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                  decoration:
                      InputDecoration(labelText: getString('authEmail'), prefixIcon: const Icon(Icons.email)),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) {
                    FocusScope.of(context).requestFocus(_passwordFocusNode);
                  },
                  validator: (v) {
                    if (v == null || v.isEmpty) return getString('authEmailRequired');
                    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
                    if (!emailRegex.hasMatch(v.trim())) return getString('authEmailInvalid');
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                  decoration: InputDecoration(
                    labelText: getString('authPassword'),
                    prefixIcon: const Icon(Icons.lock),
                    // suffix icon toggles password visibility
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                      tooltip: _obscurePassword ? getString('authShowPassword') : getString('authHidePassword'),
                    ),
                  ),
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) {
                    // validate first; if valid, unfocus and submit
                    if (_isLoading) return;
                    final isValid = _formKey.currentState?.validate() ?? false;
                    if (isValid) {
                      FocusScope.of(context).unfocus();
                      _performAuth(getString('authCheckEmail'));
                    } else {
                      // keep focus on password so user can correct it
                      FocusScope.of(context).requestFocus(_passwordFocusNode);
                    }
                  },
                  validator: (v) {
                    if (v == null || v.isEmpty) return getString('authPasswordRequired');
                    if (v.length < 8) return getString('authPasswordTooShort');
                    final passwordRegex = RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]');
                    if (!passwordRegex.hasMatch(v)) return getString('authPasswordWeak');
                    return null;
                  },
                ),
                const SizedBox(height: 30),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator())
                else
                  ElevatedButton(
                    onPressed: () => _performAuth(getString('authCheckEmail')),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(inherit: false),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        _isSignUp ? getString('authSignUp') : getString('authLogin'),
                        key: ValueKey(_isSignUp),
                        style: const TextStyle(inherit: false),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
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
                ),
                const SizedBox(height: 12),
                _buildOAuthButton(
                  provider: OAuthProvider.azure,
                  label: getString('authContinueWithMicrosoft'),
                  assetPath: 'assets/images/providers/microsoft.png',
                ),
                const SizedBox(height: 12),
                _buildOAuthButton(
                  provider: OAuthProvider.apple,
                  label: getString('authContinueWithApple'),
                  assetPath: 'assets/images/providers/apple.png',
                ),
                const SizedBox(height: 12),
                _buildOAuthButton(
                  provider: OAuthProvider.facebook,
                  label: getString('authContinueWithFacebook'),
                  assetPath: 'assets/images/providers/facebook.png',
                ),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          setState(() {
                            _isSignUp = !_isSignUp;
                            _errorMessage = null;
                          });
                        },
                  child: Text(_isSignUp ? getString('authToggleToSignIn') : getString('authToggleToSignUp')),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _isLoading ? null : _showForgotPasswordDialog,
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
