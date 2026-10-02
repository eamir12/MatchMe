bool matchesSettingsSearch({
  required String query,
  required String label,
  required String description,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;
  return '$label $description'.toLowerCase().contains(normalizedQuery);
}
