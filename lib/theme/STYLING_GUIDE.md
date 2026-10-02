# UI Styling Guide

This document outlines the standardized UI styling system for the application. All screens, especially settings screens, should follow these guidelines to maintain visual consistency.

## Overview

The styling system is divided into two main files:
- **`app_button_styles.dart`** - Centralized button styling
- **`app_component_styles.dart`** - Component styling (cards, containers, text styles, etc.)

## Button Styles

### Available Button Types

#### 1. Primary Button
Used for main calls-to-action (CTAs).
```dart
ElevatedButton(
  style: AppButtonStyles.primaryButton(context),
  onPressed: () => {},
  child: Text('Save'),
)
```
- **Color**: Primary color from theme
- **Elevation**: None (flat design)
- **Border Radius**: 12px
- **Padding**: 12px vertical, 16px horizontal

#### 2. Secondary Button
Used for alternative actions or less prominent CTAs.
```dart
OutlinedButton(
  style: AppButtonStyles.secondaryButton(context),
  onPressed: () => {},
  child: Text('Cancel'),
)
```
- **Color**: Outline color from theme
- **Border**: 1px solid outline
- **Border Radius**: 12px
- **Padding**: 12px vertical, 16px horizontal

#### 3. Destructive Button
Used for delete, remove, or other destructive actions.
```dart
ElevatedButton(
  style: AppButtonStyles.destructiveButton(context),
  onPressed: () => {},
  child: Text('Delete'),
)
```
- **Color**: Error color from theme
- **Elevation**: None (flat design)
- **Border Radius**: 12px
- **Padding**: 12px vertical, 16px horizontal

#### 4. Success Button
Used for confirm, enable, or positive actions.
```dart
ElevatedButton(
  style: AppButtonStyles.successButton(context),
  onPressed: () => {},
  child: Text('Enable'),
)
```
- **Color**: Modern green (#10B981)
- **Elevation**: None (flat design)
- **Border Radius**: 12px
- **Padding**: 12px vertical, 16px horizontal

#### 5. Tertiary Button
Used for less prominent actions (typically in dialogs).
```dart
TextButton(
  style: AppButtonStyles.tertiaryButton(context),
  onPressed: () => {},
  child: Text('More Info'),
)
```
- **Color**: Primary color from theme
- **No background or border**
- **Padding**: 12px vertical, 16px horizontal

#### 6. Small Button Variants
For compact layouts or smaller screens.
```dart
ElevatedButton(
  style: AppButtonStyles.smallPrimaryButton(context),
  onPressed: () => {},
  child: Text('Action'),
)
```
- **Padding**: 8px vertical, 12px horizontal
- **Font Size**: 12px (vs 14px for regular)

### Button with Icons

All button types support icons. Use `AppButtonStyles.getIconSize(context)` for responsive icon sizing:

```dart
ElevatedButton.icon(
  style: AppButtonStyles.primaryButton(context),
  icon: Icon(Icons.save, size: AppButtonStyles.getIconSize(context)),
  label: Text('Save'),
  onPressed: () => {},
)
```

## Component Styles

### Card Decoration
For elevated cards with subtle shadows:
```dart
Container(
  decoration: AppComponentStyles.cardDecoration(context),
  child: // content
)
```

### Card with Border
For cards with borders instead of shadows:
```dart
Container(
  decoration: AppComponentStyles.cardDecorationWithBorder(context),
  child: // content
)
```

### Container Decoration
For grouped content sections:
```dart
Container(
  decoration: AppComponentStyles.containerDecoration(context),
  child: // content
)
```

### Icon Container
For accent icons with background:
```dart
Container(
  padding: const EdgeInsets.all(10),
  decoration: AppComponentStyles.iconContainerDecoration(context),
  child: Icon(Icons.shield, color: Theme.of(context).colorScheme.primary),
)
```

### Text Styles

#### Section Header
```dart
Text(
  'Settings',
  style: AppComponentStyles.sectionHeaderStyle(context),
)
```

#### Subtitle
```dart
Text(
  'Manage your account',
  style: AppComponentStyles.subtitleStyle(context),
)
```

#### Helper Text
```dart
Text(
  'This action cannot be undone',
  style: AppComponentStyles.helperTextStyle(context),
)
```

#### Error Text
```dart
Text(
  'An error occurred',
  style: AppComponentStyles.errorTextStyle(context),
)
```

#### Success Text
```dart
Text(
  'Changes saved',
  style: AppComponentStyles.successTextStyle(context),
)
```

### Spacing Constants

Use these predefined spacing values for consistency:
```dart
AppComponentStyles.spacing2   // 4px
AppComponentStyles.spacing4   // 8px
AppComponentStyles.spacing6   // 12px
AppComponentStyles.spacing8   // 16px
AppComponentStyles.spacing10  // 20px
AppComponentStyles.spacing12  // 24px
```

### Input Field Decoration
```dart
TextField(
  decoration: AppComponentStyles.inputDecoration(
    context,
    labelText: 'Email',
    hintText: 'Enter your email',
    prefixIcon: Icon(Icons.email),
  ),
)
```

### Divider
```dart
AppComponentStyles.divider(context)
```

## Color Palette

The system uses the Material 3 color scheme from the theme:
- **Primary**: Main brand color
- **Secondary**: Complementary color
- **Tertiary**: Accent color
- **Error**: For destructive actions
- **Surface**: Background for cards and containers
- **OnSurface**: Text on surface backgrounds

## Border Radius Standards

- **Small**: 8px (for small elements)
- **Medium**: 12px (for buttons, input fields)
- **Large**: 16px (for cards, containers)

## Shadow Standards

- **Blur Radius**: 8px
- **Spread Radius**: 0px
- **Offset**: (0, 2)
- **Alpha**: 0.08 (8% opacity)

## Best Practices

1. **Always use the centralized styles** - Don't create inline `styleFrom()` calls
2. **Responsive sizing** - Use `AppButtonStyles.getIconSize(context)` for icons
3. **Consistent spacing** - Use `AppComponentStyles.spacing*` constants
4. **Color semantics** - Use destructive button for delete, success for enable, etc.
5. **Text styles** - Use predefined text styles for consistency
6. **Accessibility** - Ensure sufficient color contrast and touch targets (min 48px)

## Migration Guide

If you're updating existing code:

### Before
```dart
ElevatedButton(
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.red,
    foregroundColor: Colors.white,
    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  onPressed: () => {},
  child: Text('Delete'),
)
```

### After
```dart
ElevatedButton(
  style: AppButtonStyles.destructiveButton(context),
  onPressed: () => {},
  child: Text('Delete'),
)
```

## Examples

### Settings Screen Button Group
```dart
Row(
  children: [
    Expanded(
      child: OutlinedButton(
        style: AppButtonStyles.secondaryButton(context),
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'),
      ),
    ),
    const SizedBox(width: AppComponentStyles.spacing6),
    Expanded(
      child: ElevatedButton(
        style: AppButtonStyles.primaryButton(context),
        onPressed: () => _saveChanges(),
        child: Text('Save'),
      ),
    ),
  ],
)
```

### Dialog with Actions
```dart
AlertDialog(
  title: Text('Confirm Action'),
  content: Text('Are you sure?'),
  actions: [
    TextButton(
      style: AppButtonStyles.tertiaryButton(context),
      onPressed: () => Navigator.pop(context),
      child: Text('Cancel'),
    ),
    ElevatedButton(
      style: AppButtonStyles.destructiveButton(context),
      onPressed: () => _performAction(),
      child: Text('Delete'),
    ),
  ],
)
```

### Card with Icon
```dart
Container(
  padding: const EdgeInsets.all(AppComponentStyles.spacing8),
  decoration: AppComponentStyles.cardDecoration(context),
  child: Row(
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: AppComponentStyles.iconContainerDecoration(context),
        child: Icon(Icons.security),
      ),
      const SizedBox(width: AppComponentStyles.spacing6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Security', style: AppComponentStyles.sectionHeaderStyle(context)),
            Text('Manage your security settings', style: AppComponentStyles.subtitleStyle(context)),
          ],
        ),
      ),
    ],
  ),
)
```

## Troubleshooting

### Button text is cut off
- Ensure the button has enough width (use `Expanded` if needed)
- Check that the text isn't too long for the available space

### Colors don't match the theme
- Make sure you're using `Theme.of(context).colorScheme` colors
- Verify the theme is properly applied to the widget tree

### Spacing looks inconsistent
- Use the predefined `AppComponentStyles.spacing*` constants
- Avoid hardcoding pixel values

## Future Enhancements

Potential improvements to the styling system:
- Animation/transition styles
- Dark mode specific adjustments
- Accessibility-focused variants
- Responsive breakpoint helpers
