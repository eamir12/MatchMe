import 'package:flutter/material.dart';
import 'package:matchme/utils/directional_icons.dart';

/// Standardized card styling for settings menu items and other cards
/// Ensures visual consistency across all cards in the application
class AppCardStyles {
  // Card styling constants
  static const double _cardBorderRadius = 16.0;
  static const double _iconContainerRadius = 12.0;
  static const double _cardPadding = 16.0;
  static const double _iconPadding = 12.0;
  static const double _iconSize = 28.0;

  /// Standard settings menu card - uses primary color with gradient
  /// Use for main feature cards (Gender & Age, Invisibility, etc.)
  static BoxDecoration standardMenuCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      gradient: LinearGradient(
        colors: [
          colorScheme.primary.withValues(alpha: 0.08),
          colorScheme.primary.withValues(alpha: 0.03),
        ],
      ),
      borderRadius: BorderRadius.circular(_cardBorderRadius),
      border: Border.all(
        color: colorScheme.primary.withValues(alpha: 0.15),
        width: 1.0,
      ),
    );
  }

  /// Solid card without gradient - for simpler styling
  static BoxDecoration solidMenuCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.primary.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(_cardBorderRadius),
      border: Border.all(
        color: colorScheme.primary.withValues(alpha: 0.15),
        width: 1.0,
      ),
    );
  }

  /// Icon container decoration for menu cards
  static BoxDecoration iconContainer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: colorScheme.primary.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(_iconContainerRadius),
    );
  }

  /// Get text color for card title (uses primary color)
  static Color cardTitleColor(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  /// Get text color for card subtitle
  static Color cardSubtitleColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return colorScheme.onSurface.withValues(alpha: 0.7);
  }

  /// Get icon color for card (uses primary color)
  static Color cardIconColor(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  /// Get arrow icon color for card
  static Color cardArrowColor(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  /// Standard card padding
  static const EdgeInsets cardPadding = EdgeInsets.all(_cardPadding);

  /// Standard icon container padding
  static const EdgeInsets iconContainerPadding = EdgeInsets.all(_iconPadding);

  /// Standard icon size
  static const double iconSize = _iconSize;

  /// Standard border radius
  static const double borderRadius = _cardBorderRadius;

  /// Standard icon container border radius
  static const double iconBorderRadius = _iconContainerRadius;

  /// Title text style for menu cards
  static TextStyle cardTitleStyle(BuildContext context) {
    return TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: cardTitleColor(context),
    );
  }

  /// Subtitle text style for menu cards
  static TextStyle cardSubtitleStyle(BuildContext context) {
    return TextStyle(fontSize: 14, color: cardSubtitleColor(context));
  }

  /// Build a standard menu card
  ///
  /// Example:
  /// ```dart
  /// AppCardStyles.buildMenuCard(
  ///   context: context,
  ///   icon: Icons.people_alt_outlined,
  ///   title: 'Gender & Age Preferences',
  ///   subtitle: 'Choose which genders and age ranges you want to match with.',
  ///   onTap: () => Navigator.push(...),
  /// )
  /// ```
  static Widget buildMenuCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          padding: cardPadding,
          decoration: standardMenuCard(context),
          child: Row(
            children: [
              Container(
                padding: iconContainerPadding,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(iconBorderRadius),
                ),
                child: Icon(
                  icon,
                  color: cardIconColor(context),
                  size: iconSize,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: cardTitleStyle(context)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: cardSubtitleStyle(context)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
                Icon(
                  directionalForwardIos(context),
                  color: cardArrowColor(context),
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
