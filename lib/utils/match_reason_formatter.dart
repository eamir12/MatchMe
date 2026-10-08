// lib/utils/match_reason_formatter.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Helper class to format match reasons with Supabase translations and fallbacks
class MatchReasonFormatter {
  /// Format match reasons for display in Recent Matches
  ///
  /// This function formats match reasons in the required format:
  /// Event: Woodstock 99
  /// Intent: Romantic, Friendship
  ///
  /// For proximity matches, it shows:
  /// Intent: Romantic, Friendship
  ///
  /// All user-facing texts come from Supabase with fallbacks in the code.
  static String formatMatchReasons(
    WidgetRef ref,
    dynamic matchedIntent,
    String matchType, {
    String? eventName,
  }) {
    final l10n = ref.watch(localizationProvider);

    // Parse matchedIntent (can be List<String>, List, or comma-separated string)
    List<String> reasons;
    if (matchedIntent is List<String>) {
      reasons = matchedIntent;
    } else if (matchedIntent is List) {
      final result = <String>[];
      for (final e in matchedIntent) {
        result.add(e.toString());
      }
      reasons = result;
    } else {
      final str = matchedIntent.toString();
      reasons = str.contains(',')
          ? str.split(',').map((e) => e.trim()).toList()
          : [str];
    }

    // Format intent reasons: replace underscores, capitalize, filter nulls
    final formattedIntents = <String>[];
    for (final r in reasons) {
      if (r.trim().isNotEmpty) {
        final formatted = _formatIntentReason(l10n, r);
        if (formatted.isNotEmpty) {
          formattedIntents.add(formatted);
        }
      }
    }

    final List<String> lines = [];

    // Add event line if this is an event match
    if (matchType == 'event' && eventName != null && eventName.isNotEmpty) {
      final eventLabel = _getTranslationWithFallback(l10n, 'eventLabel');
      lines.add('$eventLabel: $eventName');
    }

    // Add intent line if there are intents
    if (formattedIntents.isNotEmpty) {
      final intentText = formattedIntents.join(', ');
      if (intentText.trim().isNotEmpty) {
        final intentLabel = _getTranslationWithFallback(l10n, 'intentLabel');
        lines.add('$intentLabel: $intentText');
      }
    }

    // Join lines with newlines
    return lines.join('\n');
  }

  /// Format match reasons as a sentence for display in Matches screen
  ///
  /// Formats as:
  /// - Event-based: "You matched because of a shared event, intent(s) and interest(s)."
  /// - Proximity-based: "You matched because of proximity, and shared intent(s) and interest(s)."
  ///
  /// All user-facing texts come from Supabase with fallbacks.
  static String formatMatchReasonSentence(
    WidgetRef ref,
    dynamic matchedIntent,
    String matchType, {
    String? eventName,
  }) {
    final l10n = ref.watch(localizationProvider);

    // Parse matchedIntent (can be List<String>, List, or comma-separated string)
    List<String> reasons;
    if (matchedIntent is List<String>) {
      reasons = matchedIntent;
    } else if (matchedIntent is List) {
      final result = <String>[];
      for (final e in matchedIntent) {
        result.add(e.toString());
      }
      reasons = result;
    } else {
      final str = matchedIntent.toString();
      reasons = str.contains(',')
          ? str.split(',').map((e) => e.trim()).toList()
          : [str];
    }

    // Format intent reasons: replace underscores, capitalize, filter nulls
    final formattedIntents = <String>[];
    for (final r in reasons) {
      if (r.trim().isNotEmpty) {
        final formatted = _formatIntentReason(l10n, r);
        if (formatted.isNotEmpty) {
          formattedIntents.add(formatted);
        }
      }
    }

    // Build the sentence based on match type
    if (matchType == 'event') {
      final sharedEventText = _getTranslationWithFallback(l10n, 'sharedEvent');
      final intentsText = formattedIntents.isNotEmpty
          ? formattedIntents.join(', ')
          : '';
      final youMatchedBecause = _getTranslationWithFallback(
        l10n,
        'youMatchedBecause',
      );

      if (intentsText.isNotEmpty) {
        return '$youMatchedBecause $sharedEventText, $intentsText.';
      } else {
        return '$youMatchedBecause $sharedEventText.';
      }
    } else if (matchType == 'proximity' || matchType == 'manual_test') {
      final proximityText = _getTranslationWithFallback(l10n, 'proximity');
      final intentsText = formattedIntents.isNotEmpty
          ? formattedIntents.join(', ')
          : '';
      final youMatchedBecause = _getTranslationWithFallback(
        l10n,
        'youMatchedBecause',
      );
      final andShared = _getTranslationWithFallback(l10n, 'andShared');

      if (intentsText.isNotEmpty) {
        return '$youMatchedBecause $proximityText, $andShared $intentsText.';
      } else {
        return '$youMatchedBecause $proximityText.';
      }
    } else if (matchType == 'co_motion') {
      final movingTogetherText = _getTranslationWithFallback(
        l10n,
        'matchReasonMovingTogether',
      );
      final intentsText = formattedIntents.isNotEmpty
          ? formattedIntents.join(', ')
          : '';
      final youMatchedBecause = _getTranslationWithFallback(
        l10n,
        'youMatchedBecause',
      );

      if (intentsText.isNotEmpty) {
        return '$youMatchedBecause $movingTogetherText, $intentsText.';
      } else {
        return '$youMatchedBecause $movingTogetherText.';
      }
    } else {
      // Fallback to comma-separated for other types
      return formatMatchReasons(
        ref,
        matchedIntent,
        matchType,
        eventName: eventName,
      );
    }
  }

  /// Format a single intent reason with Supabase translation and fallback
  static String _formatIntentReason(LocalizationState l10n, String reason) {
    if (reason.trim().isEmpty) return '';

    // Check if this is a valid intent key (case insensitive)
    final lowerReason = reason.toLowerCase().trim();
    // Allow any non-empty intent except known invalid ones
    final isValidIntent =
        lowerReason.isNotEmpty &&
        lowerReason != 'attending same event' &&
        lowerReason != 'unknown' &&
        !lowerReason.contains('attend') &&
        !lowerReason.contains('event');

    // If not a valid intent key, don't display it (return empty string)
    if (!isValidIntent) {
      return '';
    }

    // Clean the reason string
    final cleanedReason = reason.replaceAll('_', ' ').trim();
    if (cleanedReason.isEmpty) return '';

    // Try to get translation from Supabase
    String translated = _getTranslationWithFallback(l10n, cleanedReason);

    // If translation is missing or empty, use humanized version
    if (translated == cleanedReason ||
        translated.isEmpty ||
        translated.endsWith('...')) {
      translated = _humanizeReason(cleanedReason);
    }

    return translated;
  }

  /// Get translation from Supabase
  static String _getTranslationWithFallback(
    LocalizationState l10n,
    String key,
  ) {
    return l10n.getString(key);
  }

  /// Humanize a reason string by capitalizing words
  static String _humanizeReason(String reason) {
    if (reason.trim().isEmpty) return '';

    return reason
        .split(' ')
        .map(
          (word) => word.isNotEmpty
              ? word[0].toUpperCase() + word.substring(1).toLowerCase()
              : '',
        )
        .join(' ');
  }
}
