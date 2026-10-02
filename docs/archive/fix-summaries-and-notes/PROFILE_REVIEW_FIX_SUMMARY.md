# Profile Review Page Fix Summary

## Problem 1: Mixed Hebrew/English Text in Intents Section
The intent area in the Profile Edit Review page was displaying a messy mix of Hebrew and English text with duplicates:
- Example: "רומנטי - רומנטי, Romantic::casual"
- Hebrew translations were appearing alongside English fallback text
- Duplicate entries were showing up
- Sub-intents were not being properly translated

### Root Cause
The `_resolveDisplayLabel` method in `profile_wizard_screen.dart` had two issues:

#### Issue 1: Wrong Resolution Order
When processing composite keys like "romantic::casual":
1. The method would split the key into parts: left="romantic", right="casual"
2. It would resolve the left part correctly using `allIntentsMap`
3. **BUT** for the right part, it would check `interestKeyToDisplayKey` and `categoryKeyToDisplayKey` first
4. Since sub-intents are NOT interests or categories, these lookups failed
5. The method would fall back to `_humanizeKey(right)` which produces English text like "Casual"

#### Issue 2: No Direct Composite Key Lookup
The method never tried to look up the full composite key "romantic::casual" directly in `allIntentsMap` before splitting it, even though the database stores sub-intents with composite keys.

#### Issue 3: No Deduplication
The review page code didn't deduplicate resolved sub-intent labels, leading to duplicate entries when the same label was resolved multiple times.

### Solution for Problem 1

#### Fix 1: Prioritize Full Key Lookup
Modified `_resolveDisplayLabel` to try resolving the full composite key directly from `allIntentsMap` BEFORE attempting to split and resolve parts separately (lines 1947-1951):

```dart
// First, try to resolve the full key directly (works for both simple and composite keys)
if (allIntentsMap != null && allIntentsMap.containsKey(keyOrDisplay)) {
  final mapped = allIntentsMap[keyOrDisplay]!;
  final mappedLoc = _tryGetString(l10n, mapped);
  if (mappedLoc != null) return mappedLoc;
}
```

#### Fix 2: Check allIntentsMap for Sub-Intents
When splitting composite keys, added a check for `allIntentsMap` when resolving the right part, BEFORE checking interest and category maps (lines 1972-1977):

```dart
// First try allIntentsMap for the right part (it might be a sub-intent)
if (allIntentsMap != null) {
  final mappedIntent = allIntentsMap[right];
  if (mappedIntent != null && mappedIntent.isNotEmpty) {
    rightLocalized = _tryGetString(l10n, mappedIntent);
  }
}
```

#### Fix 3: Deduplicate Resolved Labels
Added `.toSet().toList()` to deduplicate resolved sub-intent labels in the review page display code (lines 4974-4982 and 5005-5013).

---

## Problem 2: Duplicate Interest Categories

Interests were being displayed multiple times in the review page because they are shared among the three personal intents (Romantic, Friendship, Activity Partner).

### Root Cause
When interests are stored in the profile, they use prefixed keys:
- "romantic::sports" → ["soccer", "basketball"]
- "friendship::sports" → ["soccer", "tennis"]  
- "activity::sports" → ["soccer"]

The review page was processing each prefixed key separately, resulting in "Sports" appearing three times with potentially different interest items under each.

### Solution for Problem 2

#### Fix 4: Merge Shared Intent Categories
Modified the interests processing logic to detect when a category belongs to a shared intent (Romantic, Friendship, or Activity Partner) and merge all instances into a single display entry (lines 5025-5105):

1. Added `isSharedIntent()` helper function to check if an intent is one of the three shared intents
2. For shared intents, strip the intent prefix and use only the category label as the map key
3. For non-shared intents (like Business/Networking), keep the full prefixed key to maintain separation
4. Use Set operations to prevent duplicate interest items when merging from multiple shared intent prefixes

```dart
bool isSharedIntent(String intentKey) {
  return _sharedIntents.contains(_normalizeKey(intentKey));
}

// When processing interests...
if (isSharedIntent(intentPrefix)) {
  // Strip the intent prefix for shared intents so they merge
  categoryLabel = catKey.isNotEmpty ? localResolve(categoryKeyToDisplayKey[catKey] ?? catKey) : formatPrefixedCategory(pref);
} else {
  categoryLabel = formatPrefixedCategory(pref);
}

// Use Set to prevent duplicates when merging
categoryToAddedSubs[categoryLabel] = (categoryToAddedSubs[categoryLabel]!.toSet()..addAll(subs)).toList();
```

### Result
Now interests shared among Romantic, Friendship, and Activity Partner appear only once in the review page:
- "ספורט: כדורגל, כדורסל, טניס" (Sports: Soccer, Basketball, Tennis) - appears once, not three times
- All interest items from all three intents are merged and deduplicated
- Non-shared interests (like Business interests) remain separated by intent

---

## Overall Result

The Profile Review page now displays:
- **Intents**: All text properly translated to Hebrew, no English fallbacks, no duplicates
- **Interests**: Shared categories appear once with merged interest items from all shared intents
- **Consistent formatting**: Matches the display from earlier selection pages
- **Clean presentation**: Professional, localized, and user-friendly

## Files Modified
- `lib/screens/profile/profile_wizard_screen.dart`
  - Lines 1938-2020: `_resolveDisplayLabel` method (intent translation fix)
  - Lines 4961-5025: Intent display logic in `_buildFinalReview` (deduplication)
  - Lines 5025-5105: Interest display logic in `_buildFinalReview` (shared interest merging)


---

## Problem 3: Sub-Intent Storage Format Inconsistency

### Issue
Sub-intents might be stored in the profile in two different formats:
1. **Without prefix**: `["casual", "long_term"]` under `subIntents["romantic"]`
2. **With prefix**: `["romantic::casual", "romantic::long_term"]` under `subIntents["romantic"]`

This inconsistency caused the code to blindly prepend the intent prefix, potentially creating invalid composite keys like `"romantic::romantic::casual"`.

### Solution (Lines 4974-4984, 5012-5022)
Added defensive logic to detect if sub-intent keys already contain the `::` prefix:

```dart
String fullKey;
if (s.contains('::')) {
  fullKey = s; // Already has prefix: "romantic::casual"
} else {
  fullKey = '$intent::$s'; // Add prefix: "casual" -> "romantic::casual"
}
```

This handles both storage formats correctly and prevents duplicate prefixing.

---

## Debugging Note

If you still see duplicate entries or the intent name appearing twice in the review (e.g., "רומנטי - רומנטי::קז'ואל"), this indicates a data consistency issue in the profile storage. The sub-intents might be stored with the full composite key including the parent intent name, which when resolved through `_resolveDisplayLabel`, displays both the parent and child parts.

To investigate further, check the actual values stored in:
- `profile.subIntents` map
- `diffs['subIntentsAdded']` and `diffs['subIntentsRemoved']` 

The fix now handles both cases, but if the issue persists, the data might need to be cleaned up in the database or during profile loading.
