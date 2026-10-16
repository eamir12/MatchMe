import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/currency_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import '../../providers/main_intents_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/widgets/currency_picker_bottom_sheet.dart';
import 'package:matchme/widgets/safe_text.dart';

class AppDisplaySettingsScreen extends ConsumerStatefulWidget {
  const AppDisplaySettingsScreen({super.key});

  @override
  ConsumerState<AppDisplaySettingsScreen> createState() =>
      _AppDisplaySettingsScreenState();
}

class _AppDisplaySettingsScreenState
    extends ConsumerState<AppDisplaySettingsScreen> {
  late String _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final languageOptionsAsync = ref.watch(languageOptionsProvider);
    final prefs = ref.watch(userPreferencesProvider);
    final preferredCurrency = ref.watch(
      effectiveUserCurrencyProvider.select(
        (state) => state.asData?.value ?? 'USD',
      ),
    );
    final prioritizedCurrencies = ref.watch(
      prioritizedCurrencyCodesProvider.select(
        (state) => state.asData?.value ?? const <String>[],
      ),
    );
    final allCurrencyOptions = ref.watch(allCurrencyOptionsProvider);

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('settingsAppDisplay'))),
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
                languageOptionsAsync.when(
                  data: (languages) {
                    final items = <DropdownMenuItem<String>>[];

                    for (final lang in languages) {
                      final langCode = lang['code'] as String;
                      final display = lang['display'] as String;
                      final isCached = (lang['cached'] as bool?) ?? true;
                      final isAvailableOffline =
                          (lang['availableOffline'] as bool?) ?? isCached;
                      final isOffline = (lang['offline'] as bool?) ?? false;
                      final canUseNow = !isOffline || isAvailableOffline;

                      items.add(
                        DropdownMenuItem<String>(
                          value: langCode,
                          child: Row(
                            children: [
                              Text(
                                display,
                                style: TextStyle(
                                  color: canUseNow
                                      ? null
                                      : Colors.grey.shade400,
                                  fontWeight: !canUseNow
                                      ? FontWeight.normal
                                      : null,
                                ),
                              ),
                              if (!canUseNow)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: 16,
                                    color: Colors.grey.shade400,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }

                    return DropdownButtonFormField<String>(
                      key: ValueKey(l10n.currentLocale.languageCode),
                      initialValue: l10n.currentLocale.languageCode,
                      decoration: InputDecoration(
                        labelText: l10n.getString('profileAppLanguage'),
                        prefixIcon: Icon(
                          Icons.language_outlined,
                          color: colors.primary,
                        ),
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
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 2,
                          ),
                        ),
                        filled: true,
                        fillColor: colors.surface,
                      ),
                      items: items,
                      onChanged: (value) async {
                        if (value == null) return;

                        final selectedLang = languages.firstWhere(
                          (l) => l['code'] == value,
                        );
                        final isCached =
                            (selectedLang['cached'] as bool?) ?? true;
                        final isAvailableOffline =
                            (selectedLang['availableOffline'] as bool?) ??
                            isCached;
                        final isOffline =
                            (selectedLang['offline'] as bool?) ?? false;

                        if (!isAvailableOffline && isOffline && mounted) {
                          await showDialog<void>(
                            context: context,
                            builder: (BuildContext ctx) => AlertDialog(
                              icon: const Icon(
                                Icons.cloud_off_rounded,
                                size: 32,
                                color: Colors.orange,
                              ),
                              title: Text(
                                l10n.getString(
                                  'offlineLanguageUnavailableTitle',
                                ),
                              ),
                              content: Text(
                                l10n.getString(
                                  'offlineLanguageUnavailableMessage',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: Text(
                                    l10n.getString('offlineOkButton'),
                                  ),
                                ),
                              ],
                            ),
                          );
                          return;
                        }

                        final localizationNotifier = ref.read(
                          localizationProvider.notifier,
                        );
                        await localizationNotifier.setLocale(value);
                        if (!mounted) return;

                        if (!isOffline) {
                          try {
                            ref
                                .read(
                                  profileEditProvider(_currentUserId).notifier,
                                )
                                .updatePreferredLanguage(value);
                          } catch (_) {}
                        }
                        if (!mounted) return;

                        ref
                            .read(translationVersionProvider.notifier)
                            .increment();
                      },
                    );
                  },
                  loading: () => const LinearProgressIndicator(),
                  error: (e, s) => Text(l10n.getString('generalError')),
                ),

                const SizedBox(height: 16),

                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final picked = await showCurrencyPickerBottomSheet(
                      context: context,
                      l10n: l10n,
                      selectedCurrency: preferredCurrency,
                      recentCurrencyCodes: prefs.recentCurrencies,
                      prioritizedCurrencyCodes: prioritizedCurrencies,
                      allCurrencyOptions: allCurrencyOptions,
                    );
                    if (picked == null || !context.mounted) return;
                    await ref
                        .read(userPreferencesProvider.notifier)
                        .setPreferredCurrency(picked);
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.getString('settingsCurrencyPreference'),
                      prefixIcon: Icon(
                        Icons.currency_exchange_outlined,
                        color: colors.primary,
                      ),
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
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currencySelectedLabel(
                                  preferredCurrency,
                                  localeCode: l10n.currentLocale.languageCode,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_drop_down,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                DropdownButtonFormField<UnitSystemPreference>(
                  key: ValueKey(prefs.unitSystem),
                  initialValue: prefs.unitSystem,
                  decoration: InputDecoration(
                    labelText: l10n.getString('settingsUnits'),
                    prefixIcon: Icon(
                      Icons.straighten_outlined,
                      color: colors.primary,
                    ),
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
                    ref
                        .read(userPreferencesProvider.notifier)
                        .setUnitSystem(value);
                  },
                ),

                const SizedBox(height: 16),

                DropdownButtonFormField<TimeFormatPreference>(
                  key: ValueKey(prefs.timeFormat),
                  initialValue: prefs.timeFormat,
                  decoration: InputDecoration(
                    labelText: l10n.getString('settingsTimeFormat'),
                    prefixIcon: Icon(
                      Icons.schedule_outlined,
                      color: colors.primary,
                    ),
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
                    ref
                        .read(userPreferencesProvider.notifier)
                        .setTimeFormat(value);
                  },
                ),

                const SizedBox(height: 16),

                DropdownButtonFormField<ThemeMode>(
                  key: ValueKey(ref.watch(themeModeProvider)),
                  initialValue: ref.watch(themeModeProvider),
                  decoration: InputDecoration(
                    labelText: l10n.getString('settingsThemeMode'),
                    prefixIcon: Icon(
                      Icons.dark_mode_outlined,
                      color: colors.primary,
                    ),
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
                      value: ThemeMode.system,
                      child: Text(l10n.getString('settingsThemeModeSystem')),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text(l10n.getString('settingsThemeModeLight')),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text(l10n.getString('settingsThemeModeDark')),
                    ),
                  ],
                  onChanged: (mode) {
                    if (mode == null) return;
                    ref.read(themeModeProvider.notifier).setThemeMode(mode);
                  },
                ),

                const SizedBox(height: 8),

                SwitchListTile(
                  value: ref.watch(amoledThemeProvider),
                  onChanged: theme.brightness == Brightness.dark
                      ? (value) {
                          ref
                              .read(amoledThemeProvider.notifier)
                              .setEnabled(value);
                        }
                      : null,
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.contrast_outlined,
                    color: colors.primary,
                  ),
                  title: Text(l10n.getString('settingsAmoledMode')),
                  subtitle: Text(
                    l10n.getString('settingsAmoledModeDescription'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                SwitchListTile(
                  value: ref.watch(voiceGuidanceEnabledProvider),
                  onChanged: (value) {
                    ref
                        .read(voiceGuidanceEnabledProvider.notifier)
                        .setEnabled(value);
                  },
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.record_voice_over_outlined,
                    color: colors.primary,
                  ),
                  title: Text(l10n.getString('voiceGuidanceSettingsLabel')),
                  subtitle: Text(
                    l10n.getString('voiceGuidanceSettingsDescription'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
