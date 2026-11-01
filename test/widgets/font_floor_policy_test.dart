// Regression tests for the app-wide type ramp (lib/theme/app_theme_tokens.dart):
// row titles 16, status lines 14, action labels 15, and nothing user-facing
// under 12.
//
// 1. Source scan — fails if a hard-coded `fontSize:` below the floor comes
//    back into the app. The ramp lives in the theme, so a literal size is
//    almost always a mistake; the only files allowed to carry one are listed
//    below with the reason.
// 2. Theme test — the ramp values themselves, so a tweak to the token file is
//    a deliberate act rather than a silent regression.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/theme/app_theme_tokens.dart';

/// Files may render below 12, with the reason. Keep this list empty unless the
/// text is genuinely not body copy.
const _exemptFiles = <String, String>{
  'onboarding_scenes.dart':
      'the miniature phone in the onboarding scenes is a scale model, '
      'not readable text',
};

void main() {
  group('source scan: no hard-coded size below the 12 floor', () {
    late List<File> dartFiles;

    setUpAll(() {
      dartFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
    });

    test('every fontSize: literal in lib/ is at least 12', () {
      final pattern = RegExp(r'(?<![A-Za-z])fontSize:\s*(\d+(?:\.\d+)?)');
      final offenders = <String>[];

      for (final file in dartFiles) {
        final exempt = _exemptFiles.entries.where(
          (e) => file.path.endsWith(e.key),
        );
        if (exempt.isNotEmpty) continue;

        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final match in pattern.allMatches(lines[i])) {
            final size = double.parse(match.group(1)!);
            if (size < 12.0) {
              offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Text below 12 is too small to read on a phone. Take the size '
            'from the theme (textTheme.titleSmall/bodySmall/labelLarge/'
            'labelSmall) instead of a literal. Offenders:\n'
            '${offenders.join('\n')}',
      );
    });
  });

  group('the theme ramp is what the floor was set from', () {
    final theme = AppThemeTokens.lightThemeData(
      textTheme: ThemeData.light().textTheme,
    );
    final text = theme.textTheme;

    test('the styles the app builds its rows from carry the ramp', () {
      expect(text.titleSmall?.fontSize, 16.0);
      expect(text.bodySmall?.fontSize, 14.0);
      expect(text.labelLarge?.fontSize, 15.0);
      expect(text.labelSmall?.fontSize, 12.0);
    });

    test('no style in the ramp drops below the floor', () {
      final sizes = <String, double?>{
        'displaySmall': text.displaySmall?.fontSize,
        'headlineLarge': text.headlineLarge?.fontSize,
        'headlineMedium': text.headlineMedium?.fontSize,
        'titleLarge': text.titleLarge?.fontSize,
        'titleMedium': text.titleMedium?.fontSize,
        'titleSmall': text.titleSmall?.fontSize,
        'bodyLarge': text.bodyLarge?.fontSize,
        'bodyMedium': text.bodyMedium?.fontSize,
        'bodySmall': text.bodySmall?.fontSize,
        'labelLarge': text.labelLarge?.fontSize,
        'labelMedium': text.labelMedium?.fontSize,
        'labelSmall': text.labelSmall?.fontSize,
      };
      for (final entry in sizes.entries) {
        // A style the app does not define is not user-facing text either, so
        // only the sizes that exist are held to the floor.
        if (entry.value == null) continue;
        expect(
          entry.value,
          greaterThanOrEqualTo(12.0),
          reason: '${entry.key} is ${entry.value}',
        );
      }
      expect(text.titleSmall, isNotNull);
      expect(text.bodySmall, isNotNull);
      expect(text.labelLarge, isNotNull);
      expect(text.labelSmall, isNotNull);
    });
  });
}
