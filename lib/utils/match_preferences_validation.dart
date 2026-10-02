List<String> invalidGenderPreferenceKeys({
  required Iterable<String> activeIntentKeys,
  required Map<String, List<String>> genderPreferences,
}) {
  return activeIntentKeys
      .where((key) {
        final values = genderPreferences[key];
        return values == null ||
            values.isEmpty ||
            values.every((value) => value.trim().isEmpty);
      })
      .toList(growable: false);
}
