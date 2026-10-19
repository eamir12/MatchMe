import 'package:flutter/material.dart';
import 'package:matchme/theme/semantic_colors.dart';

/// Central design tokens for MatchMe.
///
/// The app is built on a hand-tuned Material 3 palette:
///  * primary   - indigo (brand)
///  * secondary - pink (brand accent)
///  * tertiary  - amber (warnings / highlights)
///  * surfaces  - slate neutrals in both modes
///
/// Dark mode never relies on framework-derived surfaces: every
/// `surfaceContainer*` role is pinned to the slate family so that scaffolds,
/// cards, dialogs, sheets and menus stay in one hue with clearly stepped
/// elevation, and every `on*` role is contrast-checked against its pairing.
class AppThemeTokens {
  AppThemeTokens._();

  // ---------------------------------------------------------------------------
  // Light palette
  // ---------------------------------------------------------------------------
  static const Color lightSeedColor = Color(0xFF4F46E5);
  static const Color lightPrimary = Color(0xFF4F46E5);
  static const Color lightOnPrimary = Colors.white;
  static const Color lightSecondary = Color(0xFFEC4899);
  static const Color lightOnSecondary = Color(0xFF3D0723);
  static const Color lightTertiary = Color(0xFFF59E0B);
  static const Color lightSurface = Color(0xFFF8FAFC);
  static const Color lightOnSurface = Color(0xFF1E293B);

  // Semantic status colors (light)
  static const Color lightSuccess = Color(0xFF047857);
  static const Color lightOnSuccess = Colors.white;
  static const Color lightSuccessContainer = Color(0xFFDCFCE7);
  static const Color lightOnSuccessContainer = Color(0xFF064E3B);

  // ---------------------------------------------------------------------------
  // Dark palette (slate family, indigo-400 primary)
  // ---------------------------------------------------------------------------
  static const Color darkSeedColor = Color(0xFF818CF8);
  static const Color darkPrimary = Color(0xFF818CF8);
  static const Color darkOnPrimary = Color(0xFF1E1B4B);
  static const Color darkSecondary = Color(0xFFEC4899);
  static const Color darkOnSecondary = Color(0xFF3D0723);
  static const Color darkTertiary = Color(0xFFFBBF24);
  static const Color darkOnTertiary = Color(0xFF422006);
  static const Color darkTertiaryContainer = Color(0xFF6B4400);
  static const Color darkOnTertiaryContainer = Color(0xFFFFE7B3);

  // Surface stack: each step is a perceptibly lighter slate than the last.
  static const Color darkSurface = Color(0xFF0F172A);
  static const Color darkOnSurface = Color(0xFFE6EEF8);
  static const Color darkSurfaceDim = Color(0xFF0B1120);
  static const Color darkSurfaceBright = Color(0xFF33415E);
  static const Color darkSurfaceContainerLowest = Color(0xFF0A101F);
  static const Color darkSurfaceContainerLow = Color(0xFF1A2440);
  static const Color darkSurfaceContainer = Color(0xFF202C4A);
  static const Color darkSurfaceContainerHigh = Color(0xFF283657);
  static const Color darkSurfaceContainerHighest = Color(0xFF304066);
  static const Color darkOnSurfaceVariant = Color(0xFFB7C3D9);
  static const Color darkOutline = Color(0xFF8E9BB3);
  static const Color darkOutlineVariant = Color(0xFF3A4761);
  static const Color darkInverseSurface = Color(0xFFE2E8F0);
  static const Color darkOnInverseSurface = Color(0xFF0F172A);

  // Semantic status colors (dark)
  static const Color darkSuccess = Color(0xFF34D399);
  static const Color darkOnSuccess = Color(0xFF052E16);
  static const Color darkSuccessContainer = Color(0xFF064E3B);
  static const Color darkOnSuccessContainer = Color(0xFFA7F3D0);

  // ---------------------------------------------------------------------------
  // AMOLED palette (true-black variant of the dark theme)
  // ---------------------------------------------------------------------------
  // The base surfaces are pure black so OLED pixels switch off, while the
  // elevation stack steps by a few luminance points per level so cards,
  // sheets and menus stay distinguishable on the black canvas.
  static const Color amoledSurface = Color(0xFF000000);
  static const Color amoledSurfaceDim = Color(0xFF000000);
  static const Color amoledSurfaceBright = Color(0xFF1C2742);
  static const Color amoledSurfaceContainerLowest = Color(0xFF000000);
  static const Color amoledSurfaceContainerLow = Color(0xFF0A101F);
  static const Color amoledSurfaceContainer = Color(0xFF0F1930);
  static const Color amoledSurfaceContainerHigh = Color(0xFF16223C);
  static const Color amoledSurfaceContainerHighest = Color(0xFF1E2C4A);

  static const List<String> _fontFamilyFallback = [
    'Noto Sans',
    'Roboto',
    'Segoe UI',
    'Helvetica Neue',
  ];

  // ---------------------------------------------------------------------------
  // Adaptive brand accents
  // ---------------------------------------------------------------------------
  /// Softens a brand/semantic accent for the current brightness.
  ///
  /// Decorative category colors (purple, teal, orange, brand blues) are tuned
  /// for light surfaces and sink below contrast on dark fills. On dark
  /// surfaces the glyph is lightened toward white so it stays legible on the
  /// translucent [accentSurface] tint; light mode keeps the accent as-is.
  static Color accentInk(Color accent, Brightness brightness) => brightness ==
          Brightness.dark
      ? (Color.lerp(accent, Colors.white, 0.55) ?? accent)
      : accent;

  /// Translucent companion fill for [accentInk] chips and avatar circles.
  static Color accentSurface(Color accent, Brightness brightness) => accent
      .withValues(alpha: brightness == Brightness.dark ? 0.24 : 0.12);

  // ---------------------------------------------------------------------------
  // Color schemes
  // ---------------------------------------------------------------------------
  static ColorScheme lightColorScheme() {
    return ColorScheme.fromSeed(
      seedColor: lightSeedColor,
      brightness: Brightness.light,
    ).copyWith(
      primary: lightPrimary,
      onPrimary: lightOnPrimary,
      secondary: lightSecondary,
      onSecondary: lightOnSecondary,
      tertiary: lightTertiary,
      surface: lightSurface,
      onSurface: lightOnSurface,
    );
  }

  static ColorScheme darkColorScheme() {
    return ColorScheme.fromSeed(
      seedColor: darkSeedColor,
      brightness: Brightness.dark,
    ).copyWith(
      primary: darkPrimary,
      onPrimary: darkOnPrimary,
      secondary: darkSecondary,
      onSecondary: darkOnSecondary,
      tertiary: darkTertiary,
      onTertiary: darkOnTertiary,
      tertiaryContainer: darkTertiaryContainer,
      onTertiaryContainer: darkOnTertiaryContainer,
      surface: darkSurface,
      onSurface: darkOnSurface,
      surfaceDim: darkSurfaceDim,
      surfaceBright: darkSurfaceBright,
      surfaceContainerLowest: darkSurfaceContainerLowest,
      surfaceContainerLow: darkSurfaceContainerLow,
      surfaceContainer: darkSurfaceContainer,
      surfaceContainerHigh: darkSurfaceContainerHigh,
      surfaceContainerHighest: darkSurfaceContainerHighest,
      onSurfaceVariant: darkOnSurfaceVariant,
      outline: darkOutline,
      outlineVariant: darkOutlineVariant,
      inverseSurface: darkInverseSurface,
      onInverseSurface: darkOnInverseSurface,
    );
  }

  static ColorScheme amoledColorScheme() {
    return darkColorScheme().copyWith(
      surface: amoledSurface,
      surfaceDim: amoledSurfaceDim,
      surfaceBright: amoledSurfaceBright,
      surfaceContainerLowest: amoledSurfaceContainerLowest,
      surfaceContainerLow: amoledSurfaceContainerLow,
      surfaceContainer: amoledSurfaceContainer,
      surfaceContainerHigh: amoledSurfaceContainerHigh,
      surfaceContainerHighest: amoledSurfaceContainerHighest,
    );
  }

  // ---------------------------------------------------------------------------
  // ThemeData
  // ---------------------------------------------------------------------------
  static ThemeData lightThemeData({required TextTheme textTheme}) {
    final scheme = lightColorScheme();
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      fontFamilyFallback: _fontFamilyFallback,
      extensions: <ThemeExtension<dynamic>>[
        const SemanticColors(
          success: lightSuccess,
          onSuccess: lightOnSuccess,
          successContainer: lightSuccessContainer,
          onSuccessContainer: lightOnSuccessContainer,
        ),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Noto Sans',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      cardTheme: CardThemeData(
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: scheme.surface,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primary.withValues(alpha: 0.1),
        checkmarkColor: scheme.primary,
        labelStyle: TextStyle(color: scheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.surfaceContainerHighest),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
        filled: true,
        fillColor: scheme.surface,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.surfaceContainerHighest,
        thickness: 1,
      ),
      textTheme: _styledTextTheme(textTheme, scheme),
    );
  }

  static ThemeData darkThemeData({required TextTheme textTheme}) =>
      _darkThemeData(darkColorScheme(), textTheme: textTheme);

  static ThemeData amoledDarkThemeData({required TextTheme textTheme}) =>
      _darkThemeData(amoledColorScheme(), textTheme: textTheme);

  static ThemeData _darkThemeData(
    ColorScheme scheme, {
    required TextTheme textTheme,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamilyFallback: _fontFamilyFallback,
      extensions: <ThemeExtension<dynamic>>[
        const SemanticColors(
          success: darkSuccess,
          onSuccess: darkOnSuccess,
          successContainer: darkSuccessContainer,
          onSuccessContainer: darkOnSuccessContainer,
        ),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Noto Sans',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      // Shadows are nearly invisible on dark backgrounds, so cards and other
      // containers express elevation through a lighter slate surface plus a
      // hairline border instead.
      cardTheme: CardThemeData(
        elevation: 0,
        shadowColor: Colors.transparent,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.22),
        checkmarkColor: scheme.primary,
        labelStyle: TextStyle(color: scheme.onSurface),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.75)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.75)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      textTheme: _styledTextTheme(textTheme, scheme),
    );
  }

  static TextTheme _styledTextTheme(TextTheme base, ColorScheme scheme) {
    // Apply the scheme colors first, then tweak the styles on top of the
    // *applied* theme. Deriving the copyWith source from `base` would leak
    // the base colors back in: main.dart builds one text theme from
    // ThemeData.light() and hands it to both themes, which rendered input
    // text (bodyLarge) near-black on the dark surfaces.
    final applied = base.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    return applied.copyWith(
      headlineLarge: applied.headlineLarge?.copyWith(
        inherit: true,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      headlineMedium: applied.headlineMedium?.copyWith(
        inherit: true,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      ),
      titleLarge: applied.titleLarge?.copyWith(
        inherit: true,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: applied.bodyLarge?.copyWith(
        inherit: true,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
    );
  }
}
