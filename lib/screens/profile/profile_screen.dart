// lib/screens/profile/profile_screen.dart
// Complete ProfileScreen updated to show ordered photo thumbnails (tap to preview full-screen),
// bio, languages, and all previous functionality preserved.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:extended_image/extended_image.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/widgets/verified_badge.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/services/match_rating_service.dart';

final supabase = Supabase.instance.client;

String _normalizeKey(String s) {
  final trimmed = s.trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  // Cache for resolved display labels to avoid repeated computations
  static final Map<String, String> _displayLabelCache = {};

  // Humanize a key as a last-resort fallback for display:
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

  // Safe wrapper for l10n.getString: returns null when translation not found
  String? _tryGetString(LocalizationState l10n, String key) {
    try {
      final val = l10n.getString(key);
      // Check if translation is missing (returns 'key...' format)
      if (val.trim().isEmpty || val == key || val.endsWith('...')) {
        return null;
      }
      return val;
    } catch (_) {
      return null;
    }
  }

  // Extract language code from localization provider currentLocale value
  String _extractLangCode(dynamic cur) {
    try {
      if (cur == null) return 'en';
      if (cur is Locale) return cur.languageCode;
      if (cur is String) return (cur.split(RegExp('[-_]')).first);
      return cur.toString().split(RegExp('[-_]')).first;
    } catch (_) {
      return 'en';
    }
  }

  // Format a DateTime using localization provider:
  String _formatDateWithL10n(DateTime date, LocalizationState l10n) {
    try {
      final cur = l10n.currentLocale;
      final langCode = _extractLangCode(cur).toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(date);
        } catch (_) {}
      }

      final enMonthLower = DateFormat.MMMM('en_US').format(date).toLowerCase();
      final monthKey = 'month_$enMonthLower';
      final translatedMonth = _tryGetString(l10n, monthKey);
      if (translatedMonth != null) {
        return '$translatedMonth ${date.day}, ${date.year}';
      }

      try {
        final localeTag = cur.toLanguageTag();
        final df = localeTag.isNotEmpty ? DateFormat.yMMMMd(localeTag) : DateFormat.yMMMMd();
        return df.format(date);
      } catch (_) {}

      return DateFormat('MMMM d, yyyy').format(date);
    } catch (_) {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }

  // Calculate age from date of birth
  int _calculateAge(DateTime birthDate) {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month || (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  // Get age label for localization (same as profile wizard)
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

  // Check if current language is RTL
  bool _isRtl(LocalizationState l10n) {
    final langCode = _extractLangCode(l10n.currentLocale);
    return ['ar', 'he'].contains(langCode.toLowerCase());
  }

  // Resolve display label for a key or composite key into a user-friendly string.
  String _resolveDisplayLabel(
    LocalizationState l10n,
    String keyOrDisplay, {
    Map<String, String>? interestKeyToDisplayKey,
    Map<String, String>? categoryKeyToDisplayKey,
    Map<String, String>? allIntentsMap, // For sub-intents
    String? fallbackProvided,
  }) {
    // Create cache key from inputs
    final cacheKey = '$keyOrDisplay|${l10n.currentLocale.languageCode}|${interestKeyToDisplayKey?.length ?? 0}|${categoryKeyToDisplayKey?.length ?? 0}|${allIntentsMap?.length ?? 0}|$fallbackProvided';
    if (_displayLabelCache.containsKey(cacheKey)) {
      return _displayLabelCache[cacheKey]!;
    }

    // Special case for invalid key "0"
    if (keyOrDisplay == '0') {
      final result = 'Unknown Intent';
      _displayLabelCache[cacheKey] = result;
      return result;
    }

    if (keyOrDisplay.trim().isEmpty) {
      final result = fallbackProvided ?? '';
      _displayLabelCache[cacheKey] = result;
      return result;
    }

    if (keyOrDisplay.contains('::')) {
      final parts = keyOrDisplay.split('::');
      if (parts.length >= 2) {
        final left = parts[0];
        final right = parts.sublist(1).join('::'); // keep any extra separators

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
        final result = '$leftLocalized — $rightLocalized';
        _displayLabelCache[cacheKey] = result;
        return result;
      }
    }

    if (allIntentsMap != null && allIntentsMap.containsKey(keyOrDisplay)) {
      final mapped = allIntentsMap[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      final result = _humanizeKey(mapped);
      _displayLabelCache[cacheKey] = result;
      return result;
    }

    if (interestKeyToDisplayKey != null && interestKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = interestKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      final result = _humanizeKey(mapped);
      _displayLabelCache[cacheKey] = result;
      return result;
    }

    if (categoryKeyToDisplayKey != null && categoryKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = categoryKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      final result = _humanizeKey(mapped);
      _displayLabelCache[cacheKey] = result;
      return result;
    }

    final direct = _tryGetString(l10n, keyOrDisplay);
    if (direct != null) {
      _displayLabelCache[cacheKey] = direct;
      return direct;
    }

    if (fallbackProvided != null && fallbackProvided.trim().isNotEmpty) {
      _displayLabelCache[cacheKey] = fallbackProvided;
      return fallbackProvided;
    }

    final result = _humanizeKey(keyOrDisplay);
    _displayLabelCache[cacheKey] = result;
    return result;
  }

  // Open a full-screen preview of the image source (objectPath or url)
  void _openPhotoPreview(BuildContext context, String source, LocalizationState l10n) async {
    String? url = source;
    try {
      // If source is not an http url, get signed url for objectPath
      if (!source.startsWith('http://') && !source.startsWith('https://')) {
        url = await StorageHelper.getSignedUrl(source, ttlSeconds: 3600);
      } else {
        // Source is an http url. It may be:
        //  - already a signed URL (has token) -> use directly
        //  - a Supabase "public" storage URL without token -> request signed URL
        //  - some external URL -> use directly
        final uri = Uri.tryParse(source);
        if (uri != null) {
          if (uri.queryParameters.containsKey('token') || uri.query.contains('X-Amz-')) {
            // Already signed; use as-is
            url = source;
          } else {
            // Try to convert Supabase public object URL to signed URL (StorageHelper handles extraction)
            final signed = await StorageHelper.getSignedUrl(source, ttlSeconds: 3600);
            if (signed != null && signed.isNotEmpty) {
              url = signed;
            } else {
              // Fallback to original source (may fail if bucket is private)
              url = source;
            }
          }
        }
      }
    } catch (e) {
      url = source;
    }

    if (url == null || url.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('generalImageLoadFailed'))));
      }
      return;
    }

    // url is non-null and non-empty here; assert for NetworkImage
    final displayUrl = url;

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(8.0),
          backgroundColor: Colors.black,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: Stack(
              children: [
                ExtendedImage.network(
                  displayUrl,
                  cache: true,
                  cacheKey: StorageHelper.cacheKeyForSource(source),
                  mode: ExtendedImageMode.gesture,
                  fit: BoxFit.contain,
                  initGestureConfigHandler: (_) => GestureConfig(
                    minScale: 1.0,
                    maxScale: 5.0,
                    animationMinScale: 0.8,
                    animationMaxScale: 6.0,
                    speed: 1.0,
                    inertialSpeed: 100.0,
                    initialScale: 1.0,
                    inPageView: false,
                  ),
                  loadStateChanged: (state) {
                    switch (state.extendedImageLoadState) {
                      case LoadState.loading:
                        return const Center(
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                        );
                      case LoadState.completed:
                        return ExtendedRawImage(
                          image: state.extendedImageInfo?.image,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                        );
                      case LoadState.failed:
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text(
                              l10n.getString('generalImageLoadFailed'),
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                    }
                  },
                ),
                Positioned(
                  top: 24,
                  right: 8,
                  child: IconButton(
                    icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurface),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final user = supabase.auth.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(_t(l10n, 'generalError', fallbackProvided: 'Error'))));
    }
    final userId = user.id;
    final ratingSummaryAsync = ref.watch(userRatingSummaryProvider(userId));
    final ratingQuestionsAsync = ref.watch(ratingQuestionsProvider);

    // Watch all providers needed for the page
    final profileAsyncValue = ref.watch(userProfileProvider(userId));
    final allIntentsAsync = ref.watch(allIntentsProvider);
    final mainIntents = ref.watch(mainIntentsProvider);
    // Use the new provider to get only relevant interests for the selected intents
    final allIntents = allIntentsAsync.asData?.value ?? [];
    final relevantInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
    final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
    final interestDisplayMap = {for (var i in allInterests) i.key: i.translationKey};
    final categoryDisplayMap = {for (var i in allInterests.where((i) => i.parentId == null || i.parentId == 0)) i.id.toString(): i.translationKey};
    final languageOptionsAsync = ref.watch(languageOptionsProvider);
    final genderOptionsAsync = ref.watch(genderOptionsProvider);

    return Scaffold(
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton.extended(
          heroTag: 'profile_edit_fab',
          onPressed: () {
            final currentUser = supabase.auth.currentUser;
            if (currentUser == null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t(l10n, 'generalError', fallbackProvided: 'Error'))));
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ProfileWizardScreen(user: currentUser, isEditing: true),
              ),
            );
          },
          tooltip: _t(l10n, 'generalEdit', fallbackProvided: 'Edit'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(Icons.edit_outlined),
          label: Text(_t(l10n, 'generalEdit', fallbackProvided: 'Edit')),
        ),
      ),
      body: Builder(
        builder: (context) => profileAsyncValue.when(
          data: (profile) {
            if (profile == null) {
              return Center(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(l10n.getString('generalErrorLoadingProfile')),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => ref.read(profileSyncProvider).syncProfile(userId),
                    child: Text(_t(l10n, 'generalRetry', fallbackProvided: 'Retry')),
                  ),
                ]),
              );
            }

            return RefreshIndicator(
              onRefresh: () async => ref.read(profileSyncProvider).syncProfile(userId),
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  // Photos: show thumbnails in order. If none, show placeholder.
                  if (profile.photos.isNotEmpty)
                    SizedBox(
                      height: 140,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: profile.photos.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (ctx, i) {
                          final source = profile.photos[i];
                          return GestureDetector(
                            onTap: () => _openPhotoPreview(context, source, l10n),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SignedImage(
                                    source: source,
                                    width: 140,
                                    height: 140,
                                    fit: BoxFit.cover,
                                    placeholder: Container(
                                      width: 140,
                                      height: 140,
                                      color: Colors.grey.shade100,
                                    ),
                                    errorWidget: Container(
                                      width: 140,
                                      height: 140,
                                      color: Colors.grey.shade200,
                                      child: const Icon(
                                        Icons.broken_image,
                                        size: 36,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ),
                                if (i == 0)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      color: Colors.black54,
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Text(
                                        l10n.getString('profileWizardPrimaryPhotoBadge'),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    )
                  else
                    SizedBox(
                      height: 140,
                      child: Center(child: Text(_t(l10n, 'profileNoPhotos', fallbackProvided: 'No photos'))),
                    ),
                  
                  const SizedBox(height: 16),

                  // Name
                  (() {
                    final displayName = profile.name.trim();
                    return _buildProfileItem(
                      context,
                      Icons.person_outline_rounded,
                      _t(l10n, 'profileName', fallbackProvided: 'Name'),
                      displayName,
                      textDirection: RegExp(r'[a-zA-Z]').hasMatch(displayName) ? ui.TextDirection.ltr : (displayName.isRtl() ? ui.TextDirection.rtl : ui.TextDirection.ltr),
                      trailing: profile.isVerified ? const VerifiedBadge(size: 20, showText: true) : null,
                    );
                  })(),
                  (() {
                    final displayName = profile.name.trim();
                    final parts = displayName.split(RegExp(r'\s+')).where((p) => p.trim().isNotEmpty).toList(growable: false);
                    final hasLastName = parts.length >= 2;
                    if (!hasLastName) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(start: 16, end: 16, top: 2, bottom: 12),
                      child: Text(
                        _t(
                          l10n,
                          'profileLastNameNotDisplayed',
                          fallbackProvided: 'Your last name is never shown to other users.',
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
                      ),
                    );
                  })(),

                  // Birthday
                  _buildProfileItem(
                    context,
                    Icons.cake_outlined,
                    _t(l10n, 'profileBirthday', fallbackProvided: 'Birthday'),
                    profile.dateOfBirth != null ? _formatDateWithL10n(profile.dateOfBirth!, l10n) : _t(l10n, 'profileNotSet', fallbackProvided: 'Not set'),
                  ),

                  // Age (displayed separately like in profile wizard)
                  if (profile.dateOfBirth != null) ...[
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 12.0 + 56.0 + 8.0, top: 8.0),
                      child: Align(
                        alignment: _isRtl(l10n) ? Alignment.centerRight : Alignment.centerLeft,
                        child: Text(
                          '${_ageLabelFor(l10n)}: ${_calculateAge(profile.dateOfBirth!)}',
                          style: TextStyle(color: Colors.green.shade700),
                        ),
                      ),
                    ),
                  ],

                  // Gender
                  genderOptionsAsync.when(
                    data: (options) {
                      final genderKey = profile.gender ?? '';
                      String genderDisplay;
                      try {
                        final Map<String, String> found = options.firstWhere(
                          (o) => (o['key'] ?? '').trim().toLowerCase() == genderKey.trim().toLowerCase(),
                          orElse: () => <String, String>{},
                        );
                        
                        if (found.isNotEmpty) {
                          final displayKey = found['displayKey'] ?? '';
                          final translated = l10n.getString(displayKey);
                          
                          if (translated.endsWith('...')) {
                            genderDisplay = _humanizeKey(genderKey);
                          } else {
                            genderDisplay = translated;
                          }
                        } else {
                          if (genderKey.trim().isEmpty) {
                            genderDisplay = _t(l10n, 'profileNotSet', fallbackProvided: 'Not set');
                          } else {
                            genderDisplay = _humanizeKey(genderKey);
                          }
                        }
                      } catch (e) {
                        if (genderKey.trim().isEmpty) {
                          genderDisplay = _t(l10n, 'profileNotSet', fallbackProvided: 'Not set');
                        } else {
                          genderDisplay = _humanizeKey(genderKey);
                        }
                      }
                      return _buildProfileItem(context, Icons.wc_outlined, _t(l10n, 'profileGender', fallbackProvided: 'Gender'), genderDisplay);
                    },
                    loading: () => _buildProfileItem(context, Icons.wc_outlined, _t(l10n, 'profileGender', fallbackProvided: 'Gender'), _t(l10n, 'generalLoading', fallbackProvided: 'Loading...')),
                    error: (e, s) => _buildProfileItem(context, Icons.wc_outlined, _t(l10n, 'profileGender', fallbackProvided: 'Gender'), _t(l10n, 'generalError', fallbackProvided: 'Error')),
                  ),

                  // Bio display (if present)
                  if ((profile.bio ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(_t(l10n, 'profileAbout', fallbackProvided: 'About'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Text(
                          profile.bio ?? '',
                          textDirection: RegExp(r'[a-zA-Z]').hasMatch(profile.bio ?? '') ? ui.TextDirection.ltr : ui.TextDirection.rtl,
                          textAlign: (profile.bio ?? '').isRtl() ? TextAlign.right : TextAlign.left,
                        ),
                      ),
                    ),
                  ],

                  const Divider(height: 30),

                  // Intents
                  Text(_t(l10n, 'profileEditIntentsTitle'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  if (profile.activeModes.isEmpty)
                    Padding(padding: const EdgeInsets.only(left: 8.0), child: Text(_t(l10n, 'profileNoIntents'), style: const TextStyle(color: Colors.grey))),

                  allIntentsAsync.when(
                    data: (allIntents) {
                      final Map<String, String> mainIntentNormalizedLookup = {};
                      for (var opt in mainIntents) {
                        mainIntentNormalizedLookup[_normalizeKey(opt.key)] = opt.translationKey;
                      }

                      final validMainModes = profile.activeModes.where((modeKey) {
                        final nm = _normalizeKey(modeKey);
                        return modeKey != '0' && modeKey.isNotEmpty && mainIntentNormalizedLookup.containsKey(nm);
                      }).toList();

                      final intentOrder = ['romantic', 'friendship', 'activity_partner', 'business_networking'];
                      final sortedValidModes = validMainModes..sort((a, b) {
                        final aNorm = _normalizeKey(a);
                        final bNorm = _normalizeKey(b);
                        final aIndex = intentOrder.indexOf(aNorm);
                        final bIndex = intentOrder.indexOf(bNorm);
                        if (aIndex == -1) return 1;
                        if (bIndex == -1) return -1;
                        return aIndex.compareTo(bIndex);
                      });

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: sortedValidModes.map((modeKey) {
                          final norm = _normalizeKey(modeKey);
                          final displayKey = mainIntentNormalizedLookup[norm] ?? modeKey;
                          final chipLabel = _resolveDisplayLabel(l10n, displayKey, fallbackProvided: _humanizeKey(displayKey));

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Chip(label: Text(chipLabel), backgroundColor: Theme.of(context).colorScheme.primaryContainer),
                              if (profile.subIntents[modeKey]?.isNotEmpty ?? false)
                                Padding(
                                  padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                                  child: Wrap(
                                    spacing: 6.0,
                                    runSpacing: 0.0,
                                    children: profile.subIntents[modeKey]!.where((subKey) => subKey != '0' && subKey.isNotEmpty).map((subKey) {
                                      final subDisplayKey = subKey.contains('::') ? subKey.split('::').last : subKey;
                                      final subLabel = _tryGetString(l10n, subKey) ?? _humanizeKey(subDisplayKey);
                                      return Chip(
                                        label: Text(subLabel, style: const TextStyle(fontSize: 12)),
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        backgroundColor: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha:0.5),
                                      );
                                    }).toList(),
                                  ),
                                ),
                            ]), // end column
                          );
                        }).toList(),
                      );
                    },
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, s) => Text(_t(l10n, 'generalError', fallbackProvided: 'Error'), style: const TextStyle(color: Colors.red)),
                  ),

                  const Divider(height: 30),

                  // Interests
                  Text(_t(l10n, 'profileInterests', fallbackProvided: 'Interests'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  if (profile.interests.isEmpty)
                    Padding(padding: const EdgeInsets.only(left: 8.0), child: Text(_t(l10n, 'profileNoInterests', fallbackProvided: 'No interests selected'), style: const TextStyle(color: Colors.grey))),

                  // Display interests separated by intent type (personal vs business/networking)
                  (() {
                    final Set<String> allUniqueInterestKeys = {};
                    final Map<String, Set<String>> interestToIntents = {};
                    final Map<String, Set<String>> businessInterests = {};
                    final Map<String, Set<String>> personalInterests = {};

                    // Parse the prefixed keys to collect all unique interests and their associated intents
                    profile.interests.forEach((prefixedKey, interestKeys) {
                      if (prefixedKey.contains('::')) {
                        final parts = prefixedKey.split('::');
                        if (parts.length >= 2) {
                          final intentKey = parts[0];
                          final isBusinessNetworking = _normalizeKey(intentKey) == 'business_networking';
                          
                          for (final interestKey in interestKeys.where((key) => key != '0' && key.isNotEmpty)) {
                            allUniqueInterestKeys.add(interestKey);
                            if (!interestToIntents.containsKey(interestKey)) {
                              interestToIntents[interestKey] = {};
                            }
                            interestToIntents[interestKey]!.add(intentKey);
                            
                            // Categorize interests by intent type
                            if (isBusinessNetworking) {
                              if (!businessInterests.containsKey(interestKey)) {
                                businessInterests[interestKey] = {};
                              }
                              businessInterests[interestKey]!.add(intentKey);
                            } else {
                              if (!personalInterests.containsKey(interestKey)) {
                                personalInterests[interestKey] = {};
                              }
                              personalInterests[interestKey]!.add(intentKey);
                            }
                          }
                        }
                      }
                    });

                    // Get all unique interests with their display information
                    final uniqueInterests = relevantInterests
                        .where((interest) => allUniqueInterestKeys.contains(interest.key))
                        .toList();

                    // Helper function to create interest widgets for a category
                    Widget createInterestSection(String title, IconData icon, Map<String, Set<String>> interestCategory, Color? chipColor) {
                      if (interestCategory.isEmpty) {
                        return const SizedBox.shrink();
                      }

                      final categoryInterestKeys = interestCategory.keys.toSet();
                      final categoryInterests = uniqueInterests
                          .where((interest) => categoryInterestKeys.contains(interest.key))
                          .toList();

                      // Sort interests alphabetically for consistent display
                      categoryInterests.sort((a, b) {
                        final aInterestKey = a.key.contains('::') ? a.key.split('::').last : a.key;
                        final aDisplayName = _resolveDisplayLabel(
                          l10n,
                          aInterestKey,
                          interestKeyToDisplayKey: interestDisplayMap,
                          categoryKeyToDisplayKey: categoryDisplayMap,
                          fallbackProvided: _humanizeKey(aInterestKey),
                        ).toLowerCase();

                        final bInterestKey = b.key.contains('::') ? b.key.split('::').last : b.key;
                        final bDisplayName = _resolveDisplayLabel(
                          l10n,
                          bInterestKey,
                          interestKeyToDisplayKey: interestDisplayMap,
                          categoryKeyToDisplayKey: categoryDisplayMap,
                          fallbackProvided: _humanizeKey(bInterestKey),
                        ).toLowerCase();

                        return aDisplayName.compareTo(bDisplayName);
                      });

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 8),
                                Text(
                                  title,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: Wrap(
                                spacing: 6.0,
                                runSpacing: 4.0,
                                children: categoryInterests.map((interest) {
                                  final interestKey = interest.key.contains('::') ? interest.key.split('::').last : interest.key;
                                  final displayName = _resolveDisplayLabel(
                                    l10n,
                                    interestKey,
                                    interestKeyToDisplayKey: interestDisplayMap,
                                    categoryKeyToDisplayKey: categoryDisplayMap,
                                    fallbackProvided: _humanizeKey(interestKey),
                                  );
                                  
                                  // Optional: Show which intents this interest relates to in the tooltip
                                  final relatedIntents = interestCategory[interest.key] ?? {};
                                  String? tooltip;
                                  if (relatedIntents.isNotEmpty && relatedIntents.length > 1) {
                                    final intentNames = relatedIntents.map((intentKey) {
                                      return _resolveDisplayLabel(
                                        l10n,
                                        intentKey,
                                        allIntentsMap: {for (var intent in allIntents) intent.key: intent.translationKey},
                                        fallbackProvided: _humanizeKey(intentKey),
                                      );
                                    }).join(', ');
                                    tooltip = 'Related to: $intentNames';
                                  }
                                  
                                  return Tooltip(
                                    message: tooltip ?? '',
                                    child: Chip(
                                      label: Text(displayName, style: const TextStyle(fontSize: 12)),
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      backgroundColor: chipColor ?? Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha:0.5),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    // Create sections for personal and business interests
                    final List<Widget> sections = [];
                    
                    // Personal interests section (romantic, friendship, activity partner)
                    sections.add(createInterestSection(
                      _t(l10n, 'profilePersonalInterests', fallbackProvided: 'Personal Interests'),
                      Icons.favorite_outline,
                      personalInterests,
                      Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha:0.5),
                    ));

                    // Business/Networking interests section
                    sections.add(createInterestSection(
                      _t(l10n, 'profileBusinessInterests', fallbackProvided: 'Business & Networking'),
                      Icons.business_center_outlined,
                      businessInterests,
                      Theme.of(context).colorScheme.secondaryContainer.withValues(alpha:0.5),
                    ));

                    // If no interests at all, show the original empty state
                    if (personalInterests.isEmpty && businessInterests.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Text(
                          _t(l10n, 'profileNoInterests', fallbackProvided: 'No interests selected'),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: sections,
                    );
                  })(),

                  const Divider(height: 30),

                  // Languages Known
                  Text(_t(l10n, 'profileLanguagesKnown', fallbackProvided: 'Languages Known'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  languageOptionsAsync.when(
                    data: (allLanguages) {
                      final Map<String, String> allLangsMap = {
                        for (var v in allLanguages) v['code']!: _t(l10n, 'lang_${v['code']}', fallbackProvided: v['display'] ?? v['code']!)
                      };
                      if (profile.languagesKnown.isEmpty) {
                        return Padding(padding: const EdgeInsets.only(left: 8.0), child: Text(_t(l10n, 'profileNotSet', fallbackProvided: 'Not set'), style: const TextStyle(color: Colors.grey)));
                      }
                      final filteredEntries = <MapEntry<String, List<String>>>[];
                      final langs = profile.languagesKnown['languages'] ?? [];
                      for (final lang in langs) {
                        if (lang == 'languages') continue;
                        final skills = profile.languagesKnown[lang] ?? [];
                        filteredEntries.add(MapEntry(lang, skills));
                      }
                      if (filteredEntries.isEmpty) {
                        return Padding(padding: const EdgeInsets.only(left: 8.0), child: Text(_t(l10n, 'profileNotSet', fallbackProvided: 'Not set'), style: const TextStyle(color: Colors.grey)));
                      }
                      return Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: filteredEntries.map((entry) {
                            final langCode = entry.key;
                            final langName = allLangsMap[langCode] ?? _t(l10n, 'lang_$langCode', fallbackProvided: langCode);
                            final skills = entry.value;
                            // Format skills with capitalization
                            final skillsText = skills.map((skillKey) {
                              final skillName = _t(l10n, skillKey, fallbackProvided: skillKey);
                              return skillName;
                            }).join(', ');
                            
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6.0),
                              child: RichText(
                                text: TextSpan(
                                  style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface),
                                  children: [
                                    TextSpan(
                                      text: '$langName: ',
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    TextSpan(text: skillsText),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      );
                    },
                    loading: () => const CircularProgressIndicator(),
                    error: (e, s) => Text(_t(l10n, 'generalError', fallbackProvided: 'Error'), style: const TextStyle(color: Colors.red)),
                  ),

                  ratingSummaryAsync.when(
                    data: (summary) {
                      if (summary.overallAvg == null) {
                        return const SizedBox.shrink();
                      }
                      return ratingQuestionsAsync.when(
                        data: (questions) {
                          final firstFive = questions.take(5).toList();
                          final questionAverages = <double?>[
                            summary.q1Avg,
                            summary.q2Avg,
                            summary.q3Avg,
                            summary.q4Avg,
                            summary.q5Avg,
                          ];

                          Future<void> showQuestion(String headerKey, String questionKey) async {
                            final header = l10n.getString(headerKey);
                            final question = l10n.getString(questionKey);
                            await showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(header),
                                content: Text(question),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    child: Text(l10n.getString('generalCancel')),
                                  ),
                                ],
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Divider(height: 30),
                              Text(
                                l10n.getString('ratingSectionTitle'),
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              Card(
                                elevation: 2,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      for (var i = 0; i < firstFive.length && i < questionAverages.length; i++)
                                        if (questionAverages[i] != null)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 10.0),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Flexible(
                                                        child: Text(
                                                          l10n.getString(_headerKeyForQuestion(firstFive[i])),
                                                          style: Theme.of(context).textTheme.bodyMedium,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                      IconButton(
                                                        visualDensity: VisualDensity.compact,
                                                        padding: EdgeInsets.zero,
                                                        icon: const Icon(Icons.info_outline, size: 18),
                                                        onPressed: () => showQuestion(
                                                          _headerKeyForQuestion(firstFive[i]),
                                                          firstFive[i].translationKey,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Text(
                                                  _formatScore(questionAverages[i]!, decimals: 1),
                                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                                ),
                                              ],
                                            ),
                                          ),
                                      const Divider(height: 18),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              l10n.getString('ratingOverall'),
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                          Text(
                                            _formatScore(summary.overallAvg!, decimals: 2),
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                        loading: () => const SizedBox.shrink(),
                        error: (e, s) => const SizedBox.shrink(),
                      );
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (e, s) => const SizedBox.shrink(),
                  ),

                  const SizedBox(height: 60),
                ],
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, stack) => Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('${l10n.getString('generalErrorLoadingProfile')}: $err', textAlign: TextAlign.center),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => ref.read(profileSyncProvider).syncProfile(userId),
                  child: Text(_t(l10n, 'generalRetry', fallbackProvided: 'Retry')),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileItem(BuildContext context, IconData icon, String label, String value, {ui.TextDirection? textDirection, Widget? trailing}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: colors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface.withValues(alpha: 0.7),
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing,
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  textDirection: textDirection,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: colors.onSurface,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatScore(double value, {int decimals = 1}) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _headerKeyForQuestion(RatingQuestion q) {
    switch (q.id) {
      case 'communication':
        return 'ratingHeaderCommunication';
      case 'reliability':
        return 'ratingHeaderReliability';
      case 'respect':
        return 'ratingHeaderRespect';
      case 'safety':
        return 'ratingHeaderSafety';
      case 'profile_accuracy':
        return 'ratingHeaderAccuracy';
      default:
        return q.translationKey;
    }
  }

  String _t(LocalizationState l10n, String key, {String? fallbackProvided}) => _resolveDisplayLabel(l10n, key, fallbackProvided: fallbackProvided);
}
