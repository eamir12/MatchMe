// lib/screens/settings/settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import '../../providers/main_intents_provider.dart';
import '../../providers/translation_version_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'dart:ui' as ui;
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/screens/settings/invisibility_rules_screen.dart';
import 'package:matchme/screens/settings/gender_age_preferences_screen.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/providers/theme_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.scrollToInvisibilityRules = false});

  final bool scrollToInvisibilityRules;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late String _currentUserId;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _invisibilityRulesKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
    Future.microtask(() async {
      await ref.read(profileEditProvider(_currentUserId).notifier).loadInitialProfile();
      if (widget.scrollToInvisibilityRules) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final context = _invisibilityRulesKey.currentContext;
          if (context != null) {
            Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 500), alignment: 0.1);
          }
        });
      }
    });
  }

  void _showChangePasswordDialog(BuildContext context, LocalizationState l10n) {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isLoading = false;
    bool obscureCurrent = true;
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
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
                      child: Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextFormField(
                              controller: currentPasswordController,
                              decoration: InputDecoration(
                                label: Text(l10n.getString('settingsCurrentPassword')),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureCurrent ? Icons.visibility_off : Icons.visibility),
                                  onPressed: () => setState(() => obscureCurrent = !obscureCurrent),
                                ),
                              ),
                              obscureText: obscureCurrent,
                              validator: (v) {
                                if (v == null || v.isEmpty) return l10n.getString('authPasswordRequired');
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: newPasswordController,
                              decoration: InputDecoration(
                                label: Text(l10n.getString('settingsNewPassword')),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureNew ? Icons.visibility_off : Icons.visibility),
                                  onPressed: () => setState(() => obscureNew = !obscureNew),
                                ),
                              ),
                              obscureText: obscureNew,
                              validator: (v) {
                                if (v == null || v.isEmpty) return l10n.getString('authPasswordRequired');
                                if (v.length < 8) return l10n.getString('authPasswordTooShort');
                                final passwordRegex = RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]');
                                if (!passwordRegex.hasMatch(v)) return l10n.getString('authPasswordWeak');
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: confirmPasswordController,
                              decoration: InputDecoration(
                                label: Text(l10n.getString('settingsConfirmNewPassword')),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureConfirm ? Icons.visibility_off : Icons.visibility),
                                  onPressed: () => setState(() => obscureConfirm = !obscureConfirm),
                                ),
                              ),
                              obscureText: obscureConfirm,
                              validator: (v) {
                                if (v != newPasswordController.text) return l10n.getString('settingsPasswordMismatch');
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
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      onPressed: isLoading
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              setState(() => isLoading = true);
                              try {
                                  await Supabase.instance.client.auth.updateUser(
                                    UserAttributes(password: newPasswordController.text),
                                  );
                                  if (!mounted) return;
                                  Navigator.of(this.context).pop();
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(this.context).showSnackBar(
                                    SnackBar(content: Text(l10n.getString('settingsPasswordChanged')), backgroundColor: Colors.green),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  Navigator.of(this.context).pop();
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(this.context).showSnackBar(
                                    SnackBar(content: Text(l10n.getString('settingsPasswordChangeFailed')), backgroundColor: Colors.red),
                                  );
                                } finally {
                                  if (mounted) setState(() => isLoading = false);
                                }
                            },
                      child: isLoading ? const CircularProgressIndicator() : Text(l10n.getString('generalSave')),
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

  void _showDeleteAccountDialog(BuildContext context, LocalizationState l10n) {
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
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final currentContext = context;
                final currentL10n = l10n;
                Navigator.pop(dialogContext);
                
                // Check if user is authenticated
                final currentUser = Supabase.instance.client.auth.currentUser;
                if (currentUser == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(currentContext).showSnackBar(
                      SnackBar(content: Text(currentL10n.getString('settingsDeleteAccountFailed')), backgroundColor: Colors.red),
                    );
                  }
                  return;
                }

                // Get the current session token
                final session = Supabase.instance.client.auth.currentSession;
                if (session == null || session.accessToken.isEmpty) {
                  if (mounted) {
                    ScaffoldMessenger.of(currentContext).showSnackBar(
                      SnackBar(content: Text(currentL10n.getString('settingsDeleteAccountFailed')), backgroundColor: Colors.red),
                    );
                  }
                  return;
                }

                try {
                  // Call the delete-account Supabase function with explicit headers
                  final response = await Supabase.instance.client.functions.invoke(
                    'delete-account',
                    headers: {
                      'Authorization': 'Bearer ${session.accessToken}',
                    },
                  );

                  if (response.status == 200 || response.status == 404) {
                    // Success: either account deleted (200) or user already doesn't exist (404)
                    // Clear local storage and sign out
                    try {
                      // Sign out from Supabase (this will clear the session)
                      // Note: This might fail with 403 if user was already deleted from auth
                      await Supabase.instance.client.auth.signOut().catchError((error) {
                        // Continue anyway - the session will be cleared when app restarts
                      });
                      
                      // Clear all local database (Hive boxes)
                      final localDb = await LocalDbService.instance;
                      await localDb.clearDatabase();

                      // Try to revoke sessions before sign out (best-effort)
                      try {
                        final user = Supabase.instance.client.auth.currentUser;
                        if (user != null) {
                          await Supabase.instance.client.rpc('revoke_all_user_sessions', params: {'p_user_id': user.id});
                        }
                      } catch (e) {
                        debugPrint('revoke_all_user_sessions failed: $e');
                      }

                      // Clear other cached data if needed
                      // Note: Riverpod providers will be reset when the app restarts

                    } catch (clearError) {
                      // Continue anyway - the account is deleted from server or user doesn't exist
                    }
                    
                    if (mounted) {
                      final message = response.status == 200 
                        ? l10n.getString('settingsAccountDeleted')
                        : l10n.getString('settingsAccountAlreadyDeleted');
                      ScaffoldMessenger.of(currentContext).showSnackBar( // ignore: use_build_context_synchronously
                        SnackBar(
                          content: Text(message),
                          backgroundColor: Colors.green,
                        ),
                      );
                      // Pop all routes to return to the root screen
                      // The auth state will automatically show the login screen when session is cleared
                      Navigator.of(currentContext).popUntil((route) => route.isFirst); // ignore: use_build_context_synchronously
                    }
                  } else {
                    final errorMessage = response.data?['error'] ?? 'Unknown error (status: ${response.status})';
                    throw Exception(errorMessage);
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(currentContext).showSnackBar( // ignore: use_build_context_synchronously
                      SnackBar(content: Text('${currentL10n.getString('settingsDeleteAccountFailed')}: $e'), backgroundColor: Colors.red),
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
    final profileEditState = ref.watch(profileEditProvider(_currentUserId));
    // Ensure language options are watched so the dropdown renders and stays stable
    final languageOptionsAsync = ref.watch(languageOptionsProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    final useImperialAsync = ref.watch(unitSystemProvider);
    final prefs = ref.watch(userPreferencesProvider);

    // Compute an immediate, synchronous value to avoid UI flicker while the
    // async provider resolves (useful when switching to System preference).
    final effectiveUseImperial = useImperialAsync.maybeWhen(
      data: (v) => v,
      orElse: () {
        final unitPref = prefs.unitSystem;
        if (unitPref == UnitSystemPreference.imperial) return true;
        if (unitPref == UnitSystemPreference.metric) return false;
        // System: derive from device locale immediately when possible.
        final deviceCountry = ui.PlatformDispatcher.instance.locale.countryCode ?? '';
        if (deviceCountry.isNotEmpty) return usesImperialUnitsByCountry(deviceCountry);
        return false;
      },
    );

    // Theme-aware helpers
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsTitle')),
        actions: [
          if (!isOnline)
            Container(
              margin: const EdgeInsets.only(right: 8.0),
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Row(
                children: [
                  Icon(Icons.wifi_off, size: 14, color: colors.onPrimaryContainer),
                  const SizedBox(width: 4),
                  Text(
                    l10n.getString('generalOffline'),
                    style: TextStyle(color: colors.onPrimaryContainer, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: SafeArea(child: profileEditState.when(
        data: (profile) {
          if (profile == null) return Center(child: Text(l10n.getString('generalErrorLoadingProfile')));

          return ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16.0),
            children: [
              // App Display Section
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
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.settings_display, color: colors.primary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          l10n.getString('settingsAppDisplay'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    languageOptionsAsync.when(
                      data: (languages) => DropdownButtonFormField<String>(
                        key: ValueKey(l10n.currentLocale.languageCode),
                        initialValue: l10n.currentLocale.languageCode,
                        decoration: InputDecoration(
                          labelText: l10n.getString('profileAppLanguage'),
                          prefixIcon: Icon(Icons.language_outlined, color: colors.primary),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: theme.dividerColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: theme.dividerColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: colors.primary, width: 2),
                          ),
                          filled: true,
                          fillColor: colors.surface,
                        ),
                        items: languages.map((lang) => DropdownMenuItem(value: lang['code'], child: Text(lang['display']!))).toList(),
                        onChanged: (value) {
                          if (value == null) return;

                          // Defer provider/state updates until after this build frame completes.
                          WidgetsBinding.instance.addPostFrameCallback((_) async {
                            if (!mounted) return;
                            // 1) Update app localization state (await so it completes)
                            await ref.read(localizationProvider.notifier).setLocale(value);

                            // 2) Persist the user's preferred language on their profile (best-effort)
                            try {
                              ref.read(profileEditProvider(_currentUserId).notifier).updatePreferredLanguage(value);
                            } catch (_) {}

                            // 3) Bump translationVersionProvider to force per-message translation providers to re-run.
                            ref.read(translationVersionProvider.notifier).increment();
                          });
                        },
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (e,s) => Text(l10n.getString('generalError')),
                    ),

                    const SizedBox(height: 16),

                    // Units preference (system/metric/imperial)
                    DropdownButtonFormField<UnitSystemPreference>(
                      key: ValueKey(prefs.unitSystem),
                      initialValue: prefs.unitSystem,
                      decoration: InputDecoration(
                        labelText: l10n.getString('settingsUnits'),
                        prefixIcon: Icon(Icons.straighten_outlined, color: colors.primary),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colors.primary, width: 2),
                        ),
                        filled: true,
                        fillColor: colors.surface,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: UnitSystemPreference.system,
                          child: Text(l10n.getString('settingsUnitsSystem')),
                        ),
                        DropdownMenuItem(
                          value: UnitSystemPreference.metric,
                          child: Text(l10n.getString('settingsUnitsMetric')),
                        ),
                        DropdownMenuItem(
                          value: UnitSystemPreference.imperial,
                          child: Text(l10n.getString('settingsUnitsImperial')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        ref.read(userPreferencesProvider.notifier).setUnitSystem(value);
                      },
                    ),

                    const SizedBox(height: 16),

                    // Time format preference (system/24h/12h)
                    DropdownButtonFormField<TimeFormatPreference>(
                      key: ValueKey(prefs.timeFormat),
                      initialValue: prefs.timeFormat,
                      decoration: InputDecoration(
                        labelText: l10n.getString('settingsTimeFormat'),
                        prefixIcon: Icon(Icons.schedule_outlined, color: colors.primary),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colors.primary, width: 2),
                        ),
                        filled: true,
                        fillColor: colors.surface,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: TimeFormatPreference.system,
                          child: Text(l10n.getString('settingsTimeFormatSystem')),
                        ),
                        DropdownMenuItem(
                          value: TimeFormatPreference.h24,
                          child: Text(l10n.getString('settingsTimeFormat24')),
                        ),
                        DropdownMenuItem(
                          value: TimeFormatPreference.h12,
                          child: Text(l10n.getString('settingsTimeFormat12')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        ref.read(userPreferencesProvider.notifier).setTimeFormat(value);
                      },
                    ),

                    const SizedBox(height: 16),

                    // Theme mode (System / Light / Dark)
                    DropdownButtonFormField<ThemeMode>(
                      key: ValueKey(ref.watch(themeModeProvider)),
                      initialValue: ref.watch(themeModeProvider),
                      decoration: InputDecoration(
                        labelText: l10n.getString('settingsThemeMode'),
                        prefixIcon: Icon(Icons.dark_mode_outlined, color: colors.primary),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                        filled: true,
                        fillColor: colors.surface,
                      ),
                      items: [
                        DropdownMenuItem(value: ThemeMode.system, child: Text(l10n.getString('settingsThemeModeSystem'))),
                        DropdownMenuItem(value: ThemeMode.light, child: Text(l10n.getString('settingsThemeModeLight'))),
                        DropdownMenuItem(value: ThemeMode.dark, child: Text(l10n.getString('settingsThemeModeDark'))),
                      ],
                      onChanged: (mode) {
                        if (mode == null) return;
                        ref.read(themeModeProvider.notifier).setThemeMode(mode);
                      },
                    ),
                  ],
                ),
              ),

              // Matching Section
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
                ),                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colors.secondary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.favorite_border, color: colors.secondary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          l10n.getString('settingsMatching'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Builder(
                      builder: (context) {
                        final allowedRadii = [5, 10, 20, 100];
                        final currentRadius = profile.matchRadiusDefault;
                        final radii = Set<int>.from(allowedRadii)..add(currentRadius);
                        final sortedRadii = radii.toList()..sort();
                        return DropdownButtonFormField<int>(
                          key: ValueKey(currentRadius),
                          initialValue: currentRadius,
                          decoration: InputDecoration(
                            labelText: l10n.getString('settingsRadius'),
                            prefixIcon: Icon(Icons.radar_outlined, color: colors.secondary),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: colors.secondary, width: 2),
                            ),
                            filled: true,
                            fillColor: colors.surface,
                          ),
                          items: sortedRadii.map((radius) => DropdownMenuItem(
                            value: radius,
                            child: Text(formatDistanceWithImperial(radius.toDouble(), effectiveUseImperial, l10n)),
                          )).toList(),
                          onChanged: (value) async {
                            if (value != null && allowedRadii.contains(value)) {
                              try {
                                await ref.read(profileEditProvider(_currentUserId).notifier).updateRadius(value);
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(content: Text('${l10n.getString('settingsRadiusUpdateFailed')}: $e'), backgroundColor: Colors.red),
                                );
                              }
                            }
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Builder(
                      builder: (context) {
                        final allowedRates = [5, 10, 20, 30, 60];
                        final currentRate = profile.gpsIntervalDefault;
                        final rates = Set<int>.from(allowedRates)..add(currentRate);
                        final sortedRates = rates.toList()..sort();
                        return DropdownButtonFormField<int>(
                          key: ValueKey(currentRate),
                          initialValue: currentRate,
                          decoration: InputDecoration(
                            labelText: l10n.getString('settingsGpsRate'),
                            prefixIcon: Icon(Icons.timer_outlined, color: colors.tertiary),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: colors.tertiary, width: 2),
                            ),
                            filled: true,
                            fillColor: colors.surface,
                          ),
                          items: sortedRates.map((rate) => DropdownMenuItem(
                            value: rate,
                            child: Text('${rate.toString()} ${l10n.getString('settingsGpsRateUnit')}'),
                          )).toList(),
                          onChanged: (value) async {
                             if (value != null && allowedRates.contains(value)) {
                               try {
                                 await ref.read(profileEditProvider(_currentUserId).notifier).updateGpsRate(value);
                                 // updateGpsRate() already directly notifies VisibilityNotifier and triggers immediate location update
                                 if (!mounted) return;
                                 // ignore: use_build_context_synchronously
                                 ScaffoldMessenger.of(this.context).showSnackBar(
                                     SnackBar(content: Text(l10n.getString('settingsGpsRateUpdated')), backgroundColor: Colors.green),
                                   );
                               } catch (e) {
                                 if (!mounted) return;
                                 // ignore: use_build_context_synchronously
                                 ScaffoldMessenger.of(this.context).showSnackBar(
                                     SnackBar(content: Text('${l10n.getString('settingsGpsRateUpdateFailed')}: $e'), backgroundColor: Colors.red),
                                   );
                               }
                             }
                           },
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsSmartGpsThrottling'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: profile.smartGpsThrottlingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref.read(profileEditProvider(_currentUserId).notifier).updateSmartGpsThrottling(value);
                              // Update the location stream interval to apply throttling changes immediately
                              await ref.read(isVisibleProvider.notifier).updateLocationStreamInterval();
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text(l10n.getString('settingsSmartGpsThrottlingUpdated')), backgroundColor: Theme.of(this.context).colorScheme.primary),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('${l10n.getString('settingsSmartGpsThrottlingUpdateFailed')}: $e'), backgroundColor: Colors.red),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(context).colorScheme.tertiary,
                          activeTrackColor: Theme.of(context).colorScheme.tertiary.withValues(alpha:0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsSharedEventMatching'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: profile.sharedEventMatchingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref.read(profileEditProvider(_currentUserId).notifier).updateSharedEventMatching(value);
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text(l10n.getString('settingsSharedEventMatchingUpdated')), backgroundColor: Colors.green),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('${l10n.getString('settingsSharedEventMatchingUpdateFailed')}: $e'), backgroundColor: Theme.of(this.context).colorScheme.error),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(context).colorScheme.secondary,
                          activeTrackColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsSharedMovementMatching'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: profile.sharedMovementMatchingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref.read(profileEditProvider(_currentUserId).notifier).updateSharedMovementMatching(value);
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text(l10n.getString('settingsSharedMovementMatchingUpdated')), backgroundColor: Colors.green),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('${l10n.getString('settingsSharedMovementMatchingUpdateFailed')}: $e'), backgroundColor: Theme.of(this.context).colorScheme.error),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(context).colorScheme.secondary,
                          activeTrackColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.3),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Gender and Age Preferences Section - Navigate to dedicated screen
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const GenderAgePreferencesScreen()),
                    );
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                          Theme.of(context).colorScheme.primary.withValues(alpha:0.05),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha:0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.people_alt_outlined, color: Theme.of(context).colorScheme.primary, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.getString('settingsGenderAgePreferences'),
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.getString('settingsGenderAgePreferencesDesc'),
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_forward_ios, color: Theme.of(context).colorScheme.primary, size: 16),
                      ],
                    ),
                  ),
                ),
              ),

              // Invisibility Rules Section - Navigate to dedicated screen
              Container(
                key: _invisibilityRulesKey,
                margin: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const InvisibilityRulesScreen()),
                    );
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                          Theme.of(context).colorScheme.primary.withValues(alpha:0.05),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha:0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.visibility_off, color: Theme.of(context).colorScheme.primary, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.getString('settingsInvisibilityRules'),
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.getString('settingsInvisibilityRulesDesc'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.arrow_forward_ios,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),


              // Account Management (Change Password + Delete Account)
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
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha:0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.person, color: colors.error, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          l10n.getString('settingsAccountManagement'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Render both primary account action buttons side-by-side on all screen sizes.
                    // Titles above the buttons are removed because the button labels are descriptive.
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _showChangePasswordDialog(context, l10n),
                            icon: const Icon(Icons.edit),
                            label: Text(l10n.getString('settingsChangePassword')),
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              backgroundColor: Theme.of(context).colorScheme.error,
                              foregroundColor: Theme.of(context).colorScheme.onError,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _showDeleteAccountDialog(context, l10n),
                            icon: const Icon(Icons.delete_forever),
                            label: Text(l10n.getString('settingsDeleteAccount')),
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),

                  ],
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${l10n.getString('generalError')}: $e', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: () => ref.read(profileEditProvider(_currentUserId).notifier).loadInitialProfile(),
                child: Text(l10n.getString('generalRetry')),
              )
            ],
          ),
        )),
      )),
    );
  }
}
