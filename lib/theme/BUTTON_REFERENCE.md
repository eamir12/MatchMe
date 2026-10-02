# Button Style Reference

Quick reference for all available button styles in the application.

## Button Types at a Glance

### 1. Primary Button
**Use for**: Main actions, save, confirm, enable
```dart
ElevatedButton(
  style: AppButtonStyles.primaryButton(context),
  onPressed: () => {},
  child: Text('Save'),
)
```
- Color: Primary (usually blue)
- Elevation: None
- Border Radius: 12px

### 2. Secondary Button
**Use for**: Cancel, back, alternative actions
```dart
OutlinedButton(
  style: AppButtonStyles.secondaryButton(context),
  onPressed: () => {},
  child: Text('Cancel'),
)
```
- Color: Outline (usually gray)
- Border: 1px solid
- Border Radius: 12px

### 3. Destructive Button
**Use for**: Delete, remove, disable
```dart
ElevatedButton(
  style: AppButtonStyles.destructiveButton(context),
  onPressed: () => {},
  child: Text('Delete'),
)
```
- Color: Error (usually red)
- Elevation: None
- Border Radius: 12px

### 4. Success Button
**Use for**: Confirm positive action, enable feature
```dart
ElevatedButton(
  style: AppButtonStyles.successButton(context),
  onPressed: () => {},
  child: Text('Enable'),
)
```
- Color: Green (#10B981)
- Elevation: None
- Border Radius: 12px

### 5. Tertiary Button
**Use for**: Less prominent actions, dialog buttons
```dart
TextButton(
  style: AppButtonStyles.tertiaryButton(context),
  onPressed: () => {},
  child: Text('More Info'),
)
```
- Color: Primary (text only)
- No background or border
- Minimal visual weight

### 6. Small Primary Button
**Use for**: Compact layouts, small screens
```dart
ElevatedButton(
  style: AppButtonStyles.smallPrimaryButton(context),
  onPressed: () => {},
  child: Text('Action'),
)
```
- Smaller padding and font size
- Same color as primary button

### 7. Small Secondary Button
**Use for**: Compact layouts, small screens
```dart
OutlinedButton(
  style: AppButtonStyles.smallSecondaryButton(context),
  onPressed: () => {},
  child: Text('Cancel'),
)
```
- Smaller padding and font size
- Same styling as secondary button

## Button with Icons

All button types support icons:

```dart
ElevatedButton.icon(
  style: AppButtonStyles.primaryButton(context),
  icon: Icon(Icons.save, size: AppButtonStyles.getIconSize(context)),
  label: Text('Save'),
  onPressed: () => {},
)
```

### Icon Sizing
- Use `AppButtonStyles.getIconSize(context)` for responsive sizing
- Returns 20px on large screens, 16px on small screens

## Common Patterns

### Dialog Actions
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

### Destructive Dialog
```dart
AlertDialog(
  title: Text('Delete Item?'),
  content: Text('This cannot be undone.'),
  actions: [
    TextButton(
      style: AppButtonStyles.tertiaryButton(context),
      onPressed: () => Navigator.pop(context),
      child: Text('Cancel'),
    ),
    ElevatedButton(
      style: AppButtonStyles.destructiveButton(context),
      onPressed: () => _delete(),
      child: Text('Delete'),
    ),
  ],
)
```

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
    const SizedBox(width: 12),
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

### Button Column
```dart
Column(
  children: [
    SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: AppButtonStyles.primaryButton(context),
        onPressed: () => _action1(),
        child: Text('Primary Action'),
      ),
    ),
    const SizedBox(height: 12),
    SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: AppButtonStyles.secondaryButton(context),
        onPressed: () => _action2(),
        child: Text('Secondary Action'),
      ),
    ),
  ],
)
```

### Icon Button
```dart
IconButton(
  style: AppButtonStyles.iconButton(context),
  icon: Icon(Icons.settings),
  onPressed: () => _openSettings(),
)
```

## Disabled State

All buttons automatically handle disabled state:

```dart
ElevatedButton(
  style: AppButtonStyles.primaryButton(context),
  onPressed: isLoading ? null : () => _save(),  // null = disabled
  child: Text('Save'),
)
```

## Loading State

For buttons with loading indicators:

```dart
ElevatedButton(
  style: AppButtonStyles.primaryButton(context),
  onPressed: isLoading ? null : () => _save(),
  child: isLoading
      ? const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Text('Save'),
)
```

## Responsive Behavior

Buttons automatically adapt to screen size:

```dart
// Icon size changes based on screen width
Icon(Icons.save, size: AppButtonStyles.getIconSize(context))

// Button alignment changes based on screen width
alignment: AppButtonStyles.getButtonAlignment(context)
```

## Color Customization

If you need a custom color button, create a new method in `AppButtonStyles`:

```dart
static ButtonStyle customButton(BuildContext context, Color color) {
  return ElevatedButton.styleFrom(
    backgroundColor: color,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(
      vertical: _buttonPaddingVertical,
      horizontal: _buttonPaddingHorizontal,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_buttonBorderRadius),
    ),
    elevation: 0,
    textStyle: const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );
}
```

## Accessibility

All buttons follow accessibility best practices:
- Minimum touch target: 48x48 pixels
- Sufficient color contrast (WCAG AA)
- Clear visual hierarchy
- Semantic button types
- Proper focus states

## Troubleshooting

### Button text is cut off
- Wrap button in `Expanded` or `SizedBox` with width
- Check text length and consider abbreviating

### Button looks wrong
- Verify you're using the correct button style
- Check that context is passed correctly
- Ensure theme is applied to widget tree

### Icon not showing
- Use `AppButtonStyles.getIconSize(context)` for sizing
- Verify icon is imported correctly
- Check icon color matches button style

### Button not responding to taps
- Verify `onPressed` is not null
- Check that button is not disabled
- Ensure button is not covered by another widget

## Best Practices

1. ✅ Use semantic button types (destructive for delete, success for enable)
2. ✅ Use `AppButtonStyles.getIconSize(context)` for responsive icons
3. ✅ Wrap buttons in `Expanded` for full-width buttons
4. ✅ Use `const SizedBox` for spacing between buttons
5. ✅ Use `AppComponentStyles.spacing*` constants for spacing
6. ✅ Test buttons on different screen sizes
7. ✅ Verify color contrast meets accessibility standards

## Don'ts

1. ❌ Don't use inline `styleFrom()` calls
2. ❌ Don't hardcode colors (use theme colors)
3. ❌ Don't hardcode padding or border radius
4. ❌ Don't use different button styles for the same action
5. ❌ Don't forget to pass `context` to style methods
6. ❌ Don't use destructive button for non-destructive actions
7. ❌ Don't forget to handle disabled state

## Examples by Screen

### Settings Screen
- Primary: Save changes
- Secondary: Cancel
- Destructive: Delete account
- Success: Enable feature

### Security Center
- Primary: Enable MFA
- Secondary: Refresh recovery codes
- Destructive: Disable MFA
- Tertiary: More info

### Email Change
- Primary: Verify email
- Secondary: Cancel
- Tertiary: Back

### Invisibility Rules
- Primary: Create rule
- Secondary: Edit rule
- Destructive: Delete rule
- Tertiary: Cancel

## Version History

- **v1.0** - Initial standardized button system
  - 7 button types
  - Responsive sizing
  - Accessibility built-in
  - Comprehensive documentation
