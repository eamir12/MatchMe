bool matchesSettingsSearch({
  required String query,
  required String label,
  required String description,
  String? group,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;
  final haystack = group == null
      ? '$label $description'
      : '$group $label $description';
  return haystack.toLowerCase().contains(normalizedQuery);
}
