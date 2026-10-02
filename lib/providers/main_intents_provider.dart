import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/translation_cache_manager.dart';
import 'new_options_provider.dart';

/// Returns all interests matching any of the selected intents' is_social/is_business flags.
final interestsForSelectedIntentsProvider =
    Provider.family<List<AppInterest>, List<AppIntent>>((ref, selectedIntents) {
      final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
      if (selectedIntents.isEmpty) return [];

      // Determine if any selected intent is social or business
      final bool wantsSocial = selectedIntents.any(
        (intent) => intent.isSocial == true,
      );
      final bool wantsBusiness = selectedIntents.any(
        (intent) => intent.isBusiness == true,
      );

      return allInterests.where((interest) {
        if (wantsSocial && wantsBusiness) {
          return interest.isSocial == true || interest.isBusiness == true;
        } else if (wantsSocial) {
          return interest.isSocial == true;
        } else if (wantsBusiness) {
          return interest.isBusiness == true;
        }
        return false;
      }).toList();
    });

/// Provides only the main (top-level) intents, not sub-intents.
final mainIntentsProvider = Provider<List<AppIntent>>((ref) {
  final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];
  // Main intents: no parentId and key does not contain '::'
  return allIntents
      .where((intent) => intent.parentId == null && !intent.key.contains('::'))
      .toList();
});

/// Provides sub-intents for a given main intent key.
final subIntentsProvider = Provider.family<List<AppIntent>, int>((
  ref,
  parentIntentId,
) {
  final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];
  return allIntents
      .where((intent) => intent.parentId == parentIntentId)
      .toList();
});

/// Provides all interest children for a given parent interest id.
final interestChildrenProvider = Provider.family<List<AppInterest>, int>((
  ref,
  parentId,
) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests
      .where((interest) => interest.parentId == parentId)
      .toList();
});

/// Provides top-level interest categories for a given intent id (business intent).
final mainInterestsProvider = Provider<List<AppInterest>>((ref) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  // Main interests: no parentId
  return allInterests.where((interest) => interest.parentId == null).toList();
});

final childInterestsProvider = Provider.family<List<AppInterest>, int>((
  ref,
  parentInterestId,
) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests
      .where((interest) => interest.parentId == parentInterestId)
      .toList();
});

final socialInterestsProvider = Provider<List<AppInterest>>((ref) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests.where((interest) => interest.isSocial).toList();
});

final businessInterestsProvider = Provider<List<AppInterest>>((ref) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests.where((interest) => interest.isBusiness).toList();
});

/// Provides top-level interest categories for a given group (social intent).
final interestCategoriesByGroupProvider =
    Provider.family<List<AppInterest>, String>((ref, group) {
      final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
      return allInterests
          .where(
            (interest) =>
                (interest.parentId == null || interest.parentId == 0) &&
                false, // metadata removed
          )
          .toList();
    });

/// Provides list of cached language codes (languages with downloaded translations)
final cachedLanguagesProvider = FutureProvider<List<String>>((ref) async {
  return await TranslationCacheManager.getCachedLanguages();
});

/// Provides language options with their cache and availability status.
/// Each language is only selectable if:
/// - It's already cached (user selected it before), OR
/// - Device is online (can download it now)
///
/// Each map contains: 'code', 'display', 'cached' (bool), 'availableOffline' (bool), 'offline' (bool)
final languageOptionsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final l10n = ref.watch(localizationProvider);
  final isOnline = ref.watch(connectivityProvider).value ?? true;
  final isOffline = !isOnline;

  final result = <Map<String, dynamic>>[];
  for (final language in l10n.supportedLanguages) {
    final code = language.code;
    final isCached = await TranslationCacheManager.isLanguageCached(code);

    result.add(<String, dynamic>{
      'code': code,
      'display': language.displayName,
      'cached': isCached,
      'availableOffline': code == 'en' || isCached,
      'offline': isOffline,
    });
  }
  return result;
});
