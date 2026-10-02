// lib/utils/match_score_utils.dart
import 'package:flutter/material.dart';
import 'package:matchme/providers/profile_provider.dart';

/// Computes the number of distinct interests shared between two users,
/// restricted to the buckets matching the intents of this match.
///
/// Social intents (romantic, friendship, activity_partner) draw from the
/// personal interests pool; business_networking draws from the business
/// interests pool. When the matched intents are unknown or empty, both pools
/// are considered. A key shared under multiple categories counts once.
///
/// Returns 0 when either profile has not loaded yet.
int computeSharedInterestCount({
  required UserProfile? currentProfile,
  required UserProfile? otherProfile,
  required String matchedIntent,
}) {
  if (currentProfile == null || otherProfile == null) return 0;

  final intentKeys = matchedIntent
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();

  final wantsSocial =
      intentKeys.isEmpty || intentKeys.any((k) => k != 'business_networking');
  final wantsBusiness =
      intentKeys.isEmpty || intentKeys.contains('business_networking');

  final shared = <String>{};
  if (wantsSocial) {
    _addIntersection(
      shared,
      currentProfile.personalInterests,
      otherProfile.personalInterests,
    );
  }
  if (wantsBusiness) {
    _addIntersection(
      shared,
      currentProfile.businessInterests,
      otherProfile.businessInterests,
    );
  }
  return shared.length;
}

void _addIntersection(
  Set<String> out,
  Map<String, List<String>> a,
  Map<String, List<String>> b,
) {
  for (final entry in a.entries) {
    final otherValues = b[entry.key];
    if (otherValues == null || otherValues.isEmpty) continue;
    final otherSet = otherValues.toSet();
    for (final key in entry.value) {
      if (key.isNotEmpty && otherSet.contains(key)) out.add(key);
    }
  }
}

/// Optimistic color ramp for the shared-interest score. Even a single shared
/// interest is a positive signal, so there is no "bad" color: 0 is neutral
/// gray, mid-range values step through greens, and the maximum (10+) gets the
/// achievement gold.
Color sharedInterestColor(int count) {
  if (count <= 0) return const Color(0xFF9E9E9E);
  if (count <= 3) return const Color(0xFF2FA37B);
  if (count <= 6) return const Color(0xFF1F9D55);
  if (count <= 9) return const Color(0xFF146E42);
  return const Color(0xFFE5A61C);
}
