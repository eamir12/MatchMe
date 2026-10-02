# Theme Dropdown Styling & Translation Standardization

## Summary
Fixed the Theme dropdown styling to match the Units and Time Format dropdowns, and standardized all "System default" translations across all three dropdowns in English, Spanish, and Hebrew.

## Changes Made

### 1. **Theme Dropdown Styling Fix**
**File**: `lib/screens/settings/settings_screen.dart` (lines 1006-1033)

**Before**: Theme dropdown was missing `enabledBorder` and `focusedBorder` styling
```dart
decoration: InputDecoration(
  labelText: l10n.getString('settingsThemeMode'),
  prefixIcon: Icon(Icons.dark_mode_outlined, color: colors.primary),
  border: OutlineInputBorder(...),
  filled: true,
  fillColor: colors.surface,
),
```

**After**: Theme dropdown now has consistent styling with Units and Time Format dropdowns
```dart
decoration: InputDecoration(
  labelText: l10n.getString('settingsThemeMode'),
  prefixIcon: Icon(Icons.dark_mode_outlined, color: colors.primary),
  border: OutlineInputBorder(...),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: theme.dividerColor),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: colors.primary, width: 2),
  ),
  filled: true,
  fillColor: colors.surface,
),
```

**Result**: Theme dropdown now has:
- ✅ Consistent border styling with other dropdowns
- ✅ Proper focus state with primary color border (2px width)
- ✅ Enabled state with divider color border
- ✅ Matches the visual appearance of Units and Time Format dropdowns

### 2. **Translation Standardization**
**File**: `standardize_system_default_translations.sql`

All three dropdowns now use consistent wording: **"System default"**

#### English
- `settingsUnitsSystem`: "System default"
- `settingsTimeFormatSystem`: "System default"
- `settingsThemeModeSystem`: "System default"

#### Spanish
- `settingsUnitsSystem`: "Predeterminado del sistema"
- `settingsTimeFormatSystem`: "Predeterminado del sistema"
- `settingsThemeModeSystem`: "Predeterminado del sistema"

#### Hebrew
- `settingsUnitsSystem`: "ברירת מחדל של המערכת"
- `settingsTimeFormatSystem`: "ברירת מחדל של המערכת"
- `settingsThemeModeSystem`: "ברירת מחדל של המערכת"

### 3. **Code Fallback (English)**
**File**: `lib/providers/locale_provider.dart` (line 388, 722, 726)

The English fallback translations in the code already use "System default" consistently:
```dart
'settingsThemeModeSystem': 'System default',
'settingsUnitsSystem': 'System default',
'settingsTimeFormatSystem': 'System default',
```

## Compilation Status
✅ **All files compile without errors**
- `settings_screen.dart`: No issues found

## Visual Result
All three dropdowns in the App Display section now have:
- ✅ Consistent border styling
- ✅ Matching focus states
- ✅ Unified "System default" wording across all languages
- ✅ Professional, modern appearance

## Next Steps
1. Run the SQL migration: `standardize_system_default_translations.sql`
2. Run the app to verify all three dropdowns display with consistent styling and wording:
   ```bash
   flutter run
   ```
3. Test in English, Spanish, and Hebrew to confirm translations are applied

## Files Modified
1. `lib/screens/settings/settings_screen.dart` - Theme dropdown styling
2. `standardize_system_default_translations.sql` - Translation updates (new file)
