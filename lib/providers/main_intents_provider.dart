import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'new_options_provider.dart';

/// Returns all interests matching any of the selected intents' is_social/is_business flags.
final interestsForSelectedIntentsProvider = Provider.family<List<AppInterest>, List<AppIntent>>((ref, selectedIntents) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  if (selectedIntents.isEmpty) return [];

  // Determine if any selected intent is social or business
  final bool wantsSocial = selectedIntents.any((intent) => intent.isSocial == true);
  final bool wantsBusiness = selectedIntents.any((intent) => intent.isBusiness == true);

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
  return allIntents.where((intent) => intent.parentId == null && !intent.key.contains('::')).toList();
});

/// Provides sub-intents for a given main intent key.
final subIntentsProvider = Provider.family<List<AppIntent>, int>((ref, parentIntentId) {
  final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];
  return allIntents.where((intent) => intent.parentId == parentIntentId).toList();
});

/// Provides all interest children for a given parent interest id.
final interestChildrenProvider = Provider.family<List<AppInterest>, int>((ref, parentId) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests.where((interest) => interest.parentId == parentId).toList();
});

/// Provides top-level interest categories for a given intent id (business intent).
final mainInterestsProvider = Provider<List<AppInterest>>((ref) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  // Main interests: no parentId
  return allInterests.where((interest) => interest.parentId == null).toList();
});

final childInterestsProvider = Provider.family<List<AppInterest>, int>((ref, parentInterestId) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests.where((interest) => interest.parentId == parentInterestId).toList();
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
final interestCategoriesByGroupProvider = Provider.family<List<AppInterest>, String>((ref, group) {
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return allInterests.where((interest) =>
    (interest.parentId == null || interest.parentId == 0) &&
    false // metadata removed
  ).toList();
});

/// Provides language options (stub, replace with your actual implementation).
final languageOptionsProvider = FutureProvider<List<Map<String, String>>>((ref) async {
  // Replace with actual fetch logic
  return [
    {'code': 'en', 'display': 'English'},
    {'code': 'es', 'display': 'Español'},
    {'code': 'he', 'display': 'עברית'},
  ];
});
