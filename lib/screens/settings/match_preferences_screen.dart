// lib/screens/settings/match_preferences_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/utils/match_preferences_validation.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/widgets/safe_text.dart';

/// Which part of the match preferences a change belongs to.
///
/// All of them are stored in one `intent_preferences` JSONB blob, but each
/// group has its own writer, so a change only rewrites the group it touched.
enum _PrefsGroup { genderAge, lifestyle, family, religion, height }

class MatchPreferencesScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const MatchPreferencesScreen({super.key, this.embedded = false});

  @override
  ConsumerState<MatchPreferencesScreen> createState() =>
      _MatchPreferencesScreenState();
}

class _MatchPreferencesScreenState
    extends ConsumerState<MatchPreferencesScreen> {
  late String _currentUserId;

  Map<String, List<String>> _genderPreferences = {};
  Map<String, List<double>> _agePreferences = {};
  Map<String, Map<String, dynamic>> _lifestyleFilters = {};
  Map<String, Map<String, dynamic>> _familyFilters = {};
  Map<String, Map<String, dynamic>> _religionFilters = {};
  Map<String, Map<String, dynamic>> _heightPrefs = {};
  String _lastProfileSignature = '';
  Set<String> _activeIntentKeys = <String>{};
  Set<String> _invalidGenderIntentKeys = <String>{};
  final Map<String, FocusNode> _genderFocusNodes = {};
  final Map<String, GlobalKey> _genderGroupKeys = {};

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
  }

  @override
  void dispose() {
    for (final node in _genderFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Copies the profile's preferences into the local maps.
  ///
  /// Called whenever the profile itself changes - on the first load, and
  /// after a change made on another device. The screen keeps its own copy so
  /// a slider can follow the finger; that copy is refreshed from the profile
  /// rather than the other way round, so a remote change shows up here.
  void _applyProfileToLocal(UserProfile profile) {
    _activeIntentKeys = profile.activeModes.toSet();
    _genderPreferences = Map<String, List<String>>.from(
      profile.genderPreferences.map(
        (k, v) => MapEntry(k, List<String>.from(v)),
      ),
    );
    _agePreferences = Map<String, List<double>>.from(
      profile.agePreferences.map((k, v) => MapEntry(k, List<double>.from(v))),
    );
    _lifestyleFilters = _cloneDeep(profile.lifestyleFilters);
    _familyFilters = _cloneDeep(profile.familyFilters);
    _religionFilters = _cloneDeep(profile.religionFilters);
    _heightPrefs = _cloneDeep(profile.heightPreferences);
  }

  /// A fingerprint of the preferences the local maps were last taken from.
  ///
  /// The local maps are refreshed when this changes - not on every rebuild.
  /// That matters for the sliders: while one is being dragged the local map
  /// moves ahead of the profile, and re-applying the profile would snap it
  /// back to the old value.
  static String _profileSignature(UserProfile profile) {
    return jsonEncode({
      'gender': profile.genderPreferences,
      'age': profile.agePreferences,
      'lifestyle': profile.lifestyleFilters,
      'family': profile.familyFilters,
      'religion': profile.religionFilters,
      'height': profile.heightPreferences,
    });
  }

  Map<String, Map<String, dynamic>> _cloneDeep(
    Map<String, Map<String, dynamic>> src,
  ) {
    return Map<String, Map<String, dynamic>>.from(
      src.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v))),
    );
  }

  String _formatHeight(LocalizationState l10n, int heightCm, bool useImperial) {
    if (!useImperial) {
      return '$heightCm ${l10n.getString('settingsHeightCm')}';
    }
    return formatHeightFeetInches(l10n, heightCm);
  }

  /// Whether the current preferences are valid.
  ///
  /// Every intent must keep at least one preferred gender. Nothing is
  /// written while that is not the case, and the reason is shown.
  bool _validateGender() {
    final invalid = invalidGenderPreferenceKeys(
      activeIntentKeys: _activeIntentKeys,
      genderPreferences: _genderPreferences,
    );
    if (invalid.isEmpty) {
      if (_invalidGenderIntentKeys.isNotEmpty) {
        setState(() => _invalidGenderIntentKeys.clear());
      }
      return true;
    }
    if (mounted) {
      setState(() => _invalidGenderIntentKeys = invalid.toSet());
      _focusFirstInvalidGender(invalid);
      _showGenderValidationMessage(invalid);
    }
    return false;
  }

  /// Commits the preferences immediately.
  ///
  /// There is no Save button on this screen: a chip, a filter or a released
  /// slider is committed the moment it happens. That is how the leading
  /// social apps do it (Bumble, Hinge, Instagram, LinkedIn settings), and it
  /// is what every other settings screen in this app already does - the
  /// matching settings, the display settings and the notification settings
  /// all apply as you touch them.
  Future<void> _persist(_PrefsGroup group) async {
    if (!_validateGender()) return;
    try {
      final editor = ref.read(profileEditProvider(_currentUserId).notifier);
      if (group == _PrefsGroup.genderAge) {
        await editor.updateGenderAgePreferences(
          _genderPreferences,
          _agePreferences,
        );
      } else if (group == _PrefsGroup.lifestyle) {
        await editor.updateLifestyleFilters(_lifestyleFilters);
      } else if (group == _PrefsGroup.family) {
        await editor.updateFamilyFilters(_familyFilters);
      } else if (group == _PrefsGroup.religion) {
        await editor.updateReligionFilters(_religionFilters);
      } else {
        await editor.updateHeightPreferences(_heightPrefs);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(localizationProvider).getString('generalError'),
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Commits every group at once - used by "Copy from Profile", which
  /// rewrites all of them.
  Future<void> _persistAll() async {
    if (!_validateGender()) return;
    for (final group in _PrefsGroup.values) {
      await _persist(group);
    }
  }

  void _copyFromProfile(
    String intentKey,
    UserProfile profile,
    List<AppProfileOption> allOptions,
  ) {
    // Helper: find filter_value for a given profile_value
    String? profileToFilter(
      List<AppProfileOption> opts,
      String fieldKey,
      String profileVal,
    ) {
      final match = opts.cast<AppProfileOption?>().firstWhere(
        (o) => o!.fieldKey == fieldKey && o.profileValue == profileVal,
        orElse: () => null,
      );
      return match?.filterValue;
    }

    final l = profile.lifestyle;
    if (l != null) {
      final lf = Map<String, dynamic>.from(_lifestyleFilters[intentKey] ?? {});
      if (l['smoking'] != null) {
        final fv = profileToFilter(
          allOptions,
          'smoking',
          l['smoking'] as String,
        );
        if (fv != null) lf['smoking'] = [fv];
      }
      if (l['drinking'] != null) {
        final fv = profileToFilter(
          allOptions,
          'drinking',
          l['drinking'] as String,
        );
        if (fv != null) lf['drinking'] = [fv];
      }
      if (l['diet'] != null) {
        final fv = profileToFilter(allOptions, 'diet', l['diet'] as String);
        if (fv != null) lf['diets'] = [fv];
      }
      if (l['exercise'] != null) {
        final fv = profileToFilter(
          allOptions,
          'exercise',
          l['exercise'] as String,
        );
        if (fv != null) lf['exercise'] = [fv];
      }
      _lifestyleFilters[intentKey] = lf;
    }
    final f = profile.family;
    if (f != null) {
      final ff = Map<String, dynamic>.from(_familyFilters[intentKey] ?? {});
      if (f['has_children'] != null) {
        ff['has_children'] = [(f['has_children'] as bool) ? 'yes' : 'no'];
      }
      if (f['wants_children'] != null) {
        final fv = profileToFilter(
          allOptions,
          'wants_children',
          f['wants_children'] as String,
        );
        if (fv != null) ff['wants_children'] = [fv];
      }
      _familyFilters[intentKey] = ff;
    }
    final r = profile.religion;
    if (r != null) {
      final rf = Map<String, dynamic>.from(_religionFilters[intentKey] ?? {});
      if (r['religion'] != null) {
        final fv = profileToFilter(
          allOptions,
          'religion',
          r['religion'] as String,
        );
        if (fv != null) rf['religions'] = [fv];
      }
      if (r['denomination'] != null) {
        final fv = profileToFilter(
          allOptions,
          'denomination',
          r['denomination'].toString(),
        );
        if (fv != null) rf['denominations'] = [fv];
      }
      if (r['practice'] != null) {
        final fv = profileToFilter(
          allOptions,
          'practice',
          r['practice'].toString(),
        );
        if (fv != null) rf['practices'] = [fv];
      }
      _religionFilters[intentKey] = rf;
    }
    if (profile.height != null) {
      final hp = Map<String, dynamic>.from(_heightPrefs[intentKey] ?? {});
      hp['min'] = (profile.height! - 15).clamp(140, 220).toDouble();
      hp['max'] = (profile.height! + 15).clamp(140, 220).toDouble();
      _heightPrefs[intentKey] = hp;
    }
    _persistAll();
  }

  String _localizedIntentName(String intentKey, LocalizationState l10n) {
    for (final intent in ref.read(mainIntentsProvider)) {
      if (intent.key == intentKey) {
        return l10n.getString(intent.translationKey);
      }
    }
    return intentKey;
  }

  void _focusFirstInvalidGender(List<String> invalidKeys) {
    if (invalidKeys.isEmpty || !mounted) return;
    final intentKey = invalidKeys.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final groupContext = _genderGroupKeys[intentKey]?.currentContext;
      if (groupContext != null) {
        Scrollable.ensureVisible(
          groupContext,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      _genderFocusNodes[intentKey]?.requestFocus();
    });
  }

  void _showGenderValidationMessage(List<String> invalidKeys) {
    if (invalidKeys.isEmpty || !mounted) return;
    final l10n = ref.read(localizationProvider);
    final intentName = _localizedIntentName(invalidKeys.first, l10n);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.getString(
            'profileWizardGenderPreferenceRequired',
            params: {'intent': intentName},
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  IconData _intentIcon(String k) {
    final n = k.toLowerCase();
    if (n.contains('romantic')) return Icons.favorite_border;
    if (n.contains('friend')) return Icons.people_outline;
    if (n.contains('business') || n.contains('network')) {
      return Icons.business_center_outlined;
    }
    if (n.contains('activity')) return Icons.directions_run_outlined;
    return Icons.person_outline;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final mainIntents = ref.watch(mainIntentsProvider);
    final genderOptionsAsync = ref.watch(genderOptionsProvider);
    final profileAsync = ref.watch(userProfileProvider(_currentUserId));
    final allOptions =
        ref.watch(profileOptionsProvider).asData?.value ?? <AppProfileOption>[];

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: ShrinkText(l10n.getString('settingsMatchPreferences')),
            ),
      body: genderOptionsAsync.when(
          data: (genderOptions) => profileAsync.when(
            data: (profile) {
              if (profile == null) {
                return Center(
                  child: Text(l10n.getString('generalErrorLoadingProfile')),
                );
              }
              final signature = _profileSignature(profile);
              if (signature != _lastProfileSignature) {
                _lastProfileSignature = signature;
                _applyProfileToLocal(profile);
              }

              final selectedIntentKeys = profile.activeModes;
              final selectedIntents = mainIntents
                  .where((i) => selectedIntentKeys.contains(i.key))
                  .toList();

              if (selectedIntents.isEmpty) {
                return Center(
                  child: Text(l10n.getString('settingsNoIntentsSelected')),
                );
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.embedded)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        l10n.getString('settingsMatchPreferences'),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      l10n.getString('settingsMatchPreferencesIntro'),
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  ...selectedIntents.map(
                    (intent) => _buildIntentCard(
                      intent,
                      genderOptions,
                      profile,
                      l10n,
                      allOptions,
                    ),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, s) =>
                Center(child: Text(l10n.getString('generalError'))),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text(l10n.getString('generalError'))),
        ),
    );
  }

  Widget _buildIntentCard(
    AppIntent intent,
    List<Map<String, String>> genderOptions,
    UserProfile profile,
    LocalizationState l10n,
    List<AppProfileOption> allOptions,
  ) {
    final ik = intent.key;
    final useImperialUnits = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final isRomantic = ik.toLowerCase().contains('romantic');
    final isActivity = ik.toLowerCase().contains('activity');
    final hasSocial =
        isRomantic || ik.toLowerCase().contains('friend') || isActivity;

    final selectedGenders = _genderPreferences[ik] ?? [];
    final ageList = _agePreferences[ik] ?? [18.0, 100.0];
    final ageRange = RangeValues(
      (ageList.isNotEmpty ? ageList[0] : 18.0).clamp(18, 100),
      (ageList.length > 1 ? ageList[1] : 100.0).clamp(18, 100),
    );
    final hp = _heightPrefs[ik] ?? {};
    final hRange = RangeValues(
      ((hp['min'] as num?)?.toDouble() ?? 140).clamp(140, 220),
      ((hp['max'] as num?)?.toDouble() ?? 220).clamp(140, 220),
    );
    final lf = _lifestyleFilters[ik] ?? {};
    final famf = _familyFilters[ik] ?? {};
    final rf = _religionFilters[ik] ?? {};
    final selectedReligions = _getListField(
      rf,
      'religions',
      'religion',
    ).where((r) => r != 'any').toSet();
    final denominationOptions = _denominationFilterOptions(
      l10n,
      selectedReligions,
    );
    final genderGroupKey = _genderGroupKeys.putIfAbsent(ik, () => GlobalKey());
    final genderFocusNode = _genderFocusNodes.putIfAbsent(
      ik,
      () => FocusNode(debugLabel: 'gender-$ik'),
    );
    final hasGenderError = _invalidGenderIntentKeys.contains(ik);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(15),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _intentIcon(ik),
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.getString(intent.translationKey),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.getString('settingsCopyFromProfileHint'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_search_outlined, size: 18),
                  label: Text(l10n.getString('settingsCopyFromProfile')),
                  onPressed: () =>
                      setState(() => _copyFromProfile(ik, profile, allOptions)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Gender
                Text(
                  l10n.getString('settingsPreferredGenders'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hasGenderError)
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              l10n.getString(
                                'profileWizardGenderPreferenceRequired',
                                params: {
                                  'intent': l10n.getString(
                                    intent.translationKey,
                                  ),
                                },
                              ),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  key: genderGroupKey,
                  spacing: 8,
                  runSpacing: 8,
                  children: genderOptions.asMap().entries.map((entry) {
                    final g = entry.value;
                    final sel = selectedGenders.contains(g['key']);
                    return FilterChip(
                      focusNode: entry.key == 0 ? genderFocusNode : null,
                      label: Text(l10n.getString(g['displayKey'] ?? g['key']!)),
                      selected: sel,
                      onSelected: (selected) {
                        final list = List<String>.from(
                          _genderPreferences[ik] ?? [],
                        );
                        if (!selected && list.length <= 1) return;
                        final previous = list.isEmpty
                            ? null
                            : List<String>.from(list);
                        setState(() {
                          if (selected) {
                            if (!list.contains(g['key'])) list.add(g['key']!);
                          } else {
                            list.remove(g['key']);
                          }
                          _genderPreferences[ik] = list;
                          if (list.isNotEmpty) {
                            _invalidGenderIntentKeys.remove(ik);
                          }
                        });

                        // An intent must always keep at least one preferred
                        // gender. There is nothing to save in that case, so
                        // the chip snaps back and the reason is shown.
                        final invalid = invalidGenderPreferenceKeys(
                          activeIntentKeys: _activeIntentKeys,
                          genderPreferences: _genderPreferences,
                        );
                        if (invalid.isNotEmpty) {
                          setState(() {
                            _invalidGenderIntentKeys = invalid.toSet();
                            if (previous != null) {
                              _genderPreferences[ik] = previous;
                            } else {
                              _genderPreferences.remove(ik);
                            }
                          });
                          _focusFirstInvalidGender(invalid);
                          _showGenderValidationMessage(invalid);
                          return;
                        }
                        unawaited(_persist(_PrefsGroup.genderAge));
                      },
                      selectedColor: Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.1),
                      checkmarkColor: Theme.of(context).colorScheme.secondary,
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Age Range
                Text(
                  l10n.getString('settingsPreferredAgeRange'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                RangeSlider(
                  values: ageRange,
                  min: 18,
                  max: 100,
                  divisions: 82,
                  labels: RangeLabels(
                    '${ageRange.start.round()}',
                    '${ageRange.end.round()}',
                  ),
                  onChanged: (v) {
                    // The slider follows the finger, but nothing is written
                    // until it is released - otherwise a drag would produce
                    // one write per frame.
                    setState(
                      () => _agePreferences[ik] = [
                        v.start.roundToDouble(),
                        v.end.roundToDouble(),
                      ],
                    );
                  },
                  onChangeEnd: (v) {
                    setState(
                      () => _agePreferences[ik] = [
                        v.start.roundToDouble(),
                        v.end.roundToDouble(),
                      ],
                    );
                    unawaited(_persist(_PrefsGroup.genderAge));
                  },
                  activeColor: Theme.of(context).colorScheme.secondary,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${ageRange.start.round()} ${l10n.getString('generalYearsOld')}',
                    ),
                    Text(
                      '${ageRange.end.round()} ${l10n.getString('generalYearsOld')}',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Filter sections — collapsed by default
                if (isRomantic) ...[
                  _buildExpandableSection(
                    title: l10n.getString('settingsHeightRange'),
                    icon: Icons.straighten,
                    children: [
                      RangeSlider(
                        values: hRange,
                        min: 140,
                        max: 220,
                        divisions: 80,
                        labels: RangeLabels(
                          _formatHeight(
                            l10n,
                            hRange.start.round(),
                            useImperialUnits,
                          ),
                          _formatHeight(
                            l10n,
                            hRange.end.round(),
                            useImperialUnits,
                          ),
                        ),
                        onChanged: (v) {
                          setState(
                            () => _heightPrefs[ik] = {
                              'min': v.start.roundToDouble(),
                              'max': v.end.roundToDouble(),
                            },
                          );
                        },
                        onChangeEnd: (v) {
                          setState(
                            () => _heightPrefs[ik] = {
                              'min': v.start.roundToDouble(),
                              'max': v.end.roundToDouble(),
                            },
                          );
                          unawaited(_persist(_PrefsGroup.height));
                        },
                        activeColor: Theme.of(context).colorScheme.secondary,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatHeight(
                              l10n,
                              hRange.start.round(),
                              useImperialUnits,
                            ),
                          ),
                          Text(
                            _formatHeight(
                              l10n,
                              hRange.end.round(),
                              useImperialUnits,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
                if (hasSocial) ...[
                  _buildExpandableSection(
                    title: l10n.getString('settingsLifestyleFilters'),
                    icon: Icons.spa_outlined,
                    children: [
                      _buildMultiFilterRow(
                        l10n.getString('settingsSmoking'),
                        _filterOptionList(l10n, 'smoking'),
                        _getListField(lf, 'smoking', 'smoking'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _lifestyleFilters[ik] ?? {},
                          );
                          m['smoking'] = v;
                          _lifestyleFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.lifestyle));
                          setState(() {});
                        },
                        l10n,
                      ),
                      const SizedBox(height: 10),
                      _buildMultiFilterRow(
                        l10n.getString('settingsDrinking'),
                        _filterOptionList(l10n, 'drinking'),
                        _getListField(lf, 'drinking', 'drinking'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _lifestyleFilters[ik] ?? {},
                          );
                          m['drinking'] = v;
                          _lifestyleFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.lifestyle));
                          setState(() {});
                        },
                        l10n,
                      ),
                      const SizedBox(height: 10),
                      _buildMultiFilterRow(
                        l10n.getString('settingsDiet'),
                        _filterOptionList(l10n, 'diet'),
                        _getListField(lf, 'diets', 'diet'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _lifestyleFilters[ik] ?? {},
                          );
                          m['diets'] = v;
                          _lifestyleFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.lifestyle));
                          setState(() {});
                        },
                        l10n,
                      ),
                      if (isActivity) ...[
                        const SizedBox(height: 10),
                        _buildMultiFilterRow(
                          l10n.getString('settingsExercise'),
                          _filterOptionList(l10n, 'exercise'),
                          _getListField(lf, 'exercise', 'exercise'),
                          (v) {
                            final m = Map<String, dynamic>.from(
                              _lifestyleFilters[ik] ?? {},
                            );
                            m['exercise'] = v;
                            _lifestyleFilters[ik] = m;

                            unawaited(_persist(_PrefsGroup.lifestyle));
                            setState(() {});
                          },
                          l10n,
                        ),
                      ],
                    ],
                  ),
                ],
                if (isRomantic) ...[
                  _buildExpandableSection(
                    title: l10n.getString('settingsFamilyFilters'),
                    icon: Icons.family_restroom,
                    children: [
                      _buildMultiFilterRow(
                        l10n.getString('settingsHasChildren'),
                        _filterOptionList(l10n, 'has_children'),
                        _getListField(famf, 'has_children', 'has_children'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _familyFilters[ik] ?? {},
                          );
                          m['has_children'] = v;
                          _familyFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.family));
                          setState(() {});
                        },
                        l10n,
                      ),
                      const SizedBox(height: 10),
                      _buildMultiFilterRow(
                        l10n.getString('settingsWantsChildren'),
                        _filterOptionList(l10n, 'wants_children'),
                        _getListField(famf, 'wants_children', 'wants_children'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _familyFilters[ik] ?? {},
                          );
                          m['wants_children'] = v;
                          _familyFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.family));
                          setState(() {});
                        },
                        l10n,
                      ),
                    ],
                  ),
                ],
                if (isRomantic || ik.toLowerCase().contains('friend')) ...[
                  _buildExpandableSection(
                    title: l10n.getString('settingsBeliefs'),
                    icon: Icons.auto_awesome_outlined,
                    children: [
                      _buildMultiFilterRow(
                        l10n.getString('settingsReligion'),
                        _filterOptionList(l10n, 'religion'),
                        _getListField(rf, 'religions', 'religion'),
                        (v) => _setReligionFilter(ik, v),
                        l10n,
                      ),
                      if (denominationOptions.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _buildMultiFilterRow(
                          l10n.getString('settingsDenomination'),
                          denominationOptions,
                          _getListField(rf, 'denominations', 'denomination'),
                          (v) {
                            final m = Map<String, dynamic>.from(
                              _religionFilters[ik] ?? {},
                            );
                            m['denominations'] = v;
                            _religionFilters[ik] = m;

                            unawaited(_persist(_PrefsGroup.religion));
                            setState(() {});
                          },
                          l10n,
                        ),
                      ],
                      const SizedBox(height: 10),
                      _buildMultiFilterRow(
                        l10n.getString('settingsPractice'),
                        _filterOptionList(l10n, 'practice'),
                        _getListField(rf, 'practices', 'practice'),
                        (v) {
                          final m = Map<String, dynamic>.from(
                            _religionFilters[ik] ?? {},
                          );
                          m['practices'] = v;
                          _religionFilters[ik] = m;

                          unawaited(_persist(_PrefsGroup.religion));
                          setState(() {});
                        },
                        l10n,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String title, IconData icon) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildExpandableSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: _buildSectionLabel(title, icon),
          initiallyExpanded: false,
          children: [...children, const SizedBox(height: 12)],
        ),
      ),
    );
  }

  Widget _buildMultiFilterRow(
    String label,
    List<(String, String)> options,
    List<String> selectedValues,
    void Function(List<String>) onChanged,
    LocalizationState l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: options.map((opt) {
            final sel = selectedValues.contains(opt.$1);
            return FilterChip(
              label: Text(opt.$2),
              selected: sel,
              onSelected: (selected) {
                if (selected) {
                  if (opt.$1 == 'any') {
                    onChanged(['any']);
                  } else {
                    final updated = List<String>.from(selectedValues);
                    updated.remove('any');
                    if (!updated.contains(opt.$1)) updated.add(opt.$1);
                    onChanged(updated);
                  }
                } else {
                  final updated = List<String>.from(selectedValues);
                  updated.remove(opt.$1);
                  onChanged(updated.isEmpty ? ['any'] : updated);
                }
              },
              selectedColor: Theme.of(
                context,
              ).colorScheme.secondary.withValues(alpha: 0.1),
              checkmarkColor: Theme.of(context).colorScheme.secondary,
              labelStyle: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: sel
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: StadiumBorder(
                side: BorderSide(
                  color: sel
                      ? Theme.of(context).colorScheme.secondary
                      : Theme.of(context).dividerColor,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  void _setReligionFilter(String ik, List<String> values) {
    final m = Map<String, dynamic>.from(_religionFilters[ik] ?? {});
    m['religions'] = values;
    final selected = values.where((r) => r != 'any').toSet();
    final religionOptions =
        ref
            .read(
              fieldOptionsProvider((
                fieldKey: 'religion',
                context: 'filter',
              )),
            )
            .asData
            ?.value ??
        const [];
    final keyByValue = {
      for (final o in religionOptions)
        if (o.filterValue != null) o.filterValue!: o.optionKey,
    };
    final selectedKeys = selected.map((r) => keyByValue[r] ?? r).toSet();
    final current = _getListField(
      m,
      'denominations',
      'denomination',
    ).where((d) => d != 'any');
    final valid = current
        .where((d) => selectedKeys.any((r) => d.startsWith('${r}__')))
        .toList();
    m['denominations'] = valid.isEmpty ? ['any'] : valid;
    _religionFilters[ik] = m;

    unawaited(_persist(_PrefsGroup.religion));
    setState(() {});
  }

  List<(String, String)> _denominationFilterOptions(
    LocalizationState l10n,
    Set<String> selectedReligions,
  ) {
    if (selectedReligions.isEmpty) return const [];
    final religionOptions = _filterOptionData('religion');
    final keyByValue = {
      for (final o in religionOptions)
        if (o.filterValue != null) o.filterValue!: o.optionKey,
    };
    final labelByKey = {
      for (final o in religionOptions)
        o.optionKey: _filterOptionLabel(l10n, o),
    };
    final selectedKeys = selectedReligions
        .map((r) => keyByValue[r] ?? r)
        .toSet();
    final showParent = selectedReligions.length > 1;
    return _filterOptionList(l10n, 'denomination')
        .where((o) => selectedKeys.contains(o.$1.split('__').first))
        .map((o) {
          if (!showParent) return o;
          final parentKey = o.$1.split('__').first;
          final parentLabel = labelByKey[parentKey];
          if (parentLabel == null || parentLabel.isEmpty) return o;
          return (o.$1, '$parentLabel: ${o.$2}');
        })
        .toList();
  }

  List<String> _getListField(
    Map<String, dynamic> map,
    String key,
    String legacyKey,
  ) {
    final raw = map[key];
    if (raw is List) return raw.cast<String>();
    final legacy = map[legacyKey] as String?;
    if (legacy != null && legacy.isNotEmpty) return [legacy];
    return [];
  }

  List<AppProfileOption> _filterOptionData(String fieldKey) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: fieldKey, context: 'filter')),
            )
            .asData
            ?.value ??
        const [];
    return orderBeliefOptions(opts, fieldKey: fieldKey);
  }

  String _filterOptionLabel(LocalizationState l10n, AppProfileOption o) {
    final key = o.filterDisplayKey.isNotEmpty
        ? o.filterDisplayKey
        : o.profileDisplayKey;
    return _tryGetString(l10n, key) ??
        _humanizeFilterValue(o.filterValue ?? '');
  }

  List<(String, String)> _filterOptionList(
    LocalizationState l10n,
    String fieldKey,
  ) {
    return _filterOptionData(
      fieldKey,
    ).map((o) => (o.filterValue ?? '', _filterOptionLabel(l10n, o))).toList();
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    if (!_looksLikeTranslationKey(key)) return null;
    if (!l10n.containsKey(key)) return null;
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key || val.endsWith('...')) return null;
      return val;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeTranslationKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    return RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(normalized);
  }

  String _humanizeFilterValue(String value) {
    if (value.isEmpty) return '';
    return value[0].toUpperCase() + value.substring(1);
  }
}

