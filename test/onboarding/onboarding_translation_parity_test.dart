// test/onboarding/onboarding_translation_parity_test.dart
//
// The onboarding tour renders the *shipped* translation for every beat
// (public.translations, seeded by supabase/migrations/*onboarding*). For
// English there is no DB row to fall back on in the widget tests, so the
// tour shows the built-in English fallback from
// lib/providers/locale_provider.dart instead.
//
// That means the two can drift apart: when the English fallback is edited
// (e.g. the "Verified badge" -> "Primary Photo Verified" relabel) and the
// migration that ships the same copy is not added, the app shows one thing
// and the database another - and the tour smoke test fails with a confusing
// "subtitle equals shipped narration" mismatch.
//
// This test pins the two together: every shipped English onboarding string
// that also has a built-in fallback must be identical to that fallback.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Mirrors scripts/check_onboarding_translations.js: merges every
/// migrations/*onboarding* file, later wins, deletes applied per file.
Map<String, Map<String, String>> loadMergedSql() {
  final root = Directory('supabase/migrations');
  if (!root.existsSync()) {
    throw StateError(
      'supabase/migrations not found from ${Directory.current.path}',
    );
  }
  final files =
      root
          .listSync()
          .whereType<File>()
          .where(
            (f) => RegExp(
              r'onboarding',
              caseSensitive: false,
            ).hasMatch(f.uri.pathSegments.last),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final sql = {
    'en': <String, String>{},
    'es': <String, String>{},
    'he': <String, String>{},
  };
  final insertRe = RegExp(
    r"\('(\w{2})',\s*'(onboarding[^']*|demo[^']*|settingsAppTour[^']*)',\s*'((?:[^']|'')*)'\)",
  );
  final deleteRe = RegExp(r"\bkey\s+IN\s*\(([^)]*)\)");
  for (final f in files) {
    final text = f.readAsStringSync();
    for (final d in deleteRe.allMatches(text)) {
      for (final k in RegExp("'([^']*)'").allMatches(d.group(1)!)) {
        for (final locale in sql.keys) {
          sql[locale]!.remove(k.group(1));
        }
      }
    }
    for (final m in insertRe.allMatches(text)) {
      sql[m.group(1)]![m.group(2)!] = m.group(3)!.replaceAll("''", "'");
    }
  }
  return sql;
}

void main() {
  test('shipped English onboarding copy matches the built-in fallbacks', () {
    final sql = loadMergedSql();
    final drifted = <String, List<String>>{};

    for (final entry in sql['en']!.entries) {
      if (!entry.key.startsWith('onboarding')) continue;
      final fallback = LocalizationState.defaultTranslation(entry.key);
      // Keys without a built-in fallback are shipped-only: the database row
      // is their single source of truth.
      if (fallback == '[${entry.key}]') continue;
      if (fallback == entry.value) continue;
      drifted.putIfAbsent(entry.key, () => <String>[]).addAll([
        'shipped : ${entry.value}',
        'fallback: $fallback',
      ]);
    }

    expect(
      drifted,
      isEmpty,
      reason:
          'The shipped English onboarding copy drifted from the built-in '
          'fallbacks in locale_provider.dart. Add a migration that re-seeds '
          'the affected keys with the fallback text (later migrations win).',
    );
  });

  test('every onboarding beat has shipped copy in all three locales', () {
    final sql = loadMergedSql();
    final missing = <String>[];

    for (final locale in ['en', 'es', 'he']) {
      for (final entry in sql['en']!.entries) {
        if (!entry.key.startsWith('onboardingBeat')) continue;
        if (sql[locale]!.containsKey(entry.key)) continue;
        missing.add('$locale:${entry.key}');
      }
    }

    expect(
      missing,
      isEmpty,
      reason: 'Onboarding beats without a shipped translation.',
    );
  });
}
