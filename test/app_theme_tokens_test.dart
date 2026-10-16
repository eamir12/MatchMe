import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/utils/match_score_utils.dart';

double _contrast(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = max(firstLuminance, secondLuminance);
  final darker = min(firstLuminance, secondLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

void _expectNormalTextContrast(
  String label,
  Color foreground,
  Color background,
) {
  expect(
    _contrast(foreground, background),
    greaterThanOrEqualTo(4.5),
    reason: '$label must meet WCAG AA normal-text contrast (4.5:1)',
  );
}

void _expectNonTextContrast(
  String label,
  Color foreground,
  Color background,
) {
  expect(
    _contrast(foreground, background),
    greaterThanOrEqualTo(3.0),
    reason: '$label must meet WCAG AA non-text contrast (3:1)',
  );
}

void main() {
  final dark = AppThemeTokens.darkColorScheme();
  final light = AppThemeTokens.lightColorScheme();

  test('light core tokens meet normal-text contrast targets', () {
    _expectNormalTextContrast('primary on surface', light.primary, light.surface);
    _expectNormalTextContrast(
      'onPrimary on primary',
      light.onPrimary,
      light.primary,
    );
    _expectNormalTextContrast(
      'onSurface on surface',
      light.onSurface,
      light.surface,
    );
    _expectNormalTextContrast(
      'onPrimaryContainer on primaryContainer',
      light.onPrimaryContainer,
      light.primaryContainer,
    );
  });

  test('dark core tokens meet normal-text contrast targets', () {
    _expectNormalTextContrast('primary on surface', dark.primary, dark.surface);
    _expectNormalTextContrast(
      'onPrimary on primary',
      dark.onPrimary,
      dark.primary,
    );
    _expectNormalTextContrast(
      'onSurface on surface',
      dark.onSurface,
      dark.surface,
    );
    _expectNormalTextContrast(
      'onPrimaryContainer on primaryContainer',
      dark.onPrimaryContainer,
      dark.primaryContainer,
    );
    _expectNormalTextContrast(
      'secondary on surface',
      dark.secondary,
      dark.surface,
    );
    _expectNormalTextContrast(
      'tertiary on surface',
      dark.tertiary,
      dark.surface,
    );
    _expectNormalTextContrast(
      'onTertiary on tertiary',
      dark.onTertiary,
      dark.tertiary,
    );
    _expectNormalTextContrast(
      'onTertiaryContainer on tertiaryContainer',
      dark.onTertiaryContainer,
      dark.tertiaryContainer,
    );
    _expectNormalTextContrast(
      'onSecondary on secondary',
      dark.onSecondary,
      dark.secondary,
    );
    _expectNormalTextContrast('error on surface', dark.error, dark.surface);
    _expectNormalTextContrast('onError on error', dark.onError, dark.error);
    _expectNormalTextContrast(
      'onInverseSurface on inverseSurface',
      dark.onInverseSurface,
      dark.inverseSurface,
    );
  });

  test('dark surface stack keeps text and outlines legible', () {
    final containers = <String, Color>{
      'surface': dark.surface,
      'surfaceDim': dark.surfaceDim,
      'surfaceBright': dark.surfaceBright,
      'surfaceContainerLowest': dark.surfaceContainerLowest,
      'surfaceContainerLow': dark.surfaceContainerLow,
      'surfaceContainer': dark.surfaceContainer,
      'surfaceContainerHigh': dark.surfaceContainerHigh,
      'surfaceContainerHighest': dark.surfaceContainerHighest,
    };
    containers.forEach((name, color) {
      _expectNormalTextContrast(
        'onSurface on $name',
        dark.onSurface,
        color,
      );
      _expectNormalTextContrast(
        'onSurfaceVariant on $name',
        dark.onSurfaceVariant,
        color,
      );
      _expectNonTextContrast('outline on $name', dark.outline, color);
    });

    // The dark input field outline is painted at 75% over the field fill;
    // assert the effective (blended) border stays visible against the fill.
    final blendedBorder = Color.alphaBlend(
      dark.outline.withValues(alpha: 0.75),
      dark.surfaceContainerLow,
    );
    _expectNonTextContrast(
      'blended input border on input fill',
      blendedBorder,
      dark.surfaceContainerLow,
    );

    // Elevated surfaces must be distinguishable from the canvas.
    expect(
      _contrast(dark.surfaceContainerLow, dark.surface),
      greaterThan(1.15),
      reason: 'surfaceContainerLow must read as elevated over surface',
    );
    expect(
      _contrast(dark.surfaceContainerHighest, dark.surface),
      greaterThan(1.4),
      reason: 'surfaceContainerHighest must read as elevated over surface',
    );
  });

  test('semantic colors meet contrast targets in both modes', () {
    final lightTheme = AppThemeTokens.lightThemeData(
      textTheme: ThemeData.light().textTheme,
    );
    final darkTheme = AppThemeTokens.darkThemeData(
      textTheme: ThemeData.dark().textTheme,
    );
    final lightSemantic = lightTheme.extension<SemanticColors>()!;
    final darkSemantic = darkTheme.extension<SemanticColors>()!;

    _expectNormalTextContrast(
      'light success on surface',
      lightSemantic.success,
      light.surface,
    );
    _expectNormalTextContrast(
      'light onSuccess on success',
      lightSemantic.onSuccess,
      lightSemantic.success,
    );
    _expectNormalTextContrast(
      'light onSuccessContainer on successContainer',
      lightSemantic.onSuccessContainer,
      lightSemantic.successContainer,
    );

    _expectNormalTextContrast(
      'dark success on surface',
      darkSemantic.success,
      dark.surface,
    );
    _expectNormalTextContrast(
      'dark onSuccess on success',
      darkSemantic.onSuccess,
      darkSemantic.success,
    );
    _expectNormalTextContrast(
      'dark onSuccessContainer on successContainer',
      darkSemantic.onSuccessContainer,
      darkSemantic.successContainer,
    );
  });

  test('shared-interest ramp stays readable on both surfaces', () {
    for (var count = 0; count <= 12; count++) {
      _expectNormalTextContrast(
        'light ramp($count) on light surface',
        sharedInterestColor(count, Brightness.light),
        light.surface,
      );
      _expectNormalTextContrast(
        'dark ramp($count) on dark surface',
        sharedInterestColor(count, Brightness.dark),
        dark.surface,
      );
    }
  });

  test('dark ThemeData wires text and component themes coherently', () {
    final theme = AppThemeTokens.darkThemeData(
      textTheme: ThemeData.dark().textTheme,
    );

    // Body text must follow the scheme, never a hardcoded white.
    expect(theme.textTheme.bodyMedium?.color, AppThemeTokens.darkOnSurface);
    expect(theme.textTheme.displayLarge?.color, AppThemeTokens.darkOnSurface);
    expect(theme.scaffoldBackgroundColor, AppThemeTokens.darkSurface);

    // Component themes must exist in dark mode (they used to be light-only).
    expect(theme.cardTheme.color, AppThemeTokens.darkSurfaceContainerLow);
    expect(theme.inputDecorationTheme.filled, isTrue);
    expect(theme.inputDecorationTheme.fillColor,
        AppThemeTokens.darkSurfaceContainerLow);
    expect(theme.dividerTheme.color, AppThemeTokens.darkOutlineVariant);
    expect(theme.chipTheme.backgroundColor,
        AppThemeTokens.darkSurfaceContainerHigh);
    expect(theme.appBarTheme.backgroundColor, AppThemeTokens.darkSurface);
  });

  test('dark palette is fully pinned (no framework-derived surfaces)', () {
    final base = ColorScheme.fromSeed(
      seedColor: AppThemeTokens.darkSeedColor,
      brightness: Brightness.dark,
    );
    expect(dark.surface, isNot(base.surface));
    expect(dark.surfaceContainerLow, AppThemeTokens.darkSurfaceContainerLow);
    expect(dark.surfaceContainer, AppThemeTokens.darkSurfaceContainer);
    expect(dark.surfaceContainerHigh, AppThemeTokens.darkSurfaceContainerHigh);
    expect(
      dark.surfaceContainerHighest,
      AppThemeTokens.darkSurfaceContainerHighest,
    );
    expect(dark.onSurfaceVariant, AppThemeTokens.darkOnSurfaceVariant);
    expect(dark.outline, AppThemeTokens.darkOutline);
    expect(dark.outlineVariant, AppThemeTokens.darkOutlineVariant);
  });

  test('AMOLED scheme switches every base surface to true black', () {
    final amoled = AppThemeTokens.amoledColorScheme();
    expect(amoled.brightness, Brightness.dark);
    expect(amoled.surface, AppThemeTokens.amoledSurface);
    expect(amoled.surface, const Color(0xFF000000));
    expect(amoled.surfaceDim, AppThemeTokens.amoledSurfaceDim);
    expect(amoled.surfaceContainerLowest, const Color(0xFF000000));
    expect(amoled.surfaceContainerLow, AppThemeTokens.amoledSurfaceContainerLow);

    // Text/status colors are inherited from the slate dark scheme.
    expect(amoled.onSurface, AppThemeTokens.darkOnSurface);
    expect(amoled.onSurfaceVariant, AppThemeTokens.darkOnSurfaceVariant);
    expect(amoled.primary, AppThemeTokens.darkPrimary);
  });

  test('AMOLED surface stack keeps every role above black contrast targets', () {
    final amoled = AppThemeTokens.amoledColorScheme();
    final stack = <Color>[
      amoled.surface,
      amoled.surfaceContainerLow,
      amoled.surfaceContainer,
      amoled.surfaceContainerHigh,
      amoled.surfaceContainerHighest,
    ];

    // The stack must stay monotonic so elevation still reads on pure black.
    for (var i = 1; i < stack.length; i++) {
      expect(
        stack[i].computeLuminance(),
        greaterThanOrEqualTo(stack[i - 1].computeLuminance()),
        reason: 'AMOLED surface stack step $i must not get darker',
      );
    }
    expect(
      _contrast(amoled.surfaceContainerLow, amoled.surface),
      greaterThan(1.03),
      reason: 'first AMOLED elevation step must be perceptible over black',
    );

    // Brightest container is where dense content (lists, chips) lives.
    for (final surface in [amoled.surface, amoled.surfaceContainerHighest]) {
      _expectNormalTextContrast('onSurface on AMOLED surface', amoled.onSurface, surface);
      _expectNormalTextContrast(
        'onSurfaceVariant on AMOLED surface',
        amoled.onSurfaceVariant,
        surface,
      );
      _expectNonTextContrast('outline on AMOLED surface', amoled.outline, surface);
      _expectNonTextContrast(
        'primary on AMOLED surface',
        amoled.primary,
        surface,
      );
    }
  });

  test('AMOLED ThemeData pins scaffold and component surfaces to black', () {
    final theme = AppThemeTokens.amoledDarkThemeData(
      textTheme: ThemeData.dark().textTheme,
    );

    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, AppThemeTokens.amoledSurface);
    expect(theme.appBarTheme.backgroundColor, AppThemeTokens.amoledSurface);
    expect(theme.navigationBarTheme.backgroundColor, AppThemeTokens.amoledSurface);
    expect(theme.cardTheme.color, AppThemeTokens.amoledSurfaceContainerLow);
    expect(theme.inputDecorationTheme.fillColor,
        AppThemeTokens.amoledSurfaceContainerLow);
    expect(theme.textTheme.bodyMedium?.color, AppThemeTokens.darkOnSurface);
  });
}
