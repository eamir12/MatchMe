# Translation Audit - Testing & Implementation Guide

## Overview
This guide provides step-by-step instructions to:
1. Test the current translation system
2. Verify coverage across locales
3. Implement the Spanish/Hebrew security settings translations
4. Validate the audit results

---

## Part 1: Current State Assessment

### 1.1 Query Database Translation Coverage

```sql
-- Check total translations by locale
SELECT 
  locale,
  COUNT(*) as total_keys,
  COUNT(DISTINCT key) as unique_keys
FROM translations
GROUP BY locale
ORDER BY locale;

-- Expected Output:
-- locale | total_keys | unique_keys
-- -------|-----------|-------------
--   en   |    XXX     |     XXX
--   es   |    XXX     |     XXX
--   he   |    XXX     |     XXX
```

### 1.2 Check Security Settings Coverage (Current)

```sql
-- Security and Settings keys in database
SELECT locale, COUNT(*) as count FROM translations 
WHERE locale IN ('es', 'he')
  AND (key LIKE 'settings%' OR key LIKE 'security%' OR key LIKE 'auth%')
GROUP BY locale;

-- This will show current gaps for Spanish and Hebrew
```

### 1.3 List Missing Security Keys

```sql
-- Find security keys that are in English but missing for Spanish/Hebrew
WITH en_keys AS (
  SELECT DISTINCT key FROM translations WHERE locale = 'en'
    AND (key LIKE 'settings%' OR key LIKE 'security%' OR key LIKE 'auth%')
)
SELECT DISTINCT t.key FROM en_keys e
LEFT JOIN translations t ON e.key = t.key AND t.locale = 'es'
WHERE t.key IS NULL
ORDER BY e.key;
```

---

## Part 2: Implementation Steps

### 2.1 Run the Translation Backfill Script

**File:** `add_security_translations_es_he.sql`

#### Execution in Supabase (Recommended)
1. Go to Supabase Dashboard → SQL Editor
2. Create new query
3. Copy entire contents of  `add_security_translations_es_he.sql`
4. Execute (this adds 95+ keys to Spanish and Hebrew)
5. Check for success message

#### Backup Before Execution
```sql
-- Create backup of existing translations (optional)
SELECT * INTO translations_backup FROM translations 
WHERE locale IN ('es', 'he');
```

#### Verify Execution
```sql
-- Verify all 95+ security keys were added for Spanish and Hebrew
SELECT locale, COUNT(*) as added_keys FROM translations 
WHERE locale IN ('es', 'he')
  AND (
    key LIKE 'settings%' OR 
    key LIKE 'security%' OR 
    key LIKE 'auth%'
  )
GROUP BY locale;

-- Expected: Should show ~95+ keys for both es and he
```

---

## Part 3: Testing the Translation System

### 3.1 Flutter App Testing - Manual Verification

#### Test Spanish (es) Locale
1. Open app settings → App Display → Language
2. Select "Español"
3. Navigate to: Profile → Settings → Security & Sign-In
4. Verify screens load without errors
5. Check that no locale keys are displayed as "[key_name]"

**Key screens to verify:**
- Security & Sign-In Hub
- Two-Factor Authentication (MFA) setup
- Passkey settings
- Change password dialog
- Security settings section

#### Test Hebrew (he) Locale
1. Change language to "עברית" (Hebrew)
2. Repeat steps 2-5 above
3. Verify RTL (right-to-left) layout works correctly
4. Check text wrapping and alignment

### 3.2 Automated Verification - Code Inspection

```dart
// In Flutter app, verify getString() calls return translations
void testTranslationCoverage() {
  final l10n = LocalizationState(/* current state */);
  
  // Test security keys
  final testKeys = [
    'settingsMfaTitle',
    'settingsPasskeyTitle',
    'securitySignInHubDescription',
    'settingsMfaSetupBody',
    'settingsPasskeyRemoveConfirm',
  ];
  
  for (final key in testKeys) {
    final translation = l10n.getString(key);
    assert(translation != key, 'Missing translation for $key');
  }
}
```

### 3.3 Test Fallback Mechanism

```dart
// Verify that missing translations fall back to English
void testFallbackBehavior() {
  // If database is empty, app should show English defaults
  final l10n = LocalizationState(
    strings: {}, // Empty database
    locale: Locale('es'), // Spanish requested
  );
  
  // Should return English default instead of the key itself
  final result = l10n.getString('settingsMfaTitle');
  expect(result, isNotEmpty);
  expect(result, isNot('settingsMfaTitle')); // Not showing raw key
}
```

### 3.4 Verify Database Sync

```sql
-- Check that app-side cache matches database
-- After user changes language, verify local cache is updated

-- Get current database version
SELECT 
  locale,
  MAX(updated_at) as last_updated,
  COUNT(*) as total_keys
FROM translations
WHERE locale IN ('es', 'he')
GROUP BY locale;

-- Compare with SharedPreferences cache (from app logs)
-- Timestamps should be recent after implementation
```

---

## Part 4: Validation Checklist

### Translation Coverage Validation

**Before Implementation:**
- [ ] Query database for existing Spanish/Hebrew security translations
- [ ] Document current gap (expected: missing 95+ keys)
- [ ] Save output to `BEFORE_audit.txt`

**After Implementation:**
- [ ] Run translation backfill script
- [ ] Re-query database for coverage
- [ ] Verify 95+ new keys added for ES and HE
- [ ] Save output to `AFTER_audit.txt`
- [ ] Compare: gaps should be closed

**Acceptance Criteria:**
- [ ] Spanish locale: 100% coverage for security settings
- [ ] Hebrew locale: 100% coverage for security settings
- [ ] No "[key_name]" text displayed in UI
- [ ] All settings screens render without errors
- [ ] RTL (Hebrew) layout displays correctly

### Functional Testing

**Security Settings Screen:**
- [ ] MFA title displays in correct language
- [ ] Passkey settings visible and translated
- [ ] Recovery codes dialog shows correct text
- [ ] QR code setup instructions in user language
- [ ] Email verification codes display properly

**Password Management:**
- [ ] Change password dialog translated
- [ ] Password requirements displayed in user language
- [ ] Confirmation messages show in correct locale

**Session Management:**
- [ ] "Current session" information translated
- [ ] Device info displays properly
- [ ] Sign-in methods listed in user language

### Edge Cases

- [ ] Test with network offline (should show English defaults from cache)
- [ ] Test with partial database (missing some keys)
- [ ] Test locale switching mid-session
- [ ] Test on Android, iOS, and Web platforms
- [ ] Test with keyboard/ime for Hebrew input

---

## Part 5: Troubleshooting

### Issue: Translations not appearing

**Solution:**
1. Clear app cache: Settings → Storage → Clear app data
2. Force language refresh:
   ```dart
   ref.refresh(localizationProvider);
   ```
3. Verify database has translations for current locale
4. Check app logs for errors

### Issue: English showing instead of Spanish/Hebrew

**Possible causes:**
1. Keys not in database (check SQL execution success)
2. App cache not updated (clear SharedPreferences cache)
3. New strings not yet available (wait for database sync)

**Debug steps:**
```dart
// Print which keys are missing
final state = ref.watch(localizationProvider);
print('Current locale: ${state.currentLocale}');
print('DB keys count: ${state.dbKeys.length}');
print('Translation source: ${state.translationSource}');

// Check specific key
print('settingsMfaTitle: ${state.getString("settingsMfaTitle")}');
```

### Issue: Hebrew text displayed as LTR instead of RTL

**Solution:**
- Verify `textDirection: TextDirection.rtl` set in locale provider
- Check widget wrapping (DirectionalityWidget)
- Verify device Hebrew keyboard enabled

---

## Part 6: Post-Implementation Tasks

### 6.1 Documentation Update

- [ ] Update in-app help text references to translated keys
- [ ] Update admin dashboard if it uses translations
- [ ] Document translation key naming conventions

### 6.2 Automated Audit Script

Create script to catch future translation gaps:

```dart
// lib/utils/translation_audit.dart
class TranslationAudit {
  static void auditMissingTranslations() {
    final allUsedKeys = _extractAllStringKeys();
    final allDefaultKeys = _defaultTranslations.keys.toSet();
    
    final missingInDefaults = allUsedKeys.difference(allDefaultKeys);
    
    if (missingInDefaults.isNotEmpty) {
      throw Exception(
        'Missing translations in defaults:\n${missingInDefaults.join(", ")}'
      );
    }
  }
}
```

### 6.3 CI/CD Integration

Add to build pipeline:
```yaml
# .github/workflows/check-translations.yml
- name: Audit Translations
  run: |
    dart run lib/utils/translation_audit.dart
    # Alert if new untranslated keys found
```

### 6.4 User Communication

- [ ] Post changelog: "Added Spanish/Hebrew translations for security settings"
- [ ] Test translations with native speakers if possible
- [ ] Monitor crash logs for translation-related issues

---

## Part 7: Monitoring & Maintenance

### Metrics to Track

```sql
-- Monthly translation coverage check
SELECT 
  locale,
  COUNT(DISTINCT key) as total_keys,
  DATE(updated_at) as last_active
FROM translations
WHERE locale IN ('en', 'es', 'he')
GROUP BY locale
ORDER BY locale;

-- Track which keys are most recently added
SELECT key, locale, updated_at
FROM translations
WHERE updated_at > NOW() - INTERVAL '30 days'
ORDER BY updated_at DESC;
```

### Quarterly Review

- [ ] Check for new untranslated keys in code
- [ ] Review user feedback on translation quality
- [ ] Update translations if UX/terminology changes
- [ ] Profile native speakers for review

---

## Part 8: Reference Data

### Translation Key Statistics

**Security Settings (95 keys total):**
- Passkey Settings: 25 keys
- MFA/2FA Settings: 45 keys
- Security Hub: 25 keys

**Coverage by Locale (Post-Implementation):**
- English (en): ✅ 100%
- Spanish (es): ✅ 100% (after script execution)
- Hebrew (he): ✅ 100% (after script execution)

### Files Modified
- `add_security_translations_es_he.sql` → Database translations
- `TRANSLATION_SYSTEM_AUDIT.md` → Audit documentation
- (No code changes required - data-only)

---

## Appendix: SQL Verification Queries

### Query 1: Pre-Implementation Baseline
```sql
-- Run BEFORE applying changes
SELECT 
  locale,
  (SELECT COUNT(DISTINCT key) FROM translations WHERE locale='en' 
    AND (key LIKE 'settings%' OR key LIKE 'security%')) as en_count,
  (SELECT COUNT(DISTINCT key) FROM translations WHERE locale='es' 
    AND (key LIKE 'settings%' OR key LIKE 'security%')) as es_count,
  (SELECT COUNT(DISTINCT key) FROM translations WHERE locale='he' 
    AND (key LIKE 'settings%' OR key LIKE 'security%')) as he_count
LIMIT 1;
```

### Query 2: Post-Implementation Verification
```sql
-- Run AFTER applying SQL script
SELECT 
  locale,
  COUNT(DISTINCT key) as security_setting_keys
FROM translations 
WHERE (key LIKE 'settings%' OR key LIKE 'security%' OR key LIKE 'auth%')
  AND locale IN ('es', 'he')
GROUP BY locale
ORDER BY locale;

-- Should show es: 95+, he: 95+
```

### Query 3: Coverage Report
```sql
-- Comprehensive coverage report
WITH all_locales AS (
  SELECT DISTINCT locale FROM translations
)
SELECT 
  al.locale,
  COUNT(DISTINCT t.key) as total_translations,
  ROUND(100.0 * COUNT(DISTINCT t.key) / 
    (SELECT COUNT(DISTINCT key) FROM translations WHERE locale='en'), 2) 
    as coverage_percentage
FROM all_locales al
LEFT JOIN translations t ON al.locale = t.locale
GROUP BY al.locale
ORDER BY coverage_percentage DESC;
```

---

## Sign-Off

- [ ] Translations implemented
- [ ] Testing completed
- [ ] All validation checks passed
- [ ] Documentation updated
- [ ] Ready for production release

**Implementation Date:** _____________
**Tested By:** _____________
**Approved By:** _____________

