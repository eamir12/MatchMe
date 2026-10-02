# Shared Interests Deduplication Fix

## The Problem

### Before Fix:
When a user selected interests across Romantic, Friendship, and Activity Partner intents, the review page showed duplicates:

```
Profile Review Page (BEFORE):

חומי עניין (Interests):
├─ ספורט: כדורגל, כדורסל                    ← From "romantic::sports"
├─ ספורט: כדורגל, טניס                       ← From "friendship::sports"  
├─ ספורט: כדורגל                             ← From "activity::sports"
├─ מוזיקה: רוק, ג'אז                         ← From "romantic::music"
├─ מוזיקה: ג'אז, קלאסי                       ← From "friendship::music"
└─ מוזיקה: רוק                               ← From "activity::music"
```

**Result**: User sees "Sports" 3 times and "Music" 3 times, which is confusing and cluttered.

---

## How Data is Stored

### Profile Structure:
```dart
profile.interests = {
  "romantic::sports": ["soccer", "basketball"],
  "friendship::sports": ["soccer", "tennis"],
  "activity::sports": ["soccer"],
  "romantic::music": ["rock", "jazz"],
  "friendship::music": ["jazz", "classical"],
  "activity::music": ["rock"],
}
```

### Why Prefixes Exist:
- The three personal intents (Romantic, Friendship, Activity Partner) SHARE the same interest categories
- When the user is on the Romantic intent page, they can select sports interests
- When they're on the Friendship intent page, they can select the SAME sports interests
- The system stores these separately with prefixes to track which intent-specific page the selection was made on
- **BUT** conceptually, these are the SAME interests shared across all three intents

---

## The Solution

### After Fix:
The review page now MERGES shared interest categories:

```
Profile Review Page (AFTER):

חומי עניין (Interests):
├─ ספורט: כדורגל, כדורסל, טניס              ← Merged from all 3 intents
└─ מוזיקה: רוק, ג'אז, קלאסי                 ← Merged from all 3 intents
```

**Result**: User sees each category once with ALL selected interests from all shared intents combined.

---

## How It Works

### Detection Logic:
```dart
bool isSharedIntent(String intentKey) {
  return _sharedIntents.contains(_normalizeKey(intentKey));
}

// _sharedIntents = { "romantic", "friendship", "activity" }
```

### Processing Logic:
```dart
interestsAdded.forEach((pref, interests) {
  final parts = pref.split('::');              // ["romantic", "sports"]
  final intentPrefix = parts[0];                // "romantic"
  final catKey = parts[1];                      // "sports"
  
  String categoryLabel;
  if (isSharedIntent(intentPrefix)) {
    // For shared intents: use ONLY the category name as the key
    // This causes "romantic::sports", "friendship::sports", "activity::sports" 
    // to all map to the same "Sports" category
    categoryLabel = localResolve(catKey);       // "ספורט" (Sports in Hebrew)
  } else {
    // For non-shared intents (business): keep the full prefixed key
    // This keeps business interests separate
    categoryLabel = formatPrefixedCategory(pref);
  }
  
  // Add interests to the merged category
  // Set operations prevent duplicates
  categoryToAddedSubs[categoryLabel] = 
    (categoryToAddedSubs[categoryLabel]!.toSet()..addAll(subs)).toList();
});
```

---

## Visual Flow

### Data Flow (BEFORE FIX):
```
Storage                  Processing              Display
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
romantic::sports    →    "Sports" (key1)    →    ספורט: ⚽🏀
friendship::sports  →    "Sports" (key2)    →    ספורט: ⚽🎾  
activity::sports    →    "Sports" (key3)    →    ספורט: ⚽
```

### Data Flow (AFTER FIX):
```
Storage                  Processing              Display
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
romantic::sports    ┐
friendship::sports  ├─→  "Sports" (single)  →   ספורט: ⚽🏀🎾
activity::sports    ┘    (merged + deduped)
```

---

## Edge Cases Handled

### 1. Different Interests in Same Category
```dart
// User selected different sports under different intents
"romantic::sports": ["soccer", "basketball"]
"friendship::sports": ["tennis", "swimming"]

// Result: Merged and combined
Display: "ספורט: כדורגל, כדורסל, טניס, שחייה"
```

### 2. Overlapping Interests
```dart
// User selected some same interests under different intents
"romantic::sports": ["soccer", "basketball"]
"friendship::sports": ["soccer", "tennis"]

// Result: Merged and deduplicated (soccer appears once)
Display: "ספורט: כדורגל, כדורסל, טניס"
```

### 3. Non-Shared Intents (Business)
```dart
// Business interests are NOT shared, so they stay separate
"business::networking": ["conferences", "workshops"]

// Result: Displayed with full context
Display: "עסקי - נטוורקינג: כנסים, סדנאות"
```

---

## Code Changes

### Location: `lib/screens/profile/profile_wizard_screen.dart`

**Lines 5027-5028**: Added `isSharedIntent()` helper function

**Lines 5042-5055**: Modified category label generation to strip intent prefix for shared intents

**Lines 5058-5061**: Changed from `.addAll()` to Set-based merging to prevent duplicates

**Lines 5073-5105**: Applied same logic to removed interests

---

## Testing Scenarios

1. ✅ Select same interest under all 3 shared intents → Shows once
2. ✅ Select different interests under different intents → Merged, no duplicates  
3. ✅ Select overlapping interests → Deduplicated correctly
4. ✅ Business interests → Remain separate from shared interests
5. ✅ Hebrew translation → All labels display in Hebrew
6. ✅ Empty categories → Handled gracefully

---

## Summary

**What Changed**: Interests shared among Romantic, Friendship, and Activity Partner are now merged into single entries in the review page.

**Why**: These three intents share the same interest categories, so displaying them separately was redundant and confusing.

**How**: Detect shared intents by prefix, use only the category name as the grouping key, and merge with Set deduplication.

**Result**: Clean, professional review page that shows each interest category once with all selected items combined.
