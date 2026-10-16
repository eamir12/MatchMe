import 'package:flutter/material.dart';
import 'package:matchme/theme/semantic_colors.dart';

/// Centralized component styling for cards, containers, and other UI elements
class AppComponentStyles {
  // Border radius constants
  static const double _mediumBorderRadius = 12.0;
  static const double _largeBorderRadius = 16.0;

  // Padding constants
  static const double _mediumPadding = 12.0;

  // Shadow constants
  static const double _shadowBlurRadius = 8.0;
  static const double _shadowSpreadRadius = 0.0;
  static const Offset _shadowOffset = Offset(0, 2);
  static const double _shadowAlpha = 0.08;

  // Spacing scale
  static const double spacing2 = 4.0;
  static const double spacing4 = 8.0;
  static const double spacing6 = 12.0;
  static const double spacing8 = 16.0;
  static const double spacing10 = 20.0;
  static const double spacing12 = 24.0;

  /// Standard card decoration with subtle shadow
  static BoxDecoration cardDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return BoxDecoration(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(_largeBorderRadius),
      boxShadow: [
        BoxShadow(
          color: theme.shadowColor.withValues(alpha: _shadowAlpha),
          blurRadius: _shadowBlurRadius,
          spreadRadius: _shadowSpreadRadius,
          offset: _shadowOffset,
        ),
      ],
    );
  }

  /// Card decoration with border (no shadow)
  static BoxDecoration cardDecorationWithBorder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(_largeBorderRadius),
      border: Border.all(
        color: colorScheme.outline.withValues(alpha: 0.2),
        width: 1.0,
      ),
    );
  }

  /// Container decoration for grouped content
  static BoxDecoration containerDecoration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: colorScheme.outline.withValues(alpha: 0.12),
        width: 1.0,
      ),
    );
  }

  /// Icon container with background (for accent icons)
  static BoxDecoration iconContainerDecoration(
    BuildContext context, {
    Color? backgroundColor,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = backgroundColor ?? colorScheme.primary;
    return BoxDecoration(
      color: bgColor.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
    );
  }

  /// Chip decoration (for tags, filters, etc.)
  static BoxDecoration chipDecoration(
    BuildContext context, {
    bool selected = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.2)
          : colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20.0),
      border: Border.all(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.5)
            : colorScheme.outline.withValues(alpha: 0.2),
        width: 1.0,
      ),
    );
  }

  /// Divider with standard styling
  static Widget divider(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Divider(
      color: colorScheme.outline.withValues(alpha: 0.12),
      height: spacing8,
      thickness: 1.0,
    );
  }

  /// Section header text style
  static TextStyle sectionHeaderStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ) ??
        const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        );
  }

  /// Subtitle text style
  static TextStyle subtitleStyle(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurface.withValues(alpha: 0.7),
        ) ??
        TextStyle(
          fontSize: 12,
          color: colorScheme.onSurface.withValues(alpha: 0.7),
        );
  }

  /// Helper text style (for descriptions, hints)
  static TextStyle helperTextStyle(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 12,
        ) ??
        TextStyle(
          fontSize: 12,
          color: colorScheme.onSurface.withValues(alpha: 0.6),
        );
  }

  /// Error text style
  static TextStyle errorTextStyle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontSize: 12,
      color: colorScheme.error,
      fontWeight: FontWeight.w500,
    );
  }

  /// Success text style
  static TextStyle successTextStyle(BuildContext context) {
    return TextStyle(
      fontSize: 12,
      color: SemanticColors.of(context).success,
      fontWeight: FontWeight.w500,
    );
  }

  /// Standard list tile decoration
  static BoxDecoration listTileDecoration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.surface,
      border: Border(
        bottom: BorderSide(
          color: colorScheme.outline.withValues(alpha: 0.12),
          width: 1.0,
        ),
      ),
    );
  }

  /// Input field decoration
  static InputDecoration inputDecoration(
    BuildContext context, {
    String? labelText,
    String? hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Field outlines are the only visual boundary of the field, so the dark
    // mode border needs enough contrast to stay visible (WCAG 1.4.11).
    final borderSide = BorderSide(
      color: colorScheme.outline.withValues(alpha: isDark ? 0.75 : 0.3),
    );
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_mediumBorderRadius),
        borderSide: borderSide,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_mediumBorderRadius),
        borderSide: borderSide,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_mediumBorderRadius),
        borderSide: BorderSide(color: colorScheme.primary, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_mediumBorderRadius),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_mediumBorderRadius),
        borderSide: BorderSide(color: colorScheme.error, width: 2.0),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: _mediumPadding,
        vertical: _mediumPadding,
      ),
    );
  }

  /// Standard border styling for cards and containers
  static Border standardBorder(BuildContext context, {double width = 1.0}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Border.all(
      color: colorScheme.outline.withValues(alpha: 0.2),
      width: width,
    );
  }

  /// Subtle border styling (lighter)
  static Border subtleBorder(BuildContext context, {double width = 1.0}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Border.all(
      color: colorScheme.outline.withValues(alpha: 0.12),
      width: width,
    );
  }

  /// Accent border styling (uses primary color)
  static Border accentBorder(BuildContext context, {double width = 1.0}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Border.all(
      color: colorScheme.primary.withValues(alpha: 0.2),
      width: width,
    );
  }

  /// Standard border radius for cards
  static BorderRadius cardBorderRadius() {
    return BorderRadius.circular(_largeBorderRadius);
  }

  /// Standard border radius for buttons and inputs
  static BorderRadius buttonBorderRadius() {
    return BorderRadius.circular(_mediumBorderRadius);
  }

  /// Standard border radius for small elements
  static BorderRadius smallBorderRadius() {
    return BorderRadius.circular(8.0);
  }

  /// ChoiceChip styling - for single selection
  static ChipThemeData choiceChipTheme(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.4,
      ),
      selectedColor: colorScheme.primary.withValues(alpha: 0.15),
      disabledColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      labelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: colorScheme.primary,
      ),
      brightness: Theme.of(context).brightness,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: StadiumBorder(
        side: BorderSide(
          color: colorScheme.outline.withValues(alpha: 0.2),
          width: 1.0,
        ),
      ),
    );
  }

  /// FilterChip styling - for multiple selection
  static ChipThemeData filterChipTheme(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.4,
      ),
      selectedColor: colorScheme.primary.withValues(alpha: 0.15),
      disabledColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      labelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: colorScheme.primary,
      ),
      brightness: Theme.of(context).brightness,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: colorScheme.outline.withValues(alpha: 0.2),
          width: 1.0,
        ),
      ),
    );
  }

  /// Card decoration with accent border (for feature cards)
  static BoxDecoration accentCardDecoration(
    BuildContext context, {
    Color? accentColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = accentColor ?? colorScheme.primary;
    return BoxDecoration(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(_largeBorderRadius),
      boxShadow: [
        BoxShadow(
          color: theme.shadowColor.withValues(alpha: _shadowAlpha),
          blurRadius: _shadowBlurRadius,
          spreadRadius: _shadowSpreadRadius,
          offset: _shadowOffset,
        ),
      ],
      border: Border.all(color: accent.withValues(alpha: 0.12), width: 1.0),
    );
  }

  /// Container with consistent border styling
  static BoxDecoration borderedContainer(
    BuildContext context, {
    Color? backgroundColor,
    BorderStyle borderStyle = BorderStyle.solid,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: backgroundColor ?? colorScheme.surface,
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: colorScheme.outline.withValues(alpha: 0.2),
        width: 1.0,
        style: borderStyle,
      ),
    );
  }

  /// Info/Alert container styling
  static BoxDecoration infoContainerDecoration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: colorScheme.primary.withValues(alpha: 0.2),
        width: 1.0,
      ),
    );
  }

  /// Warning/Alert container styling
  static BoxDecoration warningContainerDecoration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.tertiary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: colorScheme.tertiary.withValues(alpha: 0.2),
        width: 1.0,
      ),
    );
  }

  /// Error/Destructive container styling
  static BoxDecoration errorContainerDecoration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.error.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: colorScheme.error.withValues(alpha: 0.2),
        width: 1.0,
      ),
    );
  }

  /// Success container styling
  static BoxDecoration successContainerDecoration(BuildContext context) {
    final semantic = SemanticColors.of(context);
    return BoxDecoration(
      color: semantic.successContainer,
      borderRadius: BorderRadius.circular(_mediumBorderRadius),
      border: Border.all(
        color: semantic.success.withValues(alpha: 0.35),
        width: 1.0,
      ),
    );
  }
}
