// lib/utils/string_extensions.dart

extension StringExtension on String {
  /// Capitalizes the first letter of the string and lowercases the rest.
  String capitalize() {
    if (isEmpty) {
      return "";
    }
    return "${this[0].toUpperCase()}${substring(1).toLowerCase()}";
  }

  /// Detects if a string contains Right-to-Left characters (e.g., Hebrew, Arabic)
  /// Returns true if the string contains any RTL characters, regardless of other characters
  bool isRtl() {
    if (isEmpty) return false;
    final rtlRegex = RegExp(r'[\u0590-\u05FF\u0600-\u06FF]');
    return rtlRegex.hasMatch(this);
  }

  /// Formats a full name as "First LastInitial." (e.g., "John Doe" -> "John D.")
  String formatAsFirstNameLastInitial() {
    final parts = trim().split(' ');
    if (parts.isEmpty) return this;
    final first = parts[0];
    String lastInitial = '';
    if (parts.length > 1 && parts[1].isNotEmpty) {
      lastInitial = ' ${parts[1][0].toUpperCase()}.';
    }
    return '\u200E$first$lastInitial\u200E';
  }
}
