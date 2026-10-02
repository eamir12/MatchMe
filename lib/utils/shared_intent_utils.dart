import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';

List<String> getSharedIntentKeys({
  required UserProfile? currentProfile,
  required UserProfile? otherProfile,
}) {
  if (currentProfile == null || otherProfile == null) return const <String>[];

  final shared = <String>[];
  final currentModes = currentProfile.activeModes
      .map((mode) => mode.trim().toLowerCase())
      .where((mode) => mode.isNotEmpty)
      .toSet();
  final otherModes = otherProfile.activeModes
      .map((mode) => mode.trim().toLowerCase())
      .where((mode) => mode.isNotEmpty)
      .toSet();

  for (final intentKey in currentModes.intersection(otherModes)) {
    shared.add(intentKey);
  }

  return shared;
}

/// Parses the `matched_intent` column stored on a match row into the
/// individual intent keys that created that match. The DB stores a single
/// intent most of the time but may store a comma-separated list.
List<String> getIntentKeysFromMatchedIntent(String? matchedIntent) {
  if (matchedIntent == null || matchedIntent.trim().isEmpty) {
    return const <String>[];
  }
  final raw = matchedIntent.trim().toLowerCase();
  // Guard against placeholder / error sentinels that should never surface
  // as a filter chip.
  if (raw == 'unknown' || raw == 'error' || raw == 'null') {
    return const <String>[];
  }
  final keys = <String>{};
  for (final part in matchedIntent.split(',')) {
    final k = part.trim().toLowerCase();
    if (k.isEmpty || k == 'unknown' || k == 'error' || k == 'null') continue;
    keys.add(k);
  }
  return keys.toList();
}

List<String> getOrderedSharedIntentKeys(Iterable<String> intentKeys) {
  final distinct = intentKeys
      .map((key) => key.trim().toLowerCase())
      .where((key) => key.isNotEmpty)
      .toSet()
      .toList();

  final priority = <String, int>{
    'romantic': 0,
    'friendship': 1,
    'activity_partner': 2,
    'business_networking': 3,
  };

  distinct.sort((a, b) {
    final priorityA = priority[a.toLowerCase()] ?? 999;
    final priorityB = priority[b.toLowerCase()] ?? 999;
    if (priorityA != priorityB) {
      return priorityA.compareTo(priorityB);
    }
    return a.compareTo(b);
  });

  return distinct;
}

class IntentFilterOption {
  final String key;
  final String label;
  final IconData icon;
  final Color color;

  const IntentFilterOption({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
  });
}

IntentFilterOption getIntentFilterOption(
  String intentKey,
  LocalizationState l10n,
  List<AppIntent> allIntents,
) {
  final normalizedKey = intentKey.trim().toLowerCase();
  final matchingIntent = allIntents.firstWhere(
    (intent) => intent.key.trim().toLowerCase() == normalizedKey,
    orElse: () =>
        AppIntent(id: 0, key: normalizedKey, translationKey: '', sortOrder: 0),
  );

  final translationKey = matchingIntent.translationKey;
  final translatedLabel = translationKey.isNotEmpty
      ? l10n.getString(translationKey)
      : '';
  final directLabel = l10n.getString('intent.$normalizedKey');
  final label =
      (translatedLabel.isNotEmpty && translatedLabel != translationKey)
      ? translatedLabel
      : (directLabel.isNotEmpty && directLabel != 'intent.$normalizedKey'
            ? directLabel
            : intentKey.replaceAll('_', ' '));

  final icon = switch (normalizedKey) {
    'romantic' => Icons.favorite_rounded,
    'friendship' => Icons.people_alt_rounded,
    'activity_partner' => Icons.sports_tennis_rounded,
    'business_networking' => Icons.business_center_rounded,
    _ => Icons.explore_rounded,
  };

  final color = switch (normalizedKey) {
    'romantic' => const Color(0xFFEF476F),
    'friendship' => const Color(0xFF06D6A0),
    'activity_partner' => const Color(0xFF118AB2),
    'business_networking' => const Color(0xFF7B61FF),
    _ => ThemeData().colorScheme.primary,
  };

  return IntentFilterOption(
    key: normalizedKey,
    label: label,
    icon: icon,
    color: color,
  );
}
