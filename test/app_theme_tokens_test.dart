import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/theme/app_theme_tokens.dart';

double _contrast(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = max(firstLuminance, secondLuminance);
  final darker = min(firstLuminance, secondLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  test('light primary tokens meet normal-text contrast targets', () {
    final scheme =
        AppThemeTokens.applyLightPrimary(
          ColorScheme.fromSeed(
            seedColor: AppThemeTokens.lightSeedColor,
            brightness: Brightness.light,
          ),
        ).copyWith(
          surface: const Color(0xFFF8FAFC),
          onSurface: const Color(0xFF1E293B),
        );

    expect(
      _contrast(scheme.primary, scheme.surface),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(scheme.onPrimary, scheme.primary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('dark primary tokens meet normal-text contrast targets', () {
    final scheme =
        AppThemeTokens.applyDarkPrimary(
          ColorScheme.fromSeed(
            seedColor: AppThemeTokens.darkSeedColor,
            brightness: Brightness.dark,
          ),
        ).copyWith(
          surface: const Color(0xFF0F172A),
          onSurface: const Color(0xFFE6EEF8),
        );

    expect(
      _contrast(scheme.primary, scheme.surface),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(scheme.onPrimary, scheme.primary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
      greaterThanOrEqualTo(4.5),
    );
  });
}
