// lib/services/deepl_usage_service.dart
import 'package:shared_preferences/shared_preferences.dart';

class DeepLUsageService {
  static const String _usageKey = 'deepl_usage_chars';
  static const String _resetDateKey = 'deepl_usage_reset_date';
  static const int _monthlyLimit = 500000; // Free tier limit

  Future<int> getCurrentUsage() async {
    final prefs = await SharedPreferences.getInstance();
    final resetDate = prefs.getString(_resetDateKey);
    final now = DateTime.now();

    // Check if we need to reset the counter (monthly)
    if (resetDate != null) {
      final resetDateTime = DateTime.parse(resetDate);
      final daysSinceReset = now.difference(resetDateTime).inDays;

      if (daysSinceReset >= 30) {
        // Reset usage counter
        await prefs.setInt(_usageKey, 0);
        await prefs.setString(_resetDateKey, now.toIso8601String());
        return 0;
      }
    } else {
      // First time using, set reset date
      await prefs.setString(_resetDateKey, now.toIso8601String());
      return 0;
    }

    return prefs.getInt(_usageKey) ?? 0;
  }

  Future<bool> canTranslate(String text) async {
    final currentUsage = await getCurrentUsage();
    final textLength = text.length;

    return (currentUsage + textLength) <= _monthlyLimit;
  }

  Future<void> recordUsage(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final currentUsage = await getCurrentUsage();
    final newUsage = currentUsage + text.length;

    await prefs.setInt(_usageKey, newUsage);
  }

  Future<double> getUsagePercentage() async {
    final currentUsage = await getCurrentUsage();
    return (currentUsage / _monthlyLimit) * 100;
  }

  Future<String> getUsageInfo() async {
    final currentUsage = await getCurrentUsage();
    final percentage = await getUsagePercentage();

    return '${currentUsage.toStringAsFixed(0)} / ${_monthlyLimit.toStringAsFixed(0)} characters (${percentage.toStringAsFixed(1)}%)';
  }

  Future<bool> isNearLimit() async {
    final percentage = await getUsagePercentage();
    return percentage > 80; // Warn when over 80% of limit
  }

  Future<DateTime?> getNextResetDate() async {
    final prefs = await SharedPreferences.getInstance();
    final resetDate = prefs.getString(_resetDateKey);

    if (resetDate != null) {
      final resetDateTime = DateTime.parse(resetDate);
      return resetDateTime.add(const Duration(days: 30));
    }

    return null;
  }
}
