# UI Styling Quick Reference Card

## Buttons

```dart
// Primary (main CTA)
ElevatedButton(
  style: AppButtonStyles.primaryButton(context),
  onPressed: () => {},
  child: Text('Save'),
)

// Secondary (alternative)
OutlinedButton(
  style: AppButtonStyles.secondaryButton(context),
  onPressed: () => {},
  child: Text('Cancel'),
)

// Destructive (delete/remove)
ElevatedButton(
  style: AppButtonStyles.destructiveButton(context),
  onPressed: () => {},
  child: Text('Delete'),
)

// Success (enable/confirm)
ElevatedButton(
  style: AppButtonStyles.successButton(context),
  onPressed: () => {},
  child: Text('Enable'),
)

// Tertiary (less prominent)
TextButton(
  style: AppButtonStyles.tertiaryButton(context),
  onPressed: () => {},
  child: Text('More Info'),
)

// Input (time, date, file)
OutlinedButton.icon(
  style: AppButtonStyles.inputButton(context),
  icon: Icon(Icons.access_time),
  label: Text('Select Time'),
  onPressed: () => {},
)
```

## Borders

```dart
// Standard border (20% opacity)
border: AppComponentStyles.standardBorder(context)

// Subtle border (12% opacity)
border: AppComponentStyles.subtleBorder(context)

// Accent border (primary color)
border: AppComponentStyles.accentBorder(context)

// Border radius
borderRadius: AppComponentStyles.cardBorderRadius()      // 16px
borderRadius: AppComponentStyles.buttonBorderRadius()    // 12px
borderRadius: AppComponentStyles.smallBorderRadius()     // 8px
```

## Cards & Containers

```dart
// Standard card with shadow
decoration: AppComponentStyles.cardDecoration(context)

// Card with border
decoration: AppComponentStyles.cardDecorationWithBorder(context)

// Feature card with accent border
decoration: AppComponentStyles.accentCardDecoration(context)

// Info container
decoration: AppComponentStyles.infoContainerDecoration(context)

// Warning container
decoration: AppComponentStyles.warningContainerDecoration(context)

// Error container
decoration: AppComponentStyles.errorContainerDecoration(context)

// Success container
decoration: AppComponentStyles.successContainerDecoration(context)

// Bordered container
decoration: AppComponentStyles.borderedContainer(context)
```

## Chips

```dart
// ChoiceChip (single selection)
ChipTheme(
  data: AppComponentStyles.choiceChipTheme(context),
  child: ChoiceChip(
    label: Text('Option'),
    selected: isSelected,
    onSelected: (selected) => {},
  ),
)

// FilterChip (multiple selection)
ChipTheme(
  data: AppComponentStyles.filterChipTheme(context),
  child: FilterChip(
    label: Text('Filter'),
    selected: isSelected,
    onSelected: (selected) => {},
  ),
)
```

## Text Styles

```dart
// Section header
style: AppComponentStyles.sectionHeaderStyle(context)

// Subtitle
style: AppComponentStyles.subtitleStyle(context)

// Helper text
style: AppComponentStyles.helperTextStyle(context)

// Error text
style: AppComponentStyles.errorTextStyle(context)

// Success text
style: AppComponentStyles.successTextStyle(context)
```

## Spacing

```dart
const double spacing2 = 4.0;    // Minimal
const double spacing4 = 8.0;    // Small
const double spacing6 = 12.0;   // Standard
const double spacing8 = 16.0;   // Standard padding
const double spacing10 = 20.0;  // Large
const double spacing12 = 24.0;  // Extra large

// Usage
SizedBox(height: AppComponentStyles.spacing8)
```

## Input Fields

```dart
TextField(
  decoration: AppComponentStyles.inputDecoration(
    context,
    labelText: 'Email',
    hintText: 'Enter email',
    prefixIcon: Icon(Icons.email),
  ),
)
```

## Dividers

```dart
AppComponentStyles.divider(context)
```

## Common Patterns

### Button Row
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
        onPressed: () => _save(),
        child: Text('Save'),
      ),
    ),
  ],
)
```

### Dialog with Actions
```dart
AlertDialog(
  title: Text('Confirm'),
  content: Text('Are you sure?'),
  actions: [
    TextButton(
      style: AppButtonStyles.tertiaryButton(context),
      onPressed: () => Navigator.pop(context),
      child: Text('Cancel'),
    ),
    ElevatedButton(
      style: AppButtonStyles.primaryButton(context),
      onPressed: () => _confirm(),
      child: Text('Confirm'),
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
            Text('Title', style: AppComponentStyles.sectionHeaderStyle(context)),
            Text('Subtitle', style: AppComponentStyles.subtitleStyle(context)),
          ],
        ),
      ),
    ],
  ),
)
```

### Info Container
```dart
Container(
  padding: const EdgeInsets.all(AppComponentStyles.spacing8),
  decoration: AppComponentStyles.infoContainerDecoration(context),
  child: Row(
    children: [
      Icon(Icons.info_outline),
      const SizedBox(width: AppComponentStyles.spacing6),
      Expanded(
        child: Text(
          'Information message',
          style: AppComponentStyles.helperTextStyle(context),
        ),
      ),
    ],
  ),
)
```

## Color Reference

### Semantic Colors
- `colorScheme.primary` - Main brand color
- `colorScheme.secondary` - Complementary color
- `colorScheme.tertiary` - Accent color
- `colorScheme.error` - Destructive actions
- `colorScheme.surface` - Backgrounds
- `colorScheme.onSurface` - Text on surface

### Alpha Values
- `0.08` - Subtle shadow
- `0.12` - Subtle border
- `0.15` - Chip selected
- `0.20` - Standard border
- `0.40` - Container background
- `0.70` - Text/icon

## Icon Sizing

```dart
// Responsive icon size
Icon(Icons.save, size: AppButtonStyles.getIconSize(context))
// Returns 20px on large screens, 16px on small screens
```

## Button Alignment

```dart
// Responsive button alignment
alignment: AppButtonStyles.getButtonAlignment(context)
// Returns center on small screens, centerLeft on large screens
```

## Don'ts ❌

- ❌ Don't use inline `styleFrom()` calls
- ❌ Don't hardcode colors
- ❌ Don't hardcode padding/border radius
- ❌ Don't use different styles for same action
- ❌ Don't forget to pass `context`
- ❌ Don't use destructive button for non-destructive actions
- ❌ Don't forget disabled state handling

## Do's ✅

- ✅ Use semantic button types
- ✅ Use `AppButtonStyles` for all buttons
- ✅ Use `AppComponentStyles` for containers
- ✅ Use predefined text styles
- ✅ Use spacing constants
- ✅ Use theme colors
- ✅ Test on multiple screen sizes
- ✅ Verify color contrast

## Files

- `lib/theme/app_button_styles.dart` - Button styles
- `lib/theme/app_component_styles.dart` - Component styles
- `lib/theme/STYLING_GUIDE.md` - Full guide
- `lib/theme/BUTTON_REFERENCE.md` - Button reference
- `lib/theme/QUICK_REFERENCE.md` - This file
