// lib/screens/auth/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  // Focus node for the password field so we can advance focus from email -> password
  final FocusNode _passwordFocusNode = FocusNode();

  // NEW: control whether the password is obscured
  bool _obscurePassword = true;

  Future<void> _performAuth(String checkEmailMessage) async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
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
        }
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
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
                          if (mounted) {
                            try {
                              await supabase.auth.resetPasswordForEmail(emailController.text.trim());
                              Navigator.pop(dialogContext); // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                                SnackBar(content: Text(getString('authResetPasswordSent')), backgroundColor: Colors.green),
                              );
                            } catch (e) {
                              Navigator.pop(dialogContext); // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                                SnackBar(content: Text(getString('authResetPasswordFailed')), backgroundColor: Colors.red),
                              );
                            } finally {
                              setState(() => isLoading = false);
                            }
                          }
                        },
                  child: isLoading ? const CircularProgressIndicator() : Text(getString('authSignUp')),
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
                  autofocus: true,
                  decoration:
                      InputDecoration(labelText: getString('authEmail'), prefixIcon: const Icon(Icons.email)),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) {
                    // move focus to password when Enter/Next pressed on email
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
