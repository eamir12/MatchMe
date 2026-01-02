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
      reasons = (matchedIntent).map((e) => e.toString()).toList();
    } else {
      final str = matchedIntent.toString();
      reasons =
          str.contains(',')
              ? str.split(',').map((e) => e.trim()).toList()
              : [str];
    }

    // Format intent reasons: replace underscores, capitalize, filter nulls
    final formattedIntents =
        reasons
            .where((r) => r.trim().isNotEmpty)
            .map((r) => _formatIntentReason(l10n, r))
            .toList();

    final List<String> lines = [];

    // Add event line if this is an event match
    if (matchType == 'event' && eventName != null && eventName.isNotEmpty) {
      final eventLabel = _getTranslationWithFallback(
        l10n,
        'eventLabel',
        hardcodedFallback: 'Event',
      );
      lines.add('$eventLabel: $eventName');
    }

    // Add intent line if there are intents
    if (formattedIntents.isNotEmpty) {
      final intentText = formattedIntents.join(', ');
      if (intentText.trim().isNotEmpty) {
        final intentLabel = _getTranslationWithFallback(
          l10n,
          'intentLabel',
          hardcodedFallback: 'Intent',
        );
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
      reasons = (matchedIntent).map((e) => e.toString()).toList();
    } else {
      final str = matchedIntent.toString();
      reasons =
          str.contains(',')
              ? str.split(',').map((e) => e.trim()).toList()
              : [str];
    }

    // Format intent reasons: replace underscores, capitalize, filter nulls
    final formattedIntents =
        reasons
            .where((r) => r.trim().isNotEmpty)
            .map((r) => _formatIntentReason(l10n, r))
            .toList();

    // Build the sentence based on match type
    if (matchType == 'event') {
      final sharedEventText = _getTranslationWithFallback(
        l10n,
        'sharedEvent',
        hardcodedFallback: 'a shared event',
      );
      final intentsText =
          formattedIntents.isNotEmpty ? formattedIntents.join(', ') : '';
      final youMatchedBecause = _getTranslationWithFallback(
        l10n,
        'youMatchedBecause',
        hardcodedFallback: 'You matched because of',
      );

      if (intentsText.isNotEmpty) {
        return '$youMatchedBecause $sharedEventText, $intentsText.';
      } else {
        return '$youMatchedBecause $sharedEventText.';
      }
    } else if (matchType == 'proximity' || matchType == 'manual_test') {
      final proximityText = _getTranslationWithFallback(
        l10n,
        'proximity',
        hardcodedFallback: 'proximity',
      );
      final intentsText =
          formattedIntents.isNotEmpty ? formattedIntents.join(', ') : '';
      final youMatchedBecause = _getTranslationWithFallback(
        l10n,
        'youMatchedBecause',
        hardcodedFallback: 'You matched because of',
      );
      final andShared = _getTranslationWithFallback(
        l10n,
        'andShared',
        hardcodedFallback: 'and shared',
      );

      if (intentsText.isNotEmpty) {
        return '$youMatchedBecause $proximityText, $andShared $intentsText.';
      } else {
        return '$youMatchedBecause $proximityText.';
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

    // If translation is the same as the key or empty, use humanized version
    if (translated == cleanedReason || translated.isEmpty) {
      translated = _humanizeReason(cleanedReason);
    }

    return translated;
  }

  /// Get translation from Supabase with fallback to humanized version or hardcoded fallback
  static String _getTranslationWithFallback(
    LocalizationState l10n,
    String key, {
    String? hardcodedFallback,
  }) {
    try {
      final translation = l10n.getString(key);
      // Check if translation is missing (returns key with '...' format)
      if (translation == key ||
          translation.trim().isEmpty ||
          translation.endsWith('...')) {
        return hardcodedFallback ?? _humanizeReason(key);
      }
      return translation;
    } catch (e) {
      // If any error occurs, fall back to hardcoded or humanized version
      return hardcodedFallback ?? _humanizeReason(key);
    }
  }

  /// Humanize a reason string by capitalizing words
  static String _humanizeReason(String reason) {
    if (reason.trim().isEmpty) return '';

    return reason
        .split(' ')
        .map(
          (word) =>
              word.isNotEmpty
                  ? word[0].toUpperCase() + word.substring(1).toLowerCase()
                  : '',
        )
        .join(' ');
  }
}
