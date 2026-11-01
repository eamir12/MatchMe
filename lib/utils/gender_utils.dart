import 'package:matchme/providers/locale_provider.dart';

/// Canonical comparison key for a gender value.
///
/// Profiles and the `app_gender_options` reference table use the same storage
/// shape ("male", "female", "non_binary"), but older rows and imports can carry
/// a `gender_` prefix or "nonbinary". Normalizing both sides keeps the filter
/// from silently matching nothing.
String normalizeGenderKey(String? raw) {
  var value = (raw ?? '').trim().toLowerCase().replaceAll('-', '_');
  if (value.startsWith('gender_')) value = value.substring(7);
  if (value == 'nonbinary' || value == 'non binary') value = 'non_binary';
  return value;
}

/// Localized label for a gender option row ({key, displayKey}).
String genderOptionLabel(LocalizationState l10n, Map<String, String> option) {
  final displayKey = (option['displayKey'] ?? '').trim();
  final displayLabel = _translatedLabel(l10n, displayKey);
  if (displayLabel != null) return displayLabel;
  final key = (option['key'] ?? '').trim();
  final keyLabel = _translatedLabel(l10n, key);
  if (keyLabel != null) return keyLabel;
  return _prettyGenderKey(key.isEmpty ? displayKey : key);
}

String? _translatedLabel(LocalizationState l10n, String raw) {
  for (final candidate in _translationCandidates(raw)) {
    final translated = l10n.getString(candidate);
    // A missing key renders as "[key]" (no-truncation policy in getString).
    if (translated.isNotEmpty &&
        translated != candidate &&
        translated != '[$candidate]') {
      return translated;
    }
  }
  return null;
}

Iterable<String> _translationCandidates(String raw) sync* {
  final value = raw.trim();
  if (value.isEmpty) return;
  yield value;
  final lower = value.toLowerCase();
  yield lower.startsWith('gender_') ? lower : 'gender_$lower';
}

String _prettyGenderKey(String raw) {
  return raw
      .replaceAll('_', ' ')
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
}
