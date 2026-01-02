import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_improved_scrolling/flutter_improved_scrolling.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/models/hierarchy_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/screens/main_navigation_screen.dart';
import 'package:matchme/screens/profile/request_change_dialog.dart';
import 'package:matchme/services/photo_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/widgets/photo_editor_widget.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncfusion_flutter_datepicker/datepicker.dart';
import 'package:auto_size_text/auto_size_text.dart';

String _normalizeKey(String s) {
  final trimmed = s.trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

class ProfileWizardScreen extends ConsumerStatefulWidget {
  final User user;
  final bool isEditing;
  const ProfileWizardScreen({super.key, required this.user, this.isEditing = false});
  @override
  ConsumerState<ProfileWizardScreen> createState() => _ProfileWizardScreenState();
}

class _ProfileWizardScreenState extends ConsumerState<ProfileWizardScreen> {
    /// Helper to get the list of selected AppIntent objects from the profile's activeModes
    List<AppIntent> _getSelectedIntents(WidgetRef ref, UserProfile? profile, List<AppIntent> allIntents) {
      if (profile == null) return [];
      final selectedKeys = profile.activeModes.map((k) => k.trim().toLowerCase()).toSet();
      return allIntents.where((intent) => selectedKeys.contains(intent.key.trim().toLowerCase())).toList();
    }
  final _pageController = PageController();
  final _nameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _dobController = TextEditingController();
  final _searchIntentController = TextEditingController();
  final _searchInterestController = TextEditingController();
  final _formKeyStep1 = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isInitialized = false;
  bool _didPrefetchPhotos = false;
  final bool _isSaving = false;

  int _currentPageIndex = 0;

  Map<String, dynamic>? _originalSnapshot;
  final Set<String> _expandedInterestKeys = {};

  static final Set<String> _sharedIntents = {
    _normLiteral('Romantic'),
    _normLiteral('Friendship'),
    _normLiteral('Activity Partner'),
  };

  static String _normLiteral(String s) => _normalizeKey(s);

  static const double _leadingWidth = 56.0;
  static const double _rowVerticalPadding = 12.0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(profileEditProvider(widget.user.id).notifier).loadInitialProfile());

    _pageController.addListener(() {
      final newPage = _pageController.page?.round() ?? 0;
      if (newPage != _currentPageIndex) {
        // Save profile data to local storage and Supabase when moving to a new page
        ref.read(profileEditProvider(widget.user.id).notifier).saveProfile(showLoading: false, markComplete: false);
        setState(() {
          _currentPageIndex = newPage;
        });
      }
    });

    ref.listenManual(profileEditProvider(widget.user.id), (prev, next) {
      next.whenData((profile) {
        if (profile != null && mounted && !_isInitialized) {
          final authName = widget.user.userMetadata?['full_name'];

          // Always keep a raw name (no directional markers) for splitting into first/last fields
          final rawName = (profile.name == 'Unnamed' || profile.name.trim().isEmpty)
              ? (authName?.toString() ?? '')
              : profile.name;

          // Display a directionally-safe formatted name in the main name field
          final displayName = rawName.isNotEmpty ? rawName.formatAsFirstNameLastInitial() : '';
          _nameController.text = displayName;

          // If profile had an empty name but auth provided one, update profile if allowed
          if ((profile.name == 'Unnamed' || profile.name.trim().isEmpty) && authName != null && profile.editableProfileFields.contains('name')) {
            try {
              ref.read(profileEditProvider(widget.user.id).notifier).updateName(authName.toString());
            } catch (_) {
              // Ignore profile update errors
            }
          }

          if (rawName.isEmpty || rawName == 'Unnamed') {
            _firstNameController.text = '';
            _lastNameController.text = '';
          } else {
            final parts = rawName.split(RegExp(r'\s+'));
            if (parts.isNotEmpty) _firstNameController.text = parts.first;
            if (parts.length > 1) _lastNameController.text = parts.sublist(1).join(' ');
          }
          if (profile.dateOfBirth != null) {
            _dobController.text = DateFormat('yyyy-MM-dd').format(profile.dateOfBirth!);
          }
          // Keep original snapshot for diffing at final step
          _originalSnapshot = _snapshotFromProfile(profile);
          _isInitialized = true;
        }
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _dobController.dispose();
    _searchIntentController.dispose();
    _searchInterestController.dispose();
    super.dispose();
  }

  int _computeAge(DateTime birthDate) {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month || (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  Future<void> _selectDate(BuildContext context) async {
    final l10n = ref.read(localizationProvider);
    final DateTime now = DateTime.now();
    final DateTime eighteenYearsAgo = now.subtract(const Duration(days: 18 * 365 + 4));
    final currentProfile = ref.read(profileEditProvider(widget.user.id)).value;
    final DateTime initial = currentProfile?.dateOfBirth ?? eighteenYearsAgo;
    final DateTime? picked = await showDialog<DateTime>(
      context: context,
      builder: (BuildContext context) {
        DateTime selectedDate = initial;
        return AlertDialog(
          title: Text(l10n.getString('profileBirthday')),
          content: SizedBox(
            height: 300,
            width: 300,
            child: SfDateRangePicker(
              initialSelectedDate: initial,
              minDate: DateTime(1920),
              maxDate: eighteenYearsAgo,
              selectionMode: DateRangePickerSelectionMode.single,
              onSelectionChanged: (DateRangePickerSelectionChangedArgs args) {
                if (args.value is DateTime) {
                  selectedDate = args.value;
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.getString('generalCancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(selectedDate),
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        );
      },
    );
    if (picked != null) {
      _dobController.text = DateFormat('yyyy-MM-dd').format(picked);
      try {
        ref.read(profileEditProvider(widget.user.id).notifier).updateDob(picked);
      } catch (_) {
        // Ignore DOB update errors
      }
      setState(() {});
    }
  }

  Future<void> _openRequestDialogForField(BuildContext context, UserProfile profile, String fieldKey, String fieldLabel) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => RequestChangeDialog(
        userId: profile.id,
        fieldKey: fieldKey,
        fieldLabel: fieldLabel,
      ),
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.read(localizationProvider).getString('profileEditRequestSubmitted')))); // ignore: use_build_context_synchronously
    }
  }

  // ----------------------------
  // Robust _submit: guard against popping the only route (safe navigation)
  // ----------------------------
  Future<void> _submit() async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;

    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);

    final currentProfile = ref.read(profileEditProvider(widget.user.id)).value;
    if (currentProfile != null) {
      final canEditName = currentProfile.editableProfileFields.contains('name');
      final newName = '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'.trim();
      if (canEditName && newName.isNotEmpty && newName != currentProfile.name) {
        try {
          notifier.updateName(newName);
        } catch (_) {
          // Ignore profile update errors
        }
      }
    }

    // Start the save operation in the background without showing loading state
    // This prevents the wizard from staying visible during the save
    notifier.saveProfile().then((success) {
      if (!mounted) return;
      if (!success) {
        // Only show error if save failed, but don't block navigation
        final state = ref.read(profileEditProvider(widget.user.id));
        String message = l10n.getString('profileEditSaveFailed');
        if (state is AsyncError) {
          message = state.error?.toString() ?? message;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
          ),
        );
      }
    });

    // Navigate immediately without waiting for save to complete
    // This ensures smooth transition without showing wizard pages
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MainNavigationScreen(initialIndex: 3)),
    );
  }

  Future<void> _handleNextPage() async {
    final l10n = ref.read(localizationProvider);
    final currentPage = _currentPageIndex;
    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);

    if (currentPage == 0) {
      if (_formKeyStep1.currentState!.validate()) {
        if (_dobController.text.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditDobRequired'))));
          return;
        }
        if (_dobController.text.isNotEmpty) {
          try {
            final dob = DateFormat('yyyy-MM-dd').parse(_dobController.text);
            if (_computeAge(dob) < 18) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditMustBe18'))));
              return;
            }
          } catch (_) {
            // Ignore invalid date format
          }
        }
        // Save basics to local and Supabase in background so page transition is immediate.
        notifier.saveProfile(showLoading: false, markComplete: false).then((success) {
          if (!success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
          }
        }).catchError((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_pageController.hasClients) {
            _pageController.animateToPage(_currentPageIndex + 1, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
          }
        });
      }
      return;
    }

    if (currentPage == 1) {
      final p = ref.read(profileEditProvider(widget.user.id)).value;
      if (p == null || p.photos.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileWizardUploadPhotoRequired'))));
        return;
      }
      // Photos are already saved when added/edited
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pageController.hasClients) {
          _pageController.animateToPage(_currentPageIndex + 1, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
        }
      });
      return;
    }

    if (currentPage == 2) {
      final p = ref.read(profileEditProvider(widget.user.id)).value;
      if (p == null || p.activeModes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSelectIntent'))));
        return;
      }
      // Intents are saved with awaitPersist: false, so save in background and continue
      notifier.saveProfile(showLoading: false, markComplete: false).then((success) {
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
        }
      }).catchError((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pageController.hasClients) {
          _pageController.animateToPage(_currentPageIndex + 1, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
        }
      });
      return;
    }

    // For other pages (subintents, interests), save after each selection in background
    notifier.saveProfile(showLoading: false, markComplete: false).then((success) {
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
      }
    }).catchError((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('profileEditSaveFailed'))));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        _pageController.animateToPage(_currentPageIndex + 1, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
      }
    });
  }

  void _handleBackPage(List<Widget> pages) {
    final currentPage = _currentPageIndex;
    if (currentPage <= 0) {
      Navigator.of(context).pop();
      return;
    }
    
    if (_pageController.hasClients) {
      _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      Navigator.of(context).pop();
    }
  }

  String _extractLangCode(dynamic cur) {
    try {
      if (cur == null) return 'en';
      if (cur is Locale) return cur.languageCode;
      if (cur is String) return (cur.split(RegExp('[-_]')).first);
      return cur.toString().split(RegExp('[-_]')).first;
    } catch (_) {
      // Ignore invalid locale format
      return 'en';
    }
  }

  Map<String, dynamic> _snapshotFromProfile(UserProfile p) {
    final Map<String, dynamic> snapshot = {};

    snapshot['name'] = p.name;
    snapshot['dateOfBirth'] = p.dateOfBirth?.toIso8601String();
    snapshot['gender'] = p.gender;

    snapshot['activeModes'] = List<String>.from(p.activeModes);

    final Map<String, List<String>> subIntentsCopy = {};
    p.subIntents.forEach((k, v) {
      subIntentsCopy[k] = List<String>.from(v);
    });
    snapshot['subIntents'] = subIntentsCopy;

    final Map<String, List<String>> interestsCopy = {};
    p.interests.forEach((k, v) {
      interestsCopy[k] = List<String>.from(v);
    });
    snapshot['interests'] = interestsCopy;

    final Map<String, List<String>> langsCopy = {};
    p.languagesKnown.forEach((k, v) {
      langsCopy[k] = List<String>.from(v);
    });
    snapshot['languagesKnown'] = langsCopy;

    snapshot['bio'] = p.bio;
    snapshot['photos'] = List<String>.from(p.photos);

    return snapshot;
  }

  Map<String, dynamic> _computeDiffs(Map<String, dynamic>? orig, UserProfile current) {
    final diffs = <String, dynamic>{
      'name': null,
      'dateOfBirth': null,
      'gender': null,
      'intentsAdded': <String>[],
      'intentsRemoved': <String>[],
      'subIntentsAdded': <String, List<String>>{},
      'subIntentsRemoved': <String, List<String>>{},
      'interestsAdded': <String, List<String>>{},
      'interestsRemoved': <String, List<String>>{},
      'languagesChanged': <String, Map<String, List<String>>>{},
      'bioChanged': null,
      'photosChanged': null,
    };

    if (orig == null) {
      diffs['name'] = {'from': null, 'to': current.name};
      diffs['dateOfBirth'] = {'from': orig?['dateOfBirth'], 'to': current.dateOfBirth?.toIso8601String()};
      diffs['gender'] = {'from': orig?['gender'], 'to': current.gender};
      diffs['intentsAdded'] = List<String>.from(current.activeModes);
      for (final intent in current.subIntents.keys) {
        (diffs['subIntentsAdded'] as Map)[intent] = List<String>.from(current.subIntents[intent]!);
      }
      current.interests.forEach((k, v) {
        (diffs['interestsAdded'] as Map)[k] = List<String>.from(v);
      });
      current.languagesKnown.forEach((k, v) {
        if (k != 'languages') {
          (diffs['languagesChanged'] as Map)[k] = {'added': List<String>.from(v), 'removed': <String>[]};
        }
      });
      diffs['bioChanged'] = {'from': null, 'to': current.bio};
      diffs['photosChanged'] = {'from': [], 'to': current.photos};
      return diffs;
    }

    if (orig['name'] != current.name) {
      diffs['name'] = {'from': orig['name'], 'to': current.name};
    }
    final origDob = orig['dateOfBirth'] as String?;
    final currDob = current.dateOfBirth?.toIso8601String();
    if (origDob != currDob) {
      diffs['dateOfBirth'] = {'from': origDob, 'to': currDob};
    }
    if (orig['gender'] != current.gender) {
      diffs['gender'] = {'from': orig['gender'], 'to': current.gender};
    }

    final List<String> origIntents = List<String>.from(orig['activeModes'] ?? <String>[]);
    final List<String> currIntents = List<String>.from(current.activeModes);
    final origSet = Set<String>.from(origIntents);
    final currSet = Set<String>.from(currIntents);
    final addedIntents = currSet.difference(origSet).toList();
    final removedIntents = origSet.difference(currSet).toList();
    diffs['intentsAdded'] = addedIntents;
    diffs['intentsRemoved'] = removedIntents;

    final Map<String, List<String>> origSubs = Map<String, List<String>>.from(
        (orig['subIntents'] as Map?)?.map((k, v) => MapEntry(k, List<String>.from(v ?? <String>[]))) ?? {});
    final Map<String, List<String>> currSubs = current.subIntents.map((k, v) => MapEntry(k, List<String>.from(v)));
    final allIntentKeys = {...origSubs.keys, ...currSubs.keys};
    for (final intent in allIntentKeys) {
      final o = Set<String>.from(origSubs[intent] ?? []);
      final c = Set<String>.from(currSubs[intent] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty) (diffs['subIntentsAdded'] as Map)[intent] = added;
      if (removed.isNotEmpty) (diffs['subIntentsRemoved'] as Map)[intent] = removed;
    }

    final Map<String, List<String>> origInterests = Map<String, List<String>>.from(
        (orig['interests'] as Map?)?.map((k, v) => MapEntry(k, List<String>.from(v ?? <String>[]))) ?? {});
    final Map<String, List<String>> currInterests = current.interests.map((k, v) => MapEntry(k, List<String>.from(v)));
    final allInterestKeys = {...origInterests.keys, ...currInterests.keys};
    for (final k in allInterestKeys) {
      final o = Set<String>.from(origInterests[k] ?? []);
      final c = Set<String>.from(currInterests[k] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty) (diffs['interestsAdded'] as Map)[k] = added;
      if (removed.isNotEmpty) (diffs['interestsRemoved'] as Map)[k] = removed;
    }

    final Map<String, List<String>> origLangs = Map<String, List<String>>.from(
        (orig['languagesKnown'] as Map?)?.map((k, v) => MapEntry(k, List<String>.from(v ?? <String>[]))) ?? {});
    final Map<String, List<String>> currLangs = current.languagesKnown.map((k, v) => MapEntry(k, List<String>.from(v)));
    final allLangKeys = {...origLangs.keys, ...currLangs.keys}.where((k) => k != 'languages').toList();
    for (final lang in allLangKeys) {
      final o = Set<String>.from(origLangs[lang] ?? []);
      final c = Set<String>.from(currLangs[lang] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty || removed.isNotEmpty) {
        (diffs['languagesChanged'] as Map)[lang] = {'added': added, 'removed': removed};
      }
    }

    final origBio = orig['bio']?.toString() ?? '';
    final currBio = current.bio?.toString() ?? '';
    if (origBio != currBio) {
      diffs['bioChanged'] = {'from': origBio, 'to': currBio};
    }

    final List<String> origPhotos = (orig['photos'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final List<String> currPhotos = current.photos;
    if (!const ListEquality<String>().equals(origPhotos, currPhotos)) {
      diffs['photosChanged'] = {'from': origPhotos, 'to': currPhotos};
    }

    return diffs;
  }

  String _humanizeKey(String key) {
    var s = key;
    s = s.replaceAll(RegExp(r'^(interest_category_|interest_|category_|subIntent|intent|profileEdit)'), '');
    s = s.replaceAll('_', ' ');
    s = s.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final human = words.map((w) {
      if (w.length <= 1) return w.toUpperCase();
      return w[0].toUpperCase() + w.substring(1);
    }).join(' ');
    
    final result = human.isEmpty ? key : human;
    return result;
  }

  String _resolveDisplayLabel(
    LocalizationState l10n,
    String keyOrDisplay, {
    Map<String, String>? interestKeyToDisplayKey,
    Map<String, String>? categoryKeyToDisplayKey,
    Map<String, String>? allIntentsMap,
    String? fallbackProvided,
  }) {
    if (keyOrDisplay.trim().isEmpty) return fallbackProvided ?? '';

    if (keyOrDisplay.contains('::')) {
      final parts = keyOrDisplay.split('::');
      
      if (parts.first == 'shared' && parts.length >= 2) {
         final catKey = parts[1];
         final catLabel = categoryKeyToDisplayKey?[catKey] ?? catKey;
         return _tryGetString(l10n, catLabel) ?? _humanizeKey(catLabel);
      }

      if (parts.length >= 2) {
        final left = parts[0];
        final right = parts.sublist(1).join('::');
        
        final leftLocalized = _tryGetString(l10n, allIntentsMap?[left] ?? left) ?? _humanizeKey(left);
        String? rightLocalized;

        if (interestKeyToDisplayKey != null) {
          final mapped = interestKeyToDisplayKey[right];
          if (mapped != null && mapped.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mapped) ?? _humanizeKey(mapped);
          }
        }
        if ((rightLocalized == null || rightLocalized.trim().isEmpty) && categoryKeyToDisplayKey != null) {
          final mappedCat = categoryKeyToDisplayKey[right];
          if (mappedCat != null && mappedCat.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mappedCat) ?? _humanizeKey(mappedCat);
          }
        }

        rightLocalized = rightLocalized ?? _tryGetString(l10n, right) ?? _humanizeKey(right);
        return '$leftLocalized — $rightLocalized';
      }
    }

    if (allIntentsMap != null && allIntentsMap.containsKey(keyOrDisplay)) {
        final mapped = allIntentsMap[keyOrDisplay]!;
        final mappedLoc = _tryGetString(l10n, mapped);
        if (mappedLoc != null) return mappedLoc;
        return _humanizeKey(mapped);
    }

    if (interestKeyToDisplayKey != null && interestKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = interestKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
      return _humanizeKey(mapped);
    }

    if (categoryKeyToDisplayKey != null && categoryKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = categoryKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
      return _humanizeKey(mapped);
    }

    final direct = _tryGetString(l10n, keyOrDisplay);
    if (direct != null) return direct;

    if (fallbackProvided != null && fallbackProvided.trim().isNotEmpty) {
      return fallbackProvided;
    }

    return _humanizeKey(keyOrDisplay);
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key) {
        return null;
      }
      return val;
    } catch (_) {
      // Ignore localization errors
      return null;
    }
  }

  void _toggleInterestExpanded(String interestKey) {
    setState(() {
      if (_expandedInterestKeys.contains(interestKey)) {
        _expandedInterestKeys.remove(interestKey);
      } else {
        _expandedInterestKeys.add(interestKey);
      }
    });
  }

  Widget _leadingCheckbox({required bool loading, required bool value, required ValueChanged<bool?>? onChanged}) {
    const double width = 44.0;
    if (loading) {
      return SizedBox(width: width, height: width, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))); 
    }
    return SizedBox(
      width: width,
      height: width,
      child: Center(
        child: Checkbox(
          value: value,
          onChanged: onChanged,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          activeColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _alignedLockedCard({
    required Widget leadingIcon,
    required String title,
    required String subtitle,
    required VoidCallback onTapPadlock,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
      margin: const EdgeInsets.only(bottom: 14.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTapPadlock,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            children: [
              const SizedBox(width: 4),
              SizedBox(width: _leadingWidth, child: Center(child: leadingIcon)),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: _rowVerticalPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600)),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.lock_outline),
                onPressed: onTapPadlock,
                tooltip: 'Locked',
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _applyInterestToSelectedIntents(WidgetRef refLocal, String categoryKey, String interestKey, {required bool select}) async {
    final profile = refLocal.read(profileEditProvider(widget.user.id)).asData?.value;
    if (profile == null) return;

    final targetIntents = profile.activeModes.where((i) => _sharedIntents.contains(_normalizeKey(i))).toList();
    if (targetIntents.isEmpty) return;

    for (final intent in targetIntents) {
      final pref = '$intent::$categoryKey';
      final actualPref = profile.interests.keys.firstWhere(
        (k) => _normalizeKey(k) == _normalizeKey(pref),
        orElse: () => pref,
      );
      final currentlySelected = profile.interests[actualPref]?.contains(interestKey) ?? false;
      if (select && !currentlySelected) {
        refLocal.read(profileEditProvider(widget.user.id).notifier).toggleInterest(pref, interestKey, awaitPersist: false);
      } else if (!select && currentlySelected) {
        refLocal.read(profileEditProvider(widget.user.id).notifier).toggleInterest(pref, interestKey, awaitPersist: false);
      }
    }

    // If selecting a sub-interest, also select the category
    if (select && interestKey != categoryKey) {
      for (final intent in targetIntents) {
        final pref = '$intent::$categoryKey';
        final actualPref = profile.interests.keys.firstWhere(
          (k) => _normalizeKey(k) == _normalizeKey(pref),
          orElse: () => pref,
        );
        final categorySelected = profile.interests[actualPref]?.contains(categoryKey) ?? false;
        if (!categorySelected) {
          refLocal.read(profileEditProvider(widget.user.id).notifier).toggleInterest(pref, categoryKey, awaitPersist: false);
        }
      }
    }
  }

  Widget _buildInterestTree(
    BuildContext context,
    WidgetRef ref,
    List<AppInterest> interests,
    String intentKey,
    String categoryKey,
    UserProfile profile,
    LocalizationState l10n,
    Set<String> excludedKeys,
  ) {
    final isSharedPage = (intentKey == "shared");

    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);

    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Column(
      children: interests
          .where((item) => item.key != categoryKey && !excludedKeys.contains(item.key)) // Prevent parent from appearing as its own child and exclude already shown interests
          .map((item) {
        final interestKey = item.key;
        final label = localResolve(item.translationKey);

        bool isSelected;
        if (isSharedPage) {
          final selectedSharedIntents = profile.activeModes.where((i) => _sharedIntents.contains(_normalizeKey(i))).toList();
          if (selectedSharedIntents.isEmpty) {
            isSelected = false;
          } else {
            isSelected = selectedSharedIntents.every((intent) {
              final pref = '$intent::$categoryKey';
              final actualPref = profile.interests.keys.firstWhere((k) => _normalizeKey(k) == _normalizeKey(pref), orElse: () => pref);
              return profile.interests[actualPref]?.contains(interestKey) ?? false;
            });
          }
        } else {
          final prefixedCategory = '$intentKey::$categoryKey';
          isSelected = profile.interests[prefixedCategory]?.contains(interestKey) ?? false;
        }
        
        final children = ref.watch(interestChildrenProvider(item.id));
        final hasChildren = children.isNotEmpty;
        final isExpanded = _expandedInterestKeys.contains(interestKey);

        void handleToggle() {
          if (isSharedPage) {
            final bool willSelect = !isSelected;
            _applyInterestToSelectedIntents(ref, categoryKey, interestKey, select: willSelect);
          } else {
            final prefixedCategory = '$intentKey::$categoryKey';
            ref.read(profileEditProvider(widget.user.id).notifier).toggleInterest(prefixedCategory, interestKey, awaitPersist: false);
            // If selecting a sub-interest, also select the category
            if (!isSelected && interestKey != categoryKey) {
              final categorySelected = profile.interests[prefixedCategory]?.contains(categoryKey) ?? false;
              if (!categorySelected) {
                ref.read(profileEditProvider(widget.user.id).notifier).toggleInterest(prefixedCategory, categoryKey, awaitPersist: false);
              }
            }
          }
        }

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
          margin: const EdgeInsets.only(bottom: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: _leadingCheckbox(
                  loading: false,
                  value: isSelected,
                  onChanged: null,
                ),
                title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => handleToggle(),
                trailing: hasChildren
                    ? IconButton(
                        icon: Icon(isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                        onPressed: () => _toggleInterestExpanded(interestKey),
                      )
                    : null,
              ),
              if (hasChildren && isExpanded)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 24.0, end: 8.0, bottom: 8.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha:0.06),
                      border: BorderDirectional(
                        start: BorderSide(
                          color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha:0.4),
                          width: 3.0,
                        ),
                      ),
                      borderRadius: const BorderRadiusDirectional.only(
                        topEnd: Radius.circular(8.0),
                        bottomEnd: Radius.circular(8.0),
                      ),
                    ),
                    padding: const EdgeInsetsDirectional.only(start: 12.0, top: 8.0),
                    child: _buildInterestTree(context, ref, children, intentKey, categoryKey, profile, l10n, const <String>{}),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSharedCategoriesPage(BuildContext ctx, LocalizationState l10n, bool isRtl, UserProfile profile) {
    final allMainIntents = ref.watch(mainIntentsProvider);
    final selectedSharedIntentKeys = profile.activeModes
        .where((modeKey) => allMainIntents.any((intent) => intent.key == modeKey && _sharedIntents.contains(_normalizeKey(intent.key))))
        .toList();

    if (selectedSharedIntentKeys.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20.0),
        child: Center(child: Text(l10n.getString('profileNotFound'))),
      );
    }
    
    final firstSharedIntentKey = selectedSharedIntentKeys.first;
    
    AppIntent? firstSharedIntent;
    try {
      firstSharedIntent = allMainIntents.firstWhere((i) => i.key == firstSharedIntentKey);
    } catch (e) {
      firstSharedIntent = null;
    }

    if (firstSharedIntent == null) {
       return Padding(
        padding: const EdgeInsets.all(20.0),
        child: Center(child: Text(l10n.getString('generalError'))),
      );
    }
    
    // For business, use intentId; for social intents, use intentKey
    List<AppInterest> categories = [];
    categories = ref.watch(nonSharedInterestCategoriesByKeyProvider(firstSharedIntent.key));
  
    final Set<String> seenCategoryKeys = {};
    final List<AppInterest> uniqueCategories = categories.where((cat) {
      if (seenCategoryKeys.contains(cat.key)) return false;
      seenCategoryKeys.add(cat.key);
      return true;
    }).toList();
    
    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.getString('profileInterests'), style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
              const SizedBox(width: 12),
              CircleAvatar(radius: 20, backgroundColor: Colors.teal.shade50, child: const Icon(Icons.favorite, color: Colors.teal)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${l10n.getString('profileInterestsHelper')} ${selectedSharedIntentKeys.map((k) => localResolve(allMainIntents.firstWhere((i) => i.key == k).translationKey)).join(', ')}',
            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 16),
          ...uniqueCategories.map((cat) {
            final categoryKey = cat.key;
            final prefLabel = cat.translationKey;
            final displayLabel = localResolve(prefLabel);
            final children = ref.watch(interestChildrenProvider(cat.id));

            bool isCategorySelected;
            if (selectedSharedIntentKeys.isEmpty) {
              isCategorySelected = false;
            } else {
              isCategorySelected = selectedSharedIntentKeys.every((intent) {
                final pref = '$intent::$categoryKey';
                final actualPref = profile.interests.keys.firstWhere((k) => _normalizeKey(k) == _normalizeKey(pref), orElse: () => pref);
                return profile.interests[actualPref]?.contains(categoryKey) ?? false;
              });
            }

            if (children.isNotEmpty) {
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12.0),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                  side: BorderSide(color: Colors.grey.shade200, width: 1),
                ),
                child: ExpansionTile(
                  key: PageStorageKey('shared_$categoryKey'),
                  leading: _leadingCheckbox(
                    loading: false,
                    value: isCategorySelected,
                    onChanged: (_) => _applyInterestToSelectedIntents(ref, categoryKey, categoryKey, select: !isCategorySelected),
                  ),
                  title: Text(displayLabel, style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: _buildInterestTree(
                        ctx,
                        ref,
                        children,
                        "shared",
                        categoryKey,
                        profile,
                        l10n,
                        seenCategoryKeys,
                      ),
                    )
                  ],
                ),
              );
            } else {
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12.0),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                  side: BorderSide(color: Colors.grey.shade200, width: 1),
                ),
                child: ListTile(
                  leading: _leadingCheckbox(
                    loading: false,
                    value: isCategorySelected,
                    onChanged: (_) => _applyInterestToSelectedIntents(ref, categoryKey, categoryKey, select: !isCategorySelected),
                  ),
                  title: Text(displayLabel, style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  onTap: () => _applyInterestToSelectedIntents(ref, categoryKey, categoryKey, select: !isCategorySelected),
                ),
              );
            }
          }),
        ],
      ),
    );
  }

  Widget _buildBasicsPage(BuildContext context, LocalizationState l10n, bool isRtl, UserProfile? profile) {
    if (profile == null) return const Center(child: CircularProgressIndicator());
    final canEditName = profile.editableProfileFields.contains('name') || !profile.isProfileComplete;
    final canEditGender = profile.editableProfileFields.contains('gender') || !profile.isProfileComplete;
    final canEditDob = profile.editableProfileFields.contains('date_of_birth') || !profile.isProfileComplete;

    final genderOptionsAsync = ref.watch(genderOptionsProvider);
    final helperText = l10n.getString('profileBasicsHelper');

    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.getString('profileEditBasics'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha:0.12),
                child: Icon(Icons.person, color: Theme.of(context).colorScheme.primary),
              )
            ],
          ),
          const SizedBox(height: 8),
          Text(helperText, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
          const SizedBox(height: 20),

          Form(
            key: _formKeyStep1,
            child: Column(
              children: [
                if (canEditName)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: TextFormField(
                        controller: _firstNameController,
                        enabled: true,
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.getString('profileFirstName'),
                          prefixIcon: const Icon(Icons.person_outline),
                          border: InputBorder.none,
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? l10n.getString('profileEditFirstNameRequired') : null,
                        onChanged: (v) {
                          final fullName = ("${_firstNameController.text.trim()} ${_lastNameController.text.trim()}").trim();
                          try {
                            ref.read(profileEditProvider(widget.user.id).notifier).updateName(fullName);
                          } catch (_) {
                            // Ignore profile update errors
                          }
                        },
                      ),
                    ),
                  ),
                if (canEditName)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: TextFormField(
                        controller: _lastNameController,
                        enabled: true,
                        textInputAction: TextInputAction.next,
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        decoration: InputDecoration(
                          labelText: l10n.getString('profileLastName'),
                          prefixIcon: const Icon(Icons.person_outline),
                          border: InputBorder.none,
                          helperText: l10n.getString('profileLastNameNotDisplayed'),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? l10n.getString('profileEditLastNameRequired') : null,
                        onChanged: (v) {
                          final fullName = ("${_firstNameController.text.trim()} ${_lastNameController.text.trim()}").trim();
                          try {
                            ref.read(profileEditProvider(widget.user.id).notifier).updateName(fullName);
                          } catch (_) {
                            // Ignore profile update errors
                          }
                        },
                      ),
                    ),
                  )
                else
                  _alignedLockedCard(
                    leadingIcon: const Icon(Icons.person_outline, size: 22),
                    title: l10n.getString('profileName'),
                    subtitle: profile.name.isNotEmpty ? profile.name.formatAsFirstNameLastInitial() : l10n.getString('profileNotSet'),
                    onTapPadlock: () => _openRequestDialogForField(context, profile, 'name', l10n.getString('profileName')),
                  ),

                if (canEditDob)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: ListTile(
                      leading: const Icon(Icons.cake_outlined),
                      title: Text(l10n.getString('profileBirthday')),
                      subtitle: Builder(builder: (context) {
                        if (_dobController.text.isEmpty) {
                          return Text(l10n.getString('profileNotSet'));
                        }
                        try {
                          final dt = DateFormat('yyyy-MM-dd').parse(_dobController.text);
                          return Text(_formatDateWithL10n(dt, l10n));
                        } catch (_) {
                          // Ignore invalid date format
                          return Text(_dobController.text);
                        }
                      }),
                      trailing: const Icon(Icons.calendar_today_outlined),
                      onTap: () => _selectDate(context),
                    ),
                  )
                else
                  _alignedLockedCard(
                    leadingIcon: const Icon(Icons.cake_outlined, size: 22),
                    title: l10n.getString('profileBirthday'),
                    subtitle: profile.dateOfBirth != null ? _formatDateWithL10n(profile.dateOfBirth!, l10n) : l10n.getString('profileNotSet'),
                    onTapPadlock: () => _openRequestDialogForField(context, profile, 'date_of_birth', l10n.getString('profileBirthday')),
                  ),

                Builder(builder: (ctx) {
                  DateTime? resolvedDob;
                  if (profile.dateOfBirth != null) {
                    resolvedDob = profile.dateOfBirth;
                  } else if (_dobController.text.isNotEmpty) {
                    try {
                      resolvedDob = DateFormat('yyyy-MM-dd').parse(_dobController.text);
                    } catch (_) {
                      // Ignore invalid date format
                      resolvedDob = null;
                    }
                  } else {
                    resolvedDob = null;
                  }

                  if (resolvedDob != null) {
                    final label = _ageLabelFor(l10n);
                    final age = _computeAge(resolvedDob);
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(start: 12.0 + _leadingWidth + 8.0, top: 8.0),
                      child: Align(
                        alignment: isRtl ? Alignment.centerRight : Alignment.centerLeft,
                        child: Text('$label: $age', style: TextStyle(color: Colors.green.shade700)),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }),

                const SizedBox(height: 12),

                if (canEditGender)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: genderOptionsAsync.when(
                         data: (options) => DropdownButtonFormField<String>(
                           initialValue: profile.gender,
                           decoration: InputDecoration(
                             labelText: l10n.getString('profileGender'),
                             prefixIcon: const Icon(Icons.wc_outlined),
                             border: InputBorder.none,
                           ),
                           items: (options..sort((a, b) {
                             final order = ['male', 'female', 'non_binary', 'prefer_not_to_say'];
                             final aKey = a['key']!;
                             final bKey = b['key']!;
                             final aIndex = order.indexOf(aKey);
                             final bIndex = order.indexOf(bKey);
                             if (aIndex == -1) return 1;
                             if (bIndex == -1) return -1;
                             return aIndex.compareTo(bIndex);
                           })).map((g) {
                             final gKey = g['key']!;
                             final displayKey = g['displayKey']!;
                             return DropdownMenuItem<String>(
                               value: gKey,
                               child: Text(localResolve(displayKey), maxLines: 1, overflow: TextOverflow.ellipsis),
                             );
                           }).toList(),
                           validator: (value) => value == null || value.trim().isEmpty ? l10n.getString('profileEditGenderRequired') : null,
                           onChanged: (value) => ref.read(profileEditProvider(widget.user.id).notifier).updateGender(value),
                         ),
                         loading: () => const Center(child: CircularProgressIndicator()),
                         error: (e,s) => Text('${l10n.getString('generalError')}: $e')
                       ),
                    ),
                  )
                else
                  _alignedLockedCard(
                    leadingIcon: const Icon(Icons.wc_outlined, size: 22),
                    title: l10n.getString('profileGender'),
                    subtitle: _genderLabelFor(profile.gender, l10n),
                    onTapPadlock: () => _openRequestDialogForField(context, profile, 'gender', l10n.getString('profileGender')),
                  ),

                // Informational note placed below the Gender field; sourced from Supabase translations with code fallback.
                if (!canEditName || !canEditGender || !canEditDob)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0, bottom: 12.0),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(l10n.getString('profileBasicsLockedNoteTitle')),
                        subtitle: Text(l10n.getString('profileBasicsLockedNoteBody')),
                        onTap: () {
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(l10n.getString('profileBasicsLockedNoteTitle')),
                              content: Text(l10n.getString('profileBasicsLockedNoteBody')),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.getString('generalClose'))),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Text(l10n.getString('profileAgeRequirementNote'), style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),

          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildDetailsPage(BuildContext context, LocalizationState l10n, bool isRtl, UserProfile? profile) {
    if (profile == null) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.getString('profileWizardDetailsTitle'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.shade50,
                child: const Icon(Icons.info, color: Colors.blue),
              )
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.getString('profileWizardDetailsSubtitle'), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
          const SizedBox(height: 20),

          // Bio editor
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.getString('profileEditShortBio'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: profile.bio ?? '',
                  maxLength: 300,
                  maxLines: 4,
                  decoration: InputDecoration(hintText: l10n.getString('profileEditShortBioHint')),
                  onChanged: (val) => ref.read(profileEditProvider(widget.user.id).notifier).updateBio(val.trim()),
                ),
              ]),
            ),
          ),

          // Photo editor section
          _buildPhotoEditorSection(profile),

          const SizedBox(height: 12),

          // Languages known section
          _buildLanguagesEditorSection(profile, l10n),

          const SizedBox(height: 60),
        ],
      ),
    );
  }

  IconData _getIconForIntent(String intentKey) {
    switch (_normalizeKey(intentKey)) {
      case 'romantic':
        return Icons.favorite_border;
      case 'friendship':
        return Icons.people_outline;
      case 'activity_partner':
        return Icons.fitness_center;
      case 'business_networking':
        return Icons.business_center_outlined;
      default:
        return Icons.explore_outlined;
    }
  }

  Widget _buildMainIntentsPage(BuildContext ctx, UserProfile profile, LocalizationState l10n, bool isRtl) {
    final allIntentsAsync = ref.watch(allIntentsProvider);
    final intents = ref.watch(mainIntentsProvider);

    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.getString('profileEditIntentsTitle'), style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
              const SizedBox(width: 12),
              CircleAvatar(radius: 24, backgroundColor: Colors.pink.shade50, child: const Icon(Icons.star, color: Colors.pink)),
            ],
          ),
          const SizedBox(height: 12),
          Text(l10n.getString('profileEditIntentsSubtitle'), style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
          const SizedBox(height: 20),
          if (allIntentsAsync.isLoading) const Center(child: CircularProgressIndicator()),
          if (!allIntentsAsync.isLoading && intents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24.0),
              child: Center(child: Text(l10n.getString('profileWizardNoIntents'))),
            ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: intents.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 1, mainAxisExtent: 92, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemBuilder: (context, index) {
              final intent = intents[index];
              final key = intent.key;
              final displayKey = intent.translationKey;
              final bool selected = profile.activeModes.any((m) => _normalizeKey(m) == _normalizeKey(key));
              final icon = _getIconForIntent(key);
              return GestureDetector(
                onTap: () => ref.read(profileEditProvider(widget.user.id).notifier).toggleIntent(key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  decoration: BoxDecoration(
                    color: selected ? Theme.of(ctx).colorScheme.primary.withValues(alpha:0.14) : Theme.of(ctx).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12.0),
                    border: Border.all(color: selected ? Theme.of(ctx).colorScheme.primary : Colors.grey.shade200, width: selected ? 2 : 1),
                    boxShadow: selected ? [BoxShadow(color: Theme.of(ctx).colorScheme.primary.withValues(alpha:0.06), blurRadius: 8.0)] : null,
                  ),
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: selected ? Theme.of(ctx).colorScheme.primary.withValues(alpha:0.18) : Colors.grey.shade100,
                        child: Icon(icon, color: selected ? Theme.of(ctx).colorScheme.primary : Colors.grey.shade700),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AutoSizeText(
                          localResolve(displayKey),
                          style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w600, fontSize: 14),
                          minFontSize: 10,
                          maxLines: 2,
                          wrapWords: false,
                        ),
                      ),
                      Checkbox(
                        value: selected,
                        onChanged: (_) => ref.read(profileEditProvider(widget.user.id).notifier).toggleIntent(key),
                        activeColor: Theme.of(ctx).colorScheme.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWizardPages(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
    List<AppIntent> allIntents,
    List<AppInterest> allInterests,
  ) {
    // Only show main intents on the main intent selection page
    final mainIntents = ref.watch(mainIntentsProvider);
    final selectedMainIntents = _getSelectedIntents(ref, profile, mainIntents);
    final pages = <Widget>[];

    pages.add(_buildBasicsPage(context, l10n, isRtl, profile));
    pages.add(_buildDetailsPage(context, l10n, isRtl, profile));
    // This page only shows main intents
    pages.add(_buildMainIntentsPage(context, profile, l10n, isRtl));

    // For each selected main intent, add a sub-intent selection page
    for (final intent in selectedMainIntents) {
      pages.add(_buildSubIntentsPage(context, intent, profile, l10n, isRtl));
    }

    // Add interests page if there are shared intents selected
    final selectedSharedIntentKeys = profile.activeModes
        .where((modeKey) => mainIntents.any((intent) => intent.key == modeKey && _sharedIntents.contains(_normalizeKey(intent.key))))
        .toList();
    if (selectedSharedIntentKeys.isNotEmpty) {
      pages.add(_buildSharedCategoriesPage(context, l10n, isRtl, profile));
    }

    // Add interest pages for non-shared intents (e.g., business/networking)
    for (final intent in selectedMainIntents) {
      if (!_sharedIntents.contains(_normalizeKey(intent.key))) {
        pages.add(_buildInterestPageForIntent(context, intent, profile, l10n, isRtl));
      }
    }

    // Compute diffs and check for changes
    final diffs = _computeDiffs(_originalSnapshot, profile);
    bool hasChanges = _isSaving; // Force hasChanges during save to prevent page list changes
    if (!hasChanges) {
      if (diffs['name'] != null) hasChanges = true;
      if (diffs['dateOfBirth'] != null) hasChanges = true;
      if (diffs['gender'] != null) hasChanges = true;
      if ((diffs['intentsAdded'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['intentsRemoved'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['languagesChanged'] as Map).isNotEmpty) hasChanges = true;
      if (diffs['bioChanged'] != null) hasChanges = true;
      if (diffs['photosChanged'] != null) hasChanges = true;
    }

    // Add a final page for submission only if there are changes
    if (hasChanges) {
      final allIntentsMap = <String, String>{for (var i in allIntents) i.key: i.translationKey};
      final interestKeyToDisplayKey = ref.read(interestDisplayMapProvider);
      final categoryKeyToDisplayKey = ref.read(categoryDisplayMapProvider);
      pages.add(_buildFinalReview(context, ref, [], profile, l10n, isRtl, allIntentsMap, interestKeyToDisplayKey, categoryKeyToDisplayKey));
    }

    return pages;
  }

  Widget _buildSubIntentsPage(BuildContext ctx, AppIntent intent, UserProfile profile, LocalizationState l10n, bool isRtl) {
    final subIntents = ref.watch(subIntentsProvider(intent.id));

    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(child: Text(localResolve(intent.translationKey), style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
              const SizedBox(width: 12),
              CircleAvatar(radius: 20, backgroundColor: Colors.grey.shade100, child: Icon(_getIconForIntent(intent.key))),
            ],
          ),
          const SizedBox(height: 20),

          if (subIntents.isEmpty)
             Text(localResolve('profileEditNoSubIntents'), style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: Colors.black54)),

          ...subIntents.map((sub) {
            final selected = profile.subIntents[intent.key]?.contains(sub.key) ?? false;
            final label = localResolve(sub.translationKey);

            final leading = _leadingCheckbox(
              loading: false,
              value: selected,
              onChanged: (_) => ref.read(profileEditProvider(widget.user.id).notifier).toggleSubIntent(intent.key, sub.key, awaitPersist: false),
            );

            return Card(
              elevation: selected ? 2 : 0,
              shape: selected
                  ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                      side: BorderSide(color: Theme.of(ctx).colorScheme.primary, width: 2),
                    )
                  : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
              margin: const EdgeInsets.only(bottom: 12.0),
              child: ListTile(
                leading: leading,
                title: AutoSizeText(label, minFontSize: 10, maxLines: 2, wrapWords: false),
                selected: selected,
                onTap: () => ref.read(profileEditProvider(widget.user.id).notifier).toggleSubIntent(intent.key, sub.key, awaitPersist: false),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildInterestPageForIntent(BuildContext ctx, AppIntent intent, UserProfile profile, LocalizationState l10n, bool isRtl) {
    // Prefer matching by intent key (robust to numeric id issues)
    final categories = ref.watch(nonSharedInterestCategoriesByKeyProvider(intent.key));

    final allIntentsMap = <String, String>{for (var i in ref.read(allIntentsProvider).asData?.value ?? []) i.key: i.translationKey};
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap
    );

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(child: Text('${l10n.getString('profileInterests')} — ${localResolve(intent.translationKey)}', style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
                const SizedBox(width: 12),
                CircleAvatar(radius: 20, backgroundColor: Colors.teal.shade50, child: const Icon(Icons.favorite, color: Colors.teal)),
              ],
            ),
            const SizedBox(height: 16),
            
            if (categories.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Text(localResolve('profileEditNoInterests'), style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
              ),
            
            ...categories.map((cat) {
              final categoryKey = cat.key;
              final prefLabel = localResolve(cat.translationKey);
              final children = ref.watch(interestChildrenProvider(cat.id));

              // Check if category is selected
              final prefixedCategory = '${intent.key}::$categoryKey';
              final isCategorySelected = profile.interests[prefixedCategory]?.contains(categoryKey) ?? false;

              void toggleCategory() {
                // Toggle only the category itself
                ref.read(profileEditProvider(widget.user.id).notifier).toggleInterest(prefixedCategory, categoryKey, awaitPersist: false);
              }

              if (children.isEmpty) {
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 12.0),
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                    side: BorderSide(color: Colors.grey.shade200, width: 1),
                  ),
                  child: ListTile(
                    key: PageStorageKey('${intent.key}::$categoryKey'),
                    leading: _leadingCheckbox(
                      loading: false,
                      value: isCategorySelected,
                      onChanged: (_) => toggleCategory(),
                    ),
                    title: Text(prefLabel, style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    onTap: () => toggleCategory(),
                  ),
                );
              } else {
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 12.0),
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                    side: BorderSide(color: Colors.grey.shade200, width: 1),
                  ),
                  child: ExpansionTile(
                    key: PageStorageKey('${intent.key}::$categoryKey'),
                    leading: _leadingCheckbox(
                      loading: false,
                      value: isCategorySelected,
                      onChanged: (_) => toggleCategory(),
                    ),
                    title: Text(prefLabel, style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: _buildInterestTree(
                          ctx,
                          ref,
                          children,
                          intent.key,
                          categoryKey,
                          profile,
                          l10n,
                          const <String>{},
                        ),
                      )
                    ],
                  ),
                );
              }
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAddPhoto() async {
    final l10n = ref.read(localizationProvider);

    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(l10n.getString('profileWizardAddPhotoFromGallery')),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: Text(l10n.getString('profileWizardAddPhotoFromCamera')),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(l10n.getString('generalCancel')),
                onTap: () => Navigator.pop(context, null),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (source == null) return;
    if (!mounted) return;

    final bytes = await PhotoEditor.pickAndEdit(context: context, source: source);
    if (bytes == null) return;
    if (mounted) {
      try {
        setState(() => _isLoading = true);
        PleaseWaitDialog.show(context); // ignore: use_build_context_synchronously
        await ref.read(profileEditProvider(widget.user.id).notifier).addPhotoFromBytes(bytes, awaitPersist: true);
      } catch (e) {
        final l10n = ref.read(localizationProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('profileWizardPhotoUploadFailed')}: $e')));
        }
      } finally {
        setState(() => _isLoading = false);
        PleaseWaitDialog.hide(context); // ignore: use_build_context_synchronously
      }
    }
  }

  Future<void> _handleEditPhoto(int index, String source) async {
    try {
      setState(() => _isLoading = true);
      PleaseWaitDialog.show(context);

      String? imagePath = source;

      // If source is not an http url -> it's an objectPath -> create signed url
      if (!source.startsWith('http://') && !source.startsWith('https://')) {
        imagePath = await StorageHelper.getSignedUrl(source, ttlSeconds: 600);
        if (imagePath == null) throw Exception('Failed to create signed URL for editing.');
      } else {
        // source is a http url; it may be a Supabase public object url without token.
        // If it already contains token (signed) use as-is; otherwise ask StorageHelper to produce a signed URL.
        final uri = Uri.tryParse(source);
        if (uri != null) {
          if (uri.queryParameters.containsKey('token') || uri.query.contains('X-Amz-')) {
            imagePath = source;
          } else {
            final signed = await StorageHelper.getSignedUrl(source, ttlSeconds: 600);
            if (signed != null && signed.isNotEmpty) {
              imagePath = signed;
            } else {
              imagePath = source; // fallback (may fail for private buckets)
            }
          }
        }
      }

      // For web, we need to download the image and save it temporarily
      // For mobile, we can use the URL directly with image_cropper
      if (kIsWeb) {
        final photoService = ref.read(photoServiceProvider);
        final existing = await photoService.downloadImageBytes(imagePath);
        if (existing == null) throw Exception('Failed to download image for editing.');
        final edited = await PhotoEditor.editBytes(context, existing); // ignore: use_build_context_synchronously
        if (edited == null) {
          // user cancelled edit
          return;
        }
        await ref.read(profileEditProvider(widget.user.id).notifier).replacePhotoAtIndex(index, bytes: edited, awaitPersist: true);
      } else {
        // For mobile, use the new editImage method
        final edited = await PhotoEditor.editImage(context: context, imagePath: imagePath); // ignore: use_build_context_synchronously
        if (edited == null) {
          // user cancelled edit
          return;
        }
        await ref.read(profileEditProvider(widget.user.id).notifier).replacePhotoAtIndex(index, bytes: edited, awaitPersist: true);
      }
    } catch (e) {
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('profileWizardPhotoEditFailed')}: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        PleaseWaitDialog.hide(context);
      }
    }
  }

  Future<void> _handleRemovePhoto(int index) async {
    try {
      await ref.read(profileEditProvider(widget.user.id).notifier).removePhotoAt(index, awaitPersist: true);
    } catch (e) {
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('profileWizardPhotoRemoveFailed')}: $e')));
      }
    }
  }

  Future<void> _handleReorderPhotos(int oldIndex, int newIndex) async {
    try {
      await ref.read(profileEditProvider(widget.user.id).notifier).reorderPhotos(oldIndex, newIndex, awaitPersist: true);
    } catch (e) {
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('profileWizardPhotoReorderFailed')}: $e')));
      }
    }
  }

  Widget _buildPhotoEditorSection(UserProfile profile) {
    final l10n = ref.read(localizationProvider);
    final photos = profile.photos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(l10n.getString('profileWizardPhotosTitle'), style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
            onPressed: _isLoading || photos.length >= 5 ? null : _handleAddPhoto,
            icon: const Icon(Icons.add_a_photo_outlined),
            tooltip: l10n.getString('profileWizardAddPhotoTooltip'),
          ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: photos.isEmpty
            ? Center(child: Text(l10n.getString('profileWizardNoPhotos'), style: TextStyle(color: Colors.grey)))
              : ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex -= 1;
                    _handleReorderPhotos(oldIndex, newIndex);
                  },
                  itemCount: photos.length,
                  itemBuilder: (ctx, idx) {
                    final source = photos[idx];
                    return Container(
                      key: ValueKey(source),
                      width: 100,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Card(
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            child: SignedImage(
                              source: source,
                              fit: BoxFit.cover,
                              width: 100,
                              height: 120,
                              placeholder: Container(color: Colors.grey.shade100),
                              errorWidget: Container(color: Colors.grey.shade200, child: const Icon(Icons.broken_image)),
                            ),
                          ),
                          Positioned(
                            right: 4, top: 4,
                            child: Column(
                              children: [
                                IconButton(icon: Icon(Icons.edit, size: 18, color: Theme.of(context).colorScheme.onPrimary), onPressed: () => _handleEditPhoto(idx, source)),
                                IconButton(icon: const Icon(Icons.delete_forever, size: 18, color: Colors.redAccent), onPressed: () => _handleRemovePhoto(idx)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        Text(l10n.getString('profileWizardPhotosTip'), style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      ],
    );
  }

  Widget _buildLanguagesEditorSection(UserProfile profile, LocalizationState l10n) {
    final available = ref.watch(languageOptionsProvider);
    final current = profile.languagesKnown;
    final filteredEntries = <MapEntry<String, List<String>>>[];
    final langs = current['languages'] ?? [];
    for (final lang in langs) {
      final skills = current[lang] ?? [];
      filteredEntries.add(MapEntry(lang, skills));
    }
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12.0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.getString('profileLanguagesKnown'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (filteredEntries.isEmpty)
            Text(l10n.getString('profileNoLanguages'), style: TextStyle(color: Colors.grey.shade600))
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: filteredEntries.map((entry) {
                final langCode = entry.key;
                final skills = entry.value;
                final name = l10n.getString('lang_$langCode');
                // Format skills with capitalization
                final skillsText = skills.map((skill) {
                  final skillName = l10n.getString(skill);
                  return skillName;
                }).join(', ');
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface),
                            children: [
                              TextSpan(
                                text: '$name: ',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(text: skillsText),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => ref.read(profileEditProvider(widget.user.id).notifier).removeLanguage(langCode),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: l10n.getString('profileWizardRemoveLanguageTooltip'),
                        color: Colors.grey.shade600,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          const SizedBox(height: 12),
          available.when(
            data: (list) {
              return ElevatedButton.icon(
                onPressed: () => _showLanguageSkillsDialog(context, list, current, l10n),
                icon: const Icon(Icons.language),
                label: Text(l10n.getString('profileWizardSelectLanguagesAndSkills')),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              );
            },
            loading: () => const CircularProgressIndicator(),
            error: (_, _) => Text(l10n.getString('profileWizardErrorLoadingLanguages')),
          )
        ]),
      ),
    );
  }

  void _showLanguageSkillsDialog(BuildContext context, List<Map<String, String>> availableLanguages, Map<String, List<String>> currentLanguages, LocalizationState l10n) {
    final selectedLanguages = Map<String, List<String>>.from(currentLanguages);
    final availableSkills = ['read', 'understand', 'speak'];

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            // Check if all selected languages have at least one skill
            bool hasValidationErrors = false;
            String validationMessage = '';

            for (final langCode in selectedLanguages.keys) {
              final skills = selectedLanguages[langCode] ?? [];
              if (skills.isEmpty) {
                hasValidationErrors = true;
                validationMessage = l10n.getString('profileLanguageSkillsRequired');
                break;
              }
            }

            return AlertDialog(
              title: Text(l10n.getString('profileLanguagesKnown')),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    if (hasValidationErrors)
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                validationMessage,
                                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        children: availableLanguages.map((lang) {
                          final langCode = lang['code']!;
                          final langName = l10n.getString('lang_$langCode');
                          final isSelected = selectedLanguages.containsKey(langCode);
                          final skills = selectedLanguages[langCode] ?? [];
                          final hasSkillsError = isSelected && skills.isEmpty;

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            shape: hasSkillsError
                                ? RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(color: Colors.red.shade300, width: 2),
                                  )
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: isSelected,
                                        onChanged: (value) {
                                          setState(() {
                                            if (value == true) {
                                              selectedLanguages[langCode] = [];
                                            } else {
                                              selectedLanguages.remove(langCode);
                                            }
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: Text(
                                          langName,
                                          style: TextStyle(
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            color: hasSkillsError ? Colors.red.shade700 : null,
                                          ),
                                        ),
                                      ),
                                      if (hasSkillsError)
                                        Icon(Icons.warning, color: Colors.red.shade700, size: 20),
                                    ],
                                  ),
                                  if (isSelected) ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          l10n.getString('profileLanguageSkills'),
                                          style: TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '*',
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: availableSkills.map((skill) {
                                        final skillName = l10n.getString(skill);
                                        final isSkillSelected = skills.contains(skill);
                                        return FilterChip(
                                          label: Text(skillName),
                                          selected: isSkillSelected,
                                          onSelected: (selected) {
                                            setState(() {
                                              if (selected) {
                                                skills.add(skill);
                                              } else {
                                                skills.remove(skill);
                                              }
                                            });
                                          },
                                          backgroundColor: isSkillSelected ? Theme.of(context).colorScheme.primary.withValues(alpha:0.1) : null,
                                          selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha:0.2),
                                          checkmarkColor: Theme.of(context).colorScheme.primary,
                                        );
                                      }).toList(),
                                    ),
                                    if (hasSkillsError)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(
                                          l10n.getString('profileSelectAtLeastOneSkill'),
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.getString('generalCancel')),
                ),
                ElevatedButton(
                  onPressed: hasValidationErrors ? null : () async {
                    // Update the profile with selected languages and skills
                    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);
                    // Remove languages not in selected
                    final toRemove = currentLanguages.keys.where((lang) => !selectedLanguages.containsKey(lang)).toList();
                    for (final lang in toRemove) {
                      notifier.removeLanguage(lang);
                    }
                    // Add or update selected languages with skills
                    selectedLanguages.forEach((langCode, skills) {
                      notifier.setLanguageSkills(langCode, skills);
                    });
                    // Save to local storage and database
                    await notifier.saveProfile(showLoading: false, markComplete: false);
                    Navigator.pop(dialogContext); // ignore: use_build_context_synchronously
                  },
                  child: Text(l10n.getString('generalSave')),
                ),
              ],
            );
          },
        );
      },
    );
  }


  Widget _buildFinalReview(
      BuildContext ctx,
      WidgetRef ref,
      List<InterestCategory> categories,
      UserProfile? profile,
      LocalizationState l10n,
      bool isRtl,
      Map<String, String> allIntentsMap,
      Map<String, String> interestKeyToDisplayKey,
      Map<String, String> categoryKeyToDisplayKey,
      ) {
    if (profile == null) return const Center(child: CircularProgressIndicator());
    
    String localResolve(String key) => _resolveDisplayLabel(
      l10n, 
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestKeyToDisplayKey,
      categoryKeyToDisplayKey: categoryKeyToDisplayKey
    );
    
    final diffs = _computeDiffs(_originalSnapshot, profile);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12.0),
      side: BorderSide(color: Colors.grey.shade200, width: 1),
    );
    final cardMargin = const EdgeInsets.only(bottom: 14.0);
    const addIcon = Icon(Icons.add_circle_outline, color: Colors.green);
    const removeIcon = Icon(Icons.remove_circle_outline, color: Colors.red);
    const editIcon = Icon(Icons.edit_outlined, color: Colors.blue);

    final List<Widget> basicChanges = [];
    final List<Widget> goalChanges = [];
    final List<Widget> interestChanges = [];
    final List<Widget> languagesChanges = [];

    if (diffs['name'] != null) {
      final m = diffs['name'] as Map;
      basicChanges.add(ListTile(
        leading: editIcon,
        title: Text(localResolve('profileName')),
        subtitle: Text('${l10n.getString('profileWizardFrom')}: "${m['from'] ?? '-'}"\n${l10n.getString('profileWizardTo')}: "${m['to'] ?? '-'}"'),
        isThreeLine: true,
      ));
    }
    if (diffs['dateOfBirth'] != null) {
      final m = diffs['dateOfBirth'] as Map;
      String from = '-';
      String to = '-';
      try {
        from = m['from'] != null ? _formatDateWithL10n(DateTime.parse(m['from']), l10n) : '-';
      } catch (_) {
        // Ignore invalid date format
        from = m['from']?.toString() ?? '-';
      }
      try {
        to = m['to'] != null ? _formatDateWithL10n(DateTime.parse(m['to']), l10n) : '-';
      } catch (_) {
        // Ignore invalid date format
        to = m['to']?.toString() ?? '-';
      }
      basicChanges.add(ListTile(
        leading: editIcon,
        title: Text(localResolve('profileBirthday')),
        subtitle: Text('${l10n.getString('profileWizardFrom')}: $from\n${l10n.getString('profileWizardTo')}: $to'),
        isThreeLine: true,
      ));
    }
    if (diffs['gender'] != null) {
      final m = diffs['gender'] as Map;
      basicChanges.add(ListTile(
        leading: editIcon,
        title: Text(localResolve('profileGender')),
        subtitle: Text('${l10n.getString('profileWizardFrom')}: ${_genderLabelFor(m['from'], l10n)}\n${l10n.getString('profileWizardTo')}: ${_genderLabelFor(m['to'], l10n)}'),
        isThreeLine: true,
      ));
    }

    if (diffs['photosChanged'] != null) {
      final m = diffs['photosChanged'] as Map;
      final fromPhotos = (m['from'] as List?)?.cast<String>() ?? [];
      final toPhotos = (m['to'] as List?)?.cast<String>() ?? [];
      final addedPhotos = toPhotos.where((photo) => !fromPhotos.contains(photo)).toList();
      final removedPhotos = fromPhotos.where((photo) => !toPhotos.contains(photo)).toList();
      final isReordered = const ListEquality<String>().equals((fromPhotos.toSet().toList()..sort()), (toPhotos.toSet().toList()..sort())) &&
          !const ListEquality<String>().equals(fromPhotos, toPhotos);

      if (addedPhotos.isNotEmpty) {
        basicChanges.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: addIcon,
                title: Text(l10n.getString('profileWizardPhotosAdded')),
                subtitle: Text(l10n.getString('profileWizardNewPhotosAdded').replaceAll('{count}', '${addedPhotos.length}')),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: addedPhotos.length,
                    itemBuilder: (ctx, idx) {
                      final source = addedPhotos[idx];
                      return Container(
                        width: 70,
                        margin: const EdgeInsets.only(right: 8),
                        child: SignedImage(
                          source: source,
                          fit: BoxFit.cover,
                          width: 70,
                          height: 80,
                          placeholder: Container(color: Colors.grey.shade100),
                          errorWidget: Container(color: Colors.grey.shade200, child: const Icon(Icons.broken_image, size: 20)),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }

      if (removedPhotos.isNotEmpty) {
        basicChanges.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: removeIcon,
                title: Text(l10n.getString('profileWizardPhotosRemoved')),
                subtitle: Text(l10n.getString('profileWizardPhotosRemoved').replaceAll('{count}', '${removedPhotos.length}')),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: removedPhotos.length,
                    itemBuilder: (ctx, idx) {
                      final source = removedPhotos[idx];
                      return Container(
                        width: 70,
                        margin: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            SignedImage(
                              source: source,
                              fit: BoxFit.cover,
                              width: 70,
                              height: 80,
                              placeholder: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                              errorWidget: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha:0.8), child: Icon(Icons.broken_image, size: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7))),
                            ),
                            Positioned.fill(
                              child: Container(
                                color: Colors.black.withValues(alpha:0.5),
                                child: Center(
                                  child: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.onSurface, size: 24),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }

      if (isReordered) {
        basicChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileWizardPhotoOrderChanged')),
            subtitle: Text(l10n.getString('profileWizardPhotoOrderDesc')),
          ),
        );
      }
    }

    final Map<String, List<String>> intentToAddedSubs = {};
    final List<String> intentsAdded = List<String>.from(diffs['intentsAdded'] as List<dynamic>);
    for (final intent in intentsAdded) {
      intentToAddedSubs[intent] = [];
    }
    final Map<String, List<String>> subsAdded = Map<String, List<String>>.from(diffs['subIntentsAdded'] as Map);
    subsAdded.forEach((intent, subs) {
      if (!intentToAddedSubs.containsKey(intent)) intentToAddedSubs[intent] = [];
      intentToAddedSubs[intent]!.addAll(subs.where((s) => _normalizeKey(s) != _normalizeKey(intent)).map((s) => _tryGetString(l10n, s) ?? _humanizeKey(s)));
    });
    for (final intent in intentToAddedSubs.keys) {
      final subs = intentToAddedSubs[intent]!;
      final title = subs.isNotEmpty ? '${_resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap)} - ${subs.join(', ')}' : _resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap);
      goalChanges.add(ListTile(
        leading: addIcon,
        title: Text(title),
      ));
    }

    final Map<String, List<String>> intentToRemovedSubs = {};
    final List<String> intentsRemoved = List<String>.from(diffs['intentsRemoved'] as List<dynamic>);
    for (final intent in intentsRemoved) {
      intentToRemovedSubs[intent] = [];
    }
    final Map<String, List<String>> subsRemoved = Map<String, List<String>>.from(diffs['subIntentsRemoved'] as Map);
    subsRemoved.forEach((intent, subs) {
      if (!intentToRemovedSubs.containsKey(intent)) intentToRemovedSubs[intent] = [];
      intentToRemovedSubs[intent]!.addAll(subs.where((s) => _normalizeKey(s) != _normalizeKey(intent)).map((s) => _tryGetString(l10n, s) ?? _humanizeKey(s)));
    });
    for (final intent in intentToRemovedSubs.keys) {
      final subs = intentToRemovedSubs[intent]!;
      final title = subs.isNotEmpty ? '${_resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap)} - ${subs.join(', ')}' : _resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap);
      goalChanges.add(ListTile(
        leading: removeIcon,
        title: Text(title),
      ));
    }

    String formatPrefixedCategory(String prefixed) {
      final parts = prefixed.split('::');

      if (parts.first == 'shared' && parts.length >= 2) {
          final catKey = parts[1];
          final catLabel = categoryKeyToDisplayKey[catKey] ?? catKey;
          return _tryGetString(l10n, catLabel) ?? _humanizeKey(catLabel);
      }

      final cat = parts.length > 1 ? parts[1] : '';
      final catLabel = cat.isNotEmpty ? localResolve(categoryKeyToDisplayKey[cat] ?? cat) : null;
      return catLabel ?? prefixed;
    }

    final Map<String, List<String>> interestsAdded = Map<String, List<String>>.from(diffs['interestsAdded'] as Map);
    final Map<String, List<String>> categoryToAddedSubs = {};
    final Set<String> categoriesAdded = {};
    interestsAdded.forEach((pref, interests) {
      final parts = pref.split('::');
      final catKey = parts.length > 1 ? parts[1] : '';
      final categoryLabel = formatPrefixedCategory(pref);
      final subs = interests.where((it) => _normalizeKey(it) != _normalizeKey(catKey)).map((it) => localResolve(interestKeyToDisplayKey[it] ?? it)).toSet().toList();
      if (subs.isNotEmpty) {
        if (!categoryToAddedSubs.containsKey(categoryLabel)) categoryToAddedSubs[categoryLabel] = [];
        categoryToAddedSubs[categoryLabel]!.addAll(subs);
      }
      if (interests.any((it) => _normalizeKey(it) == _normalizeKey(catKey))) {
        categoriesAdded.add(categoryLabel);
      }
    });
    final allAddedCategories = categoriesAdded.union(categoryToAddedSubs.keys.toSet());
    for (final category in allAddedCategories) {
      final subs = categoryToAddedSubs[category] ?? [];
      final title = subs.isNotEmpty ? '$category: ${subs.join(', ')}' : category;
      interestChanges.add(ListTile(
        leading: addIcon,
        title: Text(title),
      ));
    }

    final Map<String, List<String>> interestsRemoved = Map<String, List<String>>.from(diffs['interestsRemoved'] as Map);
    final Map<String, List<String>> categoryToRemovedSubs = {};
    final Set<String> categoriesRemoved = {};
    interestsRemoved.forEach((pref, interests) {
      final parts = pref.split('::');
      final catKey = parts.length > 1 ? parts[1] : '';
      final categoryLabel = formatPrefixedCategory(pref);
      final subs = interests.where((it) => _normalizeKey(it) != _normalizeKey(catKey)).map((it) => localResolve(interestKeyToDisplayKey[it] ?? it)).toSet().toList();
      if (subs.isNotEmpty) {
        if (!categoryToRemovedSubs.containsKey(categoryLabel)) categoryToRemovedSubs[categoryLabel] = [];
        categoryToRemovedSubs[categoryLabel]!.addAll(subs);
      }
      if (interests.any((it) => _normalizeKey(it) == _normalizeKey(catKey))) {
        categoriesRemoved.add(categoryLabel);
      }
    });
    final allRemovedCategories = categoriesRemoved.union(categoryToRemovedSubs.keys.toSet());
    for (final category in allRemovedCategories) {
      final subs = categoryToRemovedSubs[category] ?? [];
      final title = subs.isNotEmpty ? '$category: ${subs.join(', ')}' : category;
      interestChanges.add(ListTile(
        leading: removeIcon,
        title: Text(title),
      ));
    }

    final Map<String, Map<String, List<String>>> languagesChanged = Map<String, Map<String, List<String>>>.from(diffs['languagesChanged'] as Map);
    final Map<String, List<String>> addedPerLang = {};
    final Map<String, List<String>> removedPerLang = {};
    languagesChanged.forEach((lang, changes) {
      final added = changes['added'] as List<String>;
      final removed = changes['removed'] as List<String>;
      if (added.isNotEmpty) {
        addedPerLang[lang] = added;
      }
      if (removed.isNotEmpty) {
        removedPerLang[lang] = removed;
      }
    });
    addedPerLang.forEach((lang, skills) {
      final langName = _resolveDisplayLabel(l10n, 'lang_$lang');
      final skillsText = skills.join(', ');
      languagesChanges.add(ListTile(
        leading: addIcon,
        title: Text('$langName - $skillsText'),
      ));
    });
    removedPerLang.forEach((lang, skills) {
      final langName = _resolveDisplayLabel(l10n, 'lang_$lang');
      final skillsText = skills.join(', ');
      languagesChanges.add(ListTile(
        leading: removeIcon,
        title: Text('$langName - $skillsText'),
      ));
    });

    final List<Widget> entries = [];
    if (basicChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_basics'),
            initiallyExpanded: true,
            title: Text(l10n.getString('profileEditBasics'), style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            children: basicChanges,
          ),
        ),
      );
    }

    if (goalChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_goals'),
            initiallyExpanded: true,
            title: Text(l10n.getString('profileEditIntentsTitle'), style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            children: goalChanges,
          ),
        ),
      );
    }

    if (interestChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_interests'),
            initiallyExpanded: true,
            title: Text(l10n.getString('profileInterests'), style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            children: interestChanges,
          ),
        ),
      );
    }

    if (languagesChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_languages'),
            initiallyExpanded: true,
            title: Text(l10n.getString('profileLanguagesISpeak'), style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            children: languagesChanges,
          ),
        ),
      );
    }

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 18.0),
        child: ImprovedScrolling(
          scrollController: ScrollController(),
          enableKeyboardScrolling: true,
          child: ListView(
            children: [
              Row(
                children: [
                  Expanded(child: Text(l10n.getString('profileEditReviewTitle'), style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
                  const SizedBox(width: 12),
                  CircleAvatar(radius: 22, backgroundColor: Colors.blue.shade50, child: const Icon(Icons.check_circle_outline, color: Colors.blue)),
                ],
              ),
              const SizedBox(height: 16),
              if (entries.isEmpty)
                Center(child: Text(l10n.getString('profileNotSet'))),
              ...entries,
              const SizedBox(height: 24),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(int totalSteps, int currentIndex) {
    final progress = (totalSteps <= 1) ? 0.0 : (currentIndex / (totalSteps - 1)).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8.0),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar(BuildContext context, LocalizationState l10n, List<Widget> pages) {
    final totalPages = pages.length;
    final bool isLastPage = _currentPageIndex == totalPages - 1;
    final bool isFirstPage = _currentPageIndex == 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 14.0).copyWith(bottom: 22.0),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.shade200, width: 1.0)),
      ),
      child: Row(
        children: [
          if (!isFirstPage)
            TextButton.icon(
              onPressed: () => _handleBackPage(pages),
              icon: const Icon(Icons.arrow_back),
              label: Text(l10n.getString('generalBack')),
            )
          else
            Opacity(
              opacity: 0.0,
              child: TextButton.icon(onPressed: null, icon: Icon(Icons.arrow_back), label: Text(l10n.getString('generalBack')))
            ),
          const Spacer(),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 12.0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
            ),
            onPressed: isLastPage ? (_isLoading ? null : _submit) : () async => await _handleNextPage(),
            child: isLastPage && _isLoading
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary))
                : Text(isLastPage ? l10n.getString('generalSave') : l10n.getString('generalNext')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    String langCode = 'en';
    try {
      final cur = l10n.currentLocale;
      langCode = _extractLangCode(cur);
    } catch (_) {
      // Ignore invalid locale format
      langCode = 'en';
    }
    final isRtl = ['ar', 'he'].contains(langCode.toLowerCase());

    final profileEditState = ref.watch(profileEditProvider(widget.user.id));
    final allIntentsAsync = ref.watch(allIntentsProvider);
    final allInterestsAsync = ref.watch(allInterestsProvider);

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
            },
          ),
          title: Text(l10n.getString('profileEditTitle')),
          automaticallyImplyLeading: false,
          elevation: 0,
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
          foregroundColor: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
        ),
        body: profileEditState.when(
          data: (profile) {
            if (profile == null || allIntentsAsync.isLoading || allInterestsAsync.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            if(allIntentsAsync.hasError) return Center(child: Text('${l10n.getString('profileWizardErrorLoadingIntents')}: ${allIntentsAsync.error}'));
            if(allInterestsAsync.hasError) return Center(child: Text('${l10n.getString('profileWizardErrorLoadingInterests')}: ${allInterestsAsync.error}'));

            final allIntentsData = allIntentsAsync.asData!.value;
            final allInterestsData = allInterestsAsync.asData!.value;

            final pages = _buildWizardPages(context, l10n, isRtl, profile, allIntentsData, allInterestsData);

            // Precache profile photos (UI side) so images render immediately.
            // This uses any cached signed URLs from StorageHelper (prewarmed in provider).
            if (!_didPrefetchPhotos) {
              _didPrefetchPhotos = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                for (final src in profile.photos) {
                  if (src.isEmpty) continue;
                  final cached = StorageHelper.getCachedUrl(src);
                  if (cached != null && cached.isNotEmpty) {
                    try {
                      precacheImage(NetworkImage(cached), context);
                    } catch (_) {}
                  } else {
                    // Try to obtain a signed URL (async) and precache when available
                    StorageHelper.getSignedUrl(src, ttlSeconds: 600).then((signed) {
                      if (!mounted) return;
                      if (signed != null && signed.isNotEmpty) {
                        try {
                          precacheImage(NetworkImage(signed), context); // ignore: use_build_context_synchronously
                        } catch (_) {}
                      }
                    });
                  }
                }
              });
            }

            return Column(
              children: [
                const SizedBox(height: 10),
                _buildProgressIndicator(pages.length, _currentPageIndex),
                const SizedBox(height: 10),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: pages,
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text('${l10n.getString('generalError')}: $e'))),
        bottomNavigationBar: profileEditState.when(
          data: (profile) {
            if (profile == null) return const SizedBox.shrink();
            
            if (allIntentsAsync.isLoading || allInterestsAsync.isLoading) return const SizedBox.shrink();
            if (allIntentsAsync.hasError || allInterestsAsync.hasError) return const SizedBox.shrink();

            final allIntentsData = allIntentsAsync.asData!.value;
            final allInterestsData = allInterestsAsync.asData!.value;

            final pages = _buildWizardPages(context, l10n, isRtl, profile, allIntentsData, allInterestsData);
            return _buildBottomNavBar(context, l10n, pages);
          },
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  String _genderLabelFor(String? storedKey, LocalizationState l10n) {
    if (storedKey == null || storedKey.trim().isEmpty) {
      return l10n.getString('profileNotSet');
    }

    final options = ref.read(genderOptionsProvider).asData?.value ?? [];

    final Map<String, String> found = options.firstWhere(
      (o) => (o['key'] ?? '') == storedKey,
      orElse: () => <String, String>{},
    );

    if (found.isNotEmpty) {
      final displayKey = found['displayKey'] ?? '';
      try {
        final localized = _tryGetString(l10n, displayKey);
        if (localized != null) {
          return localized;
        }
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final directTranslation = _tryGetString(l10n, storedKey);
      if (directTranslation != null) {
        return directTranslation;
      }
    } catch (_) {}

    // Final fallback to humanized key
    return _humanizeKey(storedKey);
  }

  String _ageLabelFor(LocalizationState l10n) {
    const ageKey = 'profileYourAge';
    try {
      final s = l10n.getString(ageKey);
      if (s.trim().isNotEmpty && s != ageKey && !s.startsWith('profile')) {
        return s;
      }
    } catch (_) {}
    final lang = _extractLangCode(l10n.currentLocale);
    if (lang.toLowerCase().startsWith('he')) return 'גילך';
    return 'Your age';
  }

  String _formatDateWithL10n(DateTime date, LocalizationState l10n) {
    try {
      final curLocale = l10n.currentLocale;
      final langCode = _extractLangCode(curLocale).toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(date);
        } catch (e) {
          // Hebrew DateFormat failed, fall back
        }
      }

      final monthKeys = [
        'month_january',
        'month_february',
        'month_march',
        'month_april',
        'month_may',
        'month_june',
        'month_july',
        'month_august',
        'month_september',
        'month_october',
        'month_november',
        'month_december'
      ];

      final monthKey = monthKeys[date.month - 1];
      final translatedMonth = _tryGetString(l10n, monthKey);
      final day = date.day;
      final year = date.year;
      
      if (translatedMonth != null) {
        return '$translatedMonth $day, $year';
      }

      try {
        final localeTag = curLocale.toLanguageTag();
        final df = DateFormat.yMMMMd(localeTag.isNotEmpty ? localeTag : null);
        return df.format(date);
      } catch (e) {
        // Intl DateFormat fallback failed
      }

      return DateFormat('MMMM d, yyyy').format(date);
    } catch (e) {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }
}
