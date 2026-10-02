# Security Center Screen - RTL Compliance Analysis

## Overview
The Security Center screen has multiple RTL (Right-to-Left) language compliance issues that need to be addressed. The app supports Hebrew (he) with RTL text direction, but several UI components don't properly respect RTL layout.

## Critical RTL Issues Found

### 1. **Button Alignment Issues** (HIGH PRIORITY)
**Location:** Multiple button implementations throughout the screen
**Problem:** All buttons use hardcoded `alignment: Alignment.centerLeft`

```dart
// CURRENT (WRONG FOR RTL):
FilledButton.icon(
  style: FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: Alignment.centerLeft,  // ❌ Hardcoded LTR alignment
  ),
  ...
)
```

**Affected Buttons:**
- MFA Enable button (line ~1210)
- Recovery Codes button (line ~1220)
- Disable MFA button (line ~1230)
- Add Passkey button (line ~1380)
- Remove All Passkeys button (line ~1400)
- Copy Secret button (line ~2160)
- Open Authenticator button (line ~2130)
- Verify button in MFA dialog (line ~2220)

**Impact:** In RTL mode, button icons appear on the right side with text on the left, which is backwards from the natural RTL flow.

**Fix:** Use `Directionality.of(context).textDirection == TextDirection.rtl` to determine alignment dynamically.

---

### 2. **Row Layout Issues** (HIGH PRIORITY)
**Location:** Multiple Row widgets with `crossAxisAlignment: CrossAxisAlignment.start`

**Problem Areas:**
- `_buildMetric()` function (line 903): Icon + label + value layout
- `_SecurityFeatureCard` header (line 1620): Icon + title + status badge
- `_buildAuthenticatorCard` email container (line 1140): Icon + email text
- `_buildPasskeyCard` session info (line 1340): Icon + session text
- Offline banner (line 1430): Icon + text

**Issue:** Using `crossAxisAlignment.start` doesn't account for RTL text direction. In RTL, content should flow from right to left.

**Example:**
```dart
// CURRENT (WRONG FOR RTL):
Row(
  children: [
    Icon(...),  // Always on left
    const SizedBox(width: 10),
    Expanded(child: Text(...)),  // Always on right
  ],
)
```

---

### 3. **Icon Positioning in Badges** (MEDIUM PRIORITY)
**Location:** `_SecurityBadge` widget (line 1700)

**Problem:** Status badge has icon before text, which may need mirroring in RTL

```dart
// CURRENT:
Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Icon(icon, color: color, size: 16),  // Always on left
    const SizedBox(width: 6),
    Text(label, ...),  // Always on right
  ],
)
```

---

### 4. **Dialog Button Order** (MEDIUM PRIORITY)
**Location:** Multiple AlertDialog implementations

**Affected Dialogs:**
- Passkey revocation confirmation (line ~1000)
- MFA disable confirmation (line ~1050)
- Recovery codes regeneration (line ~1000)
- MFA enrollment dialog (line ~2200)
- Recovery codes display dialog (line ~1850)

**Problem:** Button order (Cancel/Confirm) should be reversed in RTL mode. In RTL, the primary action should be on the left.

**Current Pattern:**
```dart
actions: [
  TextButton(onPressed: () => Navigator.pop(dialogContext, false), ...),  // Cancel
  ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), ...),  // Confirm
]
```

In RTL, Confirm should appear first (on the left).

---

### 5. **Text Direction Not Specified** (MEDIUM PRIORITY)
**Location:** Multiple text widgets

**Affected Components:**
- `SelectableText` for recovery codes (line 1850)
- `SelectableText` for secret key (line 2150)
- `TextFormField` for MFA code (line 2170)
- Email display in authenticator card (line 1140)

**Problem:** No explicit `textDirection` parameter, relies on parent context.

---

### 6. **Offline Banner Layout** (LOW PRIORITY)
**Location:** `_buildOfflineBanner()` (line 1430)

**Problem:** Icon on left, text on right - should be mirrored in RTL

```dart
// CURRENT:
Row(
  children: [
    Icon(Icons.wifi_off_rounded, ...),  // Always on left
    const SizedBox(width: 10),
    Expanded(child: Text(...)),  // Always on right
  ],
)
```

---

### 7. **Metric Cards Layout** (LOW PRIORITY)
**Location:** `_buildMetric()` function (line 903)

**Problem:** Icon always on top, text below - this is OK for RTL, but the container itself should respect RTL padding/margins.

---

## Recommended Fixes

### Fix 1: Create RTL-Aware Button Alignment Helper
```dart
Alignment _getButtonAlignment(BuildContext context) {
  final isRtl = Directionality.of(context) == TextDirection.rtl;
  return isRtl ? Alignment.centerRight : Alignment.centerLeft;
}
```

Then use:
```dart
FilledButton.icon(
  style: FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: _getButtonAlignment(context),  // ✅ Dynamic
  ),
  ...
)
```

### Fix 2: Use `mainAxisAlignment` in Row Layouts
```dart
Row(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,  // Better for RTL
  children: [
    Icon(...),
    Expanded(child: Text(...)),
  ],
)
```

Or wrap with `Directionality` if needed:
```dart
Directionality(
  textDirection: TextDirection.ltr,  // Force LTR if needed
  child: Row(...),
)
```

### Fix 3: Reverse Dialog Button Order for RTL
```dart
final isRtl = Directionality.of(context) == TextDirection.rtl;
final actions = [
  TextButton(...),  // Cancel
  ElevatedButton(...),  // Confirm
];

actions: isRtl ? actions.reversed.toList() : actions,
```

### Fix 4: Add Explicit Text Direction to Text Widgets
```dart
SelectableText(
  code,
  textDirection: TextDirection.ltr,  // For codes/secrets
  ...
)
```

### Fix 5: Wrap Icon+Text Rows with Directionality
```dart
Directionality(
  textDirection: Directionality.of(context).textDirection,
  child: Row(
    children: [Icon(...), Text(...)],
  ),
)
```

---

## Testing Checklist

- [ ] Test all buttons in Hebrew (RTL) mode
- [ ] Verify button icons appear on correct side
- [ ] Check dialog button order in RTL
- [ ] Test email masking display in RTL
- [ ] Verify recovery codes display in RTL
- [ ] Check offline banner layout in RTL
- [ ] Test metric cards alignment in RTL
- [ ] Verify status badges in RTL
- [ ] Check all text alignment in RTL mode
- [ ] Test on both Android and iOS in RTL

---

## Summary

**Total Issues Found:** 7 categories
- **HIGH:** 2 (Button alignment, Row layouts)
- **MEDIUM:** 3 (Badge icons, Dialog buttons, Text direction)
- **LOW:** 2 (Offline banner, Metric cards)

**Affected Components:**
- 5+ buttons with hardcoded LTR alignment
- 6+ Row layouts not respecting RTL
- 5+ dialogs with incorrect button order
- 4+ text widgets without explicit direction
- 1 offline banner with LTR-only layout

**Estimated Fix Time:** 2-3 hours for comprehensive RTL support
