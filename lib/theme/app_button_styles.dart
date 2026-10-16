import 'package:flutter/material.dart';
import 'package:matchme/theme/semantic_colors.dart';

/// Centralized button styling for the application
/// Ensures consistency across all settings screens and the entire app
class AppButtonStyles {
  // Spacing constants
  static const double _buttonBorderRadius = 12.0;
  static const double _buttonPaddingVertical = 12.0;
  static const double _buttonPaddingHorizontal = 16.0;
  static const double _buttonIconSize = 20.0;
  static const double _smallButtonIconSize = 16.0;

  // Primary action button (main CTA)
  static ButtonStyle primaryButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ElevatedButton.styleFrom(
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      padding: const EdgeInsets.symmetric(
        vertical: _buttonPaddingVertical,
        horizontal: _buttonPaddingHorizontal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      elevation: 0,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  // Secondary action button (alternative CTA)
  static ButtonStyle secondaryButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton.styleFrom(
      foregroundColor: colorScheme.primary,
      side: BorderSide(color: colorScheme.outline, width: 1.0),
      padding: const EdgeInsets.symmetric(
        vertical: _buttonPaddingVertical,
        horizontal: _buttonPaddingHorizontal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  // Destructive action button (delete, remove, etc.)
  static ButtonStyle destructiveButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ElevatedButton.styleFrom(
      backgroundColor: colorScheme.error,
      foregroundColor: colorScheme.onError,
      padding: const EdgeInsets.symmetric(
        vertical: _buttonPaddingVertical,
        horizontal: _buttonPaddingHorizontal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      elevation: 0,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  // Success action button (confirm, enable, etc.)
  static ButtonStyle successButton(BuildContext context) {
    // Mode-aware success pair: light mode uses emerald-700 with white text
    // (5.4:1); dark mode uses emerald-400 with deep green text (7.9:1).
    final semantic = SemanticColors.of(context);
    return ElevatedButton.styleFrom(
      backgroundColor: semantic.success,
      foregroundColor: semantic.onSuccess,
      padding: const EdgeInsets.symmetric(
        vertical: _buttonPaddingVertical,
        horizontal: _buttonPaddingHorizontal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      elevation: 0,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  // Tertiary button (less prominent actions)
  static ButtonStyle tertiaryButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton.styleFrom(
      foregroundColor: colorScheme.primary,
      padding: const EdgeInsets.symmetric(
        vertical: _buttonPaddingVertical,
        horizontal: _buttonPaddingHorizontal,
      ),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  // Small button variant (for compact layouts)
  static ButtonStyle smallPrimaryButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ElevatedButton.styleFrom(
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      elevation: 0,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
  }

  // Small secondary button variant
  static ButtonStyle smallSecondaryButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton.styleFrom(
      foregroundColor: colorScheme.primary,
      side: BorderSide(color: colorScheme.outline, width: 1.0),
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
  }

  // Icon button styling
  static ButtonStyle iconButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton.styleFrom(
      foregroundColor: colorScheme.primary,
      padding: const EdgeInsets.all(8.0),
    );
  }

  // Input/Selection button (for time pickers, date pickers, etc.)
  static ButtonStyle inputButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton.styleFrom(
      foregroundColor: colorScheme.onSurface,
      side: BorderSide(
        color: colorScheme.outline.withValues(alpha: 0.3),
        width: 1.0,
      ),
      padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_buttonBorderRadius),
      ),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
  }

  // Get icon size based on screen size
  static double getIconSize(BuildContext context) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return isSmallScreen ? _smallButtonIconSize : _buttonIconSize;
  }

  // Get button alignment based on screen size
  static Alignment getButtonAlignment(BuildContext context) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return isSmallScreen ? Alignment.center : Alignment.centerLeft;
  }
}
