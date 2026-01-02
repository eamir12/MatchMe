// lib/screens/settings/gender_age_preferences_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../providers/new_options_provider.dart';
import 'dart:developer' as developer;

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
  UserProfile? _profile;
  bool _isLoadingProfile = true;

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
    // Load initial profile data directly
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    setState(() => _isLoadingProfile = true);
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('*')
          .eq('id', _currentUserId)
          .single();

      // Create UserProfile from the response
      _profile = UserProfile.fromMap(response);
      _initializePreferences(_profile!);
    } catch (e) {
      developer.log('Error loading profile data: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingProfile = false);
      }
    }
  }

  void _initializePreferences(UserProfile profile) {
    if (!_preferencesInitialized) {
      _strictEnforcement.value = profile.strictGenderAgeEnforcement;
      _genderPreferences.value = Map.from(profile.genderPreferences);
      _agePreferences.value = Map.from(profile.agePreferences);
      _preferencesInitialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final mainIntents = ref.watch(mainIntentsProvider);
    final genderOptionsAsync = ref.watch(genderOptionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsGenderAgePreferences')),
        actions: [
          TextButton(
            onPressed: _savePreferences,
            child: Text(l10n.getString('generalSave')),
          ),
        ],
      ),
      body: genderOptionsAsync.when(
        data: (genderOptions) {
          if (_isLoadingProfile) {
            return const Center(child: CircularProgressIndicator());
          }

          if (_profile == null) {
            return Center(child: Text(l10n.getString('generalErrorLoadingProfile')));
          }

          final selectedIntentKeys = _profile!.activeModes;
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
                                child: Text(
                                  strictEnforcement ? l10n.getString('settingsStrictLabel') : l10n.getString('settingsFlexibleLabel'),
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                              ),
                              Switch(
                                value: strictEnforcement,
                                onChanged: (value) => _strictEnforcement.value = value,
                                activeThumbColor: Theme.of(context).colorScheme.secondary,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
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
                  final ageRange = RangeValues(ageList.isNotEmpty ? ageList[0] : 18.0, ageList.length > 1 ? ageList[1] : 100.0);
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
                          newPrefs[intentKey] = [values.start, values.end];
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
    final l10n = ref.read(localizationProvider);
    try {
      await ref.read(profileEditProvider(_currentUserId).notifier).updateGenderAgePreferences(
        _genderPreferences.value,
        _agePreferences.value,
        _strictEnforcement.value,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('settingsPreferencesSaved')), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.getString('settingsPreferencesSaveFailed')}: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}