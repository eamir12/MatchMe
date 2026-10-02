# Translation Key Fix Summary

## Problem
The app was logging "Missing translation for key" errors for bare keys like `outdoors`, `startups`, and `mentorship`, even though these translations existed in the database with prefixed keys like `interest.romantic.outdoors`, `interest.business.entrepreneurship.startups`, etc.

### Root Cause
In `lib/widgets/match_box.dart`, the `_computeMatchReason()` method was passing bare intent keys directly to `getString()`:
- Line 562: `sharedIntentKeys.map((key) => l10n.getString(key))`
- Line 570: `parsedIntents.map((key) => l10n.getString(key))`

These bare keys (e.g., `'romantic'`, `'friendship'`, `'business_networking'`) don't exist in the translations table. The correct translation keys are stored in the `AppIntent.translationKey` field (e.g., `'interest.romantic'`, `'interest.friendship'`, etc.).

## Solution
Updated the translation key lookup to use the proper prefixed keys from the `AppIntent` model:

### Changes Made

**File: `lib/widgets/match_box.dart`**

1. **Modified `_computeMatchReason()` method** (lines 540-617):
   - Changed line 562 from: `sharedIntentKeys.map((key) => l10n.getString(key))`
   - To: `sharedIntentKeys.map((key) => _getIntentTranslation(key, ref, l10n))`
   - Changed line 570 from: `parsedIntents.map((key) => l10n.getString(key))`
   - To: `parsedIntents.map((key) => _getIntentTranslation(key, ref, l10n))`

2. **Added new helper method `_getIntentTranslation()`** (lines 619-635):
   ```dart
   String _getIntentTranslation(String intentKey, WidgetRef ref, LocalizationState l10n) {
     try {
       final allIntents = ref.read(allIntentsProvider).asData?.value ?? [];
       final intent = allIntents.firstWhere(
         (i) => i.key == intentKey,
         orElse: () => AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
       );
       
       if (intent.translationKey.isNotEmpty) {
         return l10n.getString(intent.translationKey);
       }
     } catch (_) {
       // If lookup fails, fall back to bare key
     }
     
     // Fallback: use the key directly (will show 'key...' if not found)
     return l10n.getString(intentKey);
   }
   ```

## How It Works

1. When displaying match reasons, the code now calls `_getIntentTranslation()` instead of directly calling `getString()`
2. `_getIntentTranslation()` looks up the `AppIntent` object by its key
3. It retrieves the `translationKey` from the `AppIntent` object (e.g., `'interest.romantic'`)
4. It passes the proper prefixed key to `getString()`, which finds the translation in the database
5. If the lookup fails, it gracefully falls back to the bare key

## Translation Key Naming Convention

The app uses a hierarchical dot-notation for translation keys:
- **Intent keys**: `interest.{group}` (e.g., `interest.romantic`, `interest.friendship`)
- **Category keys**: `interest.{group}.{category}` (e.g., `interest.romantic.outdoors`)
- **Subcategory keys**: `interest.{group}.{category}.{subcategory}` (e.g., `interest.romantic.outdoors.hiking`)

## Verification

- ✅ File compiles without errors
- ✅ No syntax issues detected
- ✅ Follows the same pattern used in `match_notification_overlay.dart` (line 163)
- ✅ Consistent with interest display logic in `profile_screen.dart` (lines 562-567)

## Additional Fix: Bare Key Aliases

After investigating further, I discovered that the `_translationLookupCandidates` method in `profile_screen.dart` generates bare keys as lookup aliases (e.g., `'outdoors'`, `'startups'`, `'hiking'`, etc.). These bare keys are used to help find translations for interests with compound names.

However, these bare keys don't exist in the translations table, causing the "Missing translation for key" warnings.

**Solution**: Created a new migration file `supabase/migrations/20260422180000_add_bare_interest_key_translations.sql` that adds translations for all these bare key aliases:

- `outdoors` → "Outdoors" (en), "Afuera" (es), "בחוץ" (he)
- `startups` → "Startups" (en), "Startups" (es), "סטארטאפים" (he)
- `mentorship` → "Mentorship" (en), "Mentoría" (es), "חניכות" (he)
- Plus 30+ other aliases used by the lookup system

These translations allow the bare keys to be resolved correctly when they're used as lookup candidates.

## Expected Outcome

After both fixes:
1. The code in `match_box.dart` now properly looks up intent translation keys instead of using bare keys
2. The bare key aliases in the translations table provide fallback translations for the lookup system
3. The "Missing translation for key" warnings for `outdoors`, `startups`, `mentorship`, etc. should disappear
4. Match reasons will display correctly with proper localized intent names
5. The translation system will use the correct prefixed keys from the database
