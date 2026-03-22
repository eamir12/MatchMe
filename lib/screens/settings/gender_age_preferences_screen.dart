// lib/screens/settings/gender_age_preferences_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../providers/new_options_provider.dart';

class GenderAgePreferencesScreen extends ConsumerStatefulWidget {
  const GenderAgePreferencesScreen({super.key});

  @override
  ConsumerState<GenderAgePreferencesScreen> createState() => _GenderAgePreferencesScreenState();
}

class _GenderAgePreferencesScreenState extends ConsumerState<GenderAgePreferencesScreen> {
  late String _currentUserId;
  final _strictEnforcement = ValueNotifier<bool>(false);
  final _genderPreferences = ValueNotifier<Map<String, List<String>>>({});
  final _agePreferences = ValueNotifier<Map<String, List<double>>>({});
  bool _preferencesInitialized = false;
  bool _updatingFromProfile = false;
  Map<String, List<String>> _lastAppliedGenderPreferences = {};
  Map<String, List<double>> _lastAppliedAgePreferences = {};
  bool _lastAppliedStrictEnforcement = false;
  bool _hasAppliedRemotePreferences = false;

  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
    _strictEnforcement.addListener(_onStrictEnforcementChanged);
    _genderPreferences.addListener(_onPreferencesChanged);
    _agePreferences.addListener(_onPreferencesChanged);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _strictEnforcement.dispose();
    _genderPreferences.dispose();
    _agePreferences.dispose();
    super.dispose();
  }

  void _onStrictEnforcementChanged() {
    if (!_preferencesInitialized || _updatingFromProfile) return;
    _savePreferences();
  }

  void _onPreferencesChanged() {
    if (!_preferencesInitialized || _updatingFromProfile) return;
    _debounceSave();
  }

  void _debounceSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _savePreferences);
  }

  bool _stringMapListEquals(Map<String, List<String>> a, Map<String, List<String>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || !listEquals(entry.value, other)) return false;
    }
    return true;
  }

  bool _doubleMapListEquals(Map<String, List<double>> a, Map<String, List<double>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || !listEquals(entry.value, other)) return false;
    }
    return true;
  }

  Map<String, List<String>> _cloneGenderPrefs(Map<String, List<String>> value) {
    return Map<String, List<String>>.from(
      value.map((key, list) => MapEntry(key, List<String>.from(list))),
    );
  }

  Map<String, List<double>> _cloneAgePrefs(Map<String, List<double>> value) {
    return Map<String, List<double>>.from(
      value.map((key, list) => MapEntry(key, List<double>.from(list))),
    );
  }

  void _applyProfilePreferences(UserProfile profile) {
    final nextStrict = profile.strictGenderAgeEnforcement;
    final nextGender = _cloneGenderPrefs(profile.genderPreferences);
    final nextAge = _cloneAgePrefs(profile.agePreferences);

    final changedFromLastApplied = !_hasAppliedRemotePreferences ||
        _lastAppliedStrictEnforcement != nextStrict ||
        !_stringMapListEquals(_lastAppliedGenderPreferences, nextGender) ||
        !_doubleMapListEquals(_lastAppliedAgePreferences, nextAge);

    if (!changedFromLastApplied && _preferencesInitialized) {
      return;
    }

    _updatingFromProfile = true;
    _strictEnforcement.value = nextStrict;
    _genderPreferences.value = nextGender;
    _agePreferences.value = nextAge;
    _preferencesInitialized = true;
    _lastAppliedStrictEnforcement = nextStrict;
    _lastAppliedGenderPreferences = _cloneGenderPrefs(nextGender);
    _lastAppliedAgePreferences = _cloneAgePrefs(nextAge);
    _hasAppliedRemotePreferences = true;
    _updatingFromProfile = false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final mainIntents = ref.watch(mainIntentsProvider);
    final genderOptionsAsync = ref.watch(genderOptionsProvider);
    final profileAsync = ref.watch(userProfileProvider(_currentUserId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsGenderAgePreferences')),
      ),
      body: genderOptionsAsync.when(
        data: (genderOptions) => profileAsync.when(
          data: (profile) {
            if (profile == null) {
              return Center(child: Text(l10n.getString('generalErrorLoadingProfile')));
            }

            _applyProfilePreferences(profile);

            final selectedIntentKeys = profile.activeModes;
            final selectedIntents = mainIntents.where((intent) => selectedIntentKeys.contains(intent.key)).toList();

            if (selectedIntents.isEmpty) {
              return Center(child: Text(l10n.getString('settingsNoIntentsSelected')));
            }

            return ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // Strict vs Prioritize Toggle
                ValueListenableBuilder<bool>(
                  valueListenable: _strictEnforcement,
                  builder: (context, strictEnforcement, _) => Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
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
                            Expanded(
                              child: Text(
                                l10n.getString('settingsEnforcementMode'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.info_outline),
                              tooltip: 'Enforcement details',
                              onPressed: () {
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.getString('settingsEnforcementHelpTitle')),
                                    content: Text(l10n.getString('settingsEnforcementHelpBody')),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.getString('generalClose'))),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: ChoiceChip(
                                    label: Text(l10n.getString('settingsFlexibleLabel')),
                                    selected: !strictEnforcement,
                                    onSelected: (_) => _strictEnforcement.value = false,
                                    selectedColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
                                    labelStyle: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: !strictEnforcement
                                          ? Theme.of(context).colorScheme.secondary
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                                    shape: StadiumBorder(
                                      side: BorderSide(
                                        color: !strictEnforcement
                                            ? Theme.of(context).colorScheme.secondary
                                            : Theme.of(context).dividerColor,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ChoiceChip(
                                    label: Text(l10n.getString('settingsStrictLabel')),
                                    selected: strictEnforcement,
                                    onSelected: (_) => _strictEnforcement.value = true,
                                    selectedColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
                                    labelStyle: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: strictEnforcement
                                          ? Theme.of(context).colorScheme.secondary
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                                    shape: StadiumBorder(
                                      side: BorderSide(
                                        color: strictEnforcement
                                            ? Theme.of(context).colorScheme.secondary
                                            : Theme.of(context).dividerColor,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              strictEnforcement ? l10n.getString('settingsStrictEnforcement') : l10n.getString('settingsPrioritizeEnforcement'),
                              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.75)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // Intent-specific preferences
                ...selectedIntents.map((intent) => _buildIntentPreferenceCard(intent, genderOptions, l10n)),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text('${l10n.getString('generalError')}: $e')),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('${l10n.getString('generalError')}: $e')),
      ),
    );
  }

  Widget _buildIntentPreferenceCard(AppIntent intent, List<Map<String, String>> genderOptions, LocalizationState l10n) {
    final intentKey = intent.key;

    return ValueListenableBuilder<Map<String, List<String>>>(
      valueListenable: _genderPreferences,
      builder: (context, genderPrefs, _) => ValueListenableBuilder<Map<String, List<double>>>(
        valueListenable: _agePreferences,
        builder: (context, agePrefs, _) => Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).shadowColor.withValues(alpha:0.05),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.getString(intent.translationKey),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),

              // Gender Preferences
              Text(
                l10n.getString('settingsPreferredGenders'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.85),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: genderOptions.map((gender) {
                  final selectedGenders = genderPrefs[intentKey] ?? [];
                  final isSelected = selectedGenders.contains(gender['key']);
                  return FilterChip(
                    label: Text(l10n.getString(gender['displayKey'] ?? gender['key']!)),
                    selected: isSelected,
                    onSelected: (selected) {
                      final currentList = List<String>.from(genderPrefs[intentKey] ?? []);
                      if (selected) {
                        if (!currentList.contains(gender['key'])) {
                          currentList.add(gender['key']!);
                        }
                      } else {
                        currentList.remove(gender['key']);
                      }
                      final newPrefs = Map<String, List<String>>.from(genderPrefs);
                      newPrefs[intentKey] = currentList;
                      _genderPreferences.value = newPrefs;
                    },
                    selectedColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.1),
                    checkmarkColor: Theme.of(context).colorScheme.secondary,
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),

              // Age Range
              Text(
                l10n.getString('settingsPreferredAgeRange'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.85),
                ),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final ageList = agePrefs[intentKey] ?? [18.0, 100.0];
                  final rawStart = ageList.isNotEmpty ? ageList[0] : 18.0;
                  final rawEnd = ageList.length > 1 ? ageList[1] : 100.0;
                  final roundedStart = rawStart.round().clamp(18, 100).toDouble();
                  final roundedEnd = rawEnd.round().clamp(18, 100).toDouble();
                  final ageRange = roundedStart <= roundedEnd
                      ? RangeValues(roundedStart, roundedEnd)
                      : RangeValues(roundedEnd, roundedStart);
                  return Column(
                    children: [
                      RangeSlider(
                        values: ageRange,
                        min: 18,
                        max: 100,
                        divisions: 82,
                        labels: RangeLabels(
                          '${ageRange.start.round()}',
                          '${ageRange.end.round()}',
                        ),
                        onChanged: (values) {
                          final newPrefs = Map<String, List<double>>.from(agePrefs);
                          newPrefs[intentKey] = [
                            values.start.roundToDouble(),
                            values.end.roundToDouble(),
                          ];
                          _agePreferences.value = newPrefs;
                        },
                        activeColor: Theme.of(context).colorScheme.secondary,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${ageRange.start.round()} ${l10n.getString('generalYearsOld')}'),
                          Text('${ageRange.end.round()} ${l10n.getString('generalYearsOld')}'),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _savePreferences() async {
    try {
      await ref.read(profileEditProvider(_currentUserId).notifier).updateGenderAgePreferences(
        _genderPreferences.value,
        _agePreferences.value,
        _strictEnforcement.value,
      );
      // Auto-save is silent - no snackbar needed
    } catch (e) {
      // Silent failure for auto-save - user can retry manually if needed
      debugPrint('Auto-save failed: $e');
    }
  }
}
