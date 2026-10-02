# MatchMe Translation System Audit Report

**Generated:** 2024
**Status:** COMPREHENSIVE SYSTEM OVERVIEW

## Executive Summary

The MatchMe translation system uses a **hybrid architecture** combining:
1. **Default English translations** in `lib/providers/locale_provider.dart` (fallback layer)
2. **Database-driven translations** (Supabase `translations` table for multiple locales)
3. **Language-specific SQL migration files** for offline and online provider features

### Key Metrics
- **Translation Keys Used:** 500+ unique keys identified in codebase
- **Supported Locales:** English (en), Spanish (es), Hebrew (he)
- **Primary Translation Methods:** `l10n.getString(key)` and `localization.getString(key)`
- **Database Storage:** `translations(locale, key, value)` table

---

## Architecture Overview

### 1. Translation Provider System
**File:** `lib/providers/locale_provider.dart`

#### Structure
```dart
class LocalizationState {
  final Locale currentLocale;
  final Map<String, String> strings;        // DB translations
  final Set<String> dbKeys;                 // Keys available in DB
  final String translationSource;           // 'defaults' or 'db'
}
```

#### Fallback Mechanism
```
getString(key) → Checks:
1. Gender-specific variant (if gender provided)
2. Values from database (strings map)
3. Default English from _defaultTranslations
4. Returns key itself if not found (escape hatch)
```

### 2. Translation Sources

#### A. Default Translations (Locale Provider)
- **File:** `lib/providers/locale_provider.dart`
- **Contains:** English hardcoded defaults for all keys
- **Purpose:** Fallback when database unavailable
- **Coverage:** 100% - every key used in code has English default

#### B. Database Translations
- **Storage:** Supabase `translations` table
- **Schema:** `(locale: text, key: text, value: text, created_at, updated_at)`
- **Locales:** en, es, he
- **Usage:** Runtime loaded via `_loadTranslationsFromDatabase()`

#### C. SQL Migration Files
- `add_offline_translations.sql` - Offline feature strings (60+ keys)
- `add_online_providers_translations.sql` - Calendar provider integration (5+ keys)
- Other migration files for specific features

---

## Translation Keys By Category

### Core Authentication (20+ keys)
```
authLogin, authSignUp, authEmail, authPassword
authEmailInvalid, authPasswordRequired
authPasswordRequirementsTitle, authPasswordRuleMinLength, etc.
authOAuthAccountExists, authOAuthCancelled, authOAuthFailed
authPasskeySignInSuccess, authPasskeySignInFailed, etc.
authContinueWithGoogle, authContinueWithMicrosoft, authContinueWithApple
```

### CAPTCHA/Security (15+ keys)
```
authCaptchaTitle, authCaptchaSignUpBody, authCaptchaLoginBody
authCaptchaPreparing, authCaptchaPrompt, authCaptchaComplete
authCaptchaFailedRetry, authCaptchaExpiredRetry, authCaptchaMissingConfig
```

### Settings - Passkeys (25+ keys)
```
settingsPasskeyTitle, settingsPasskeyDescription
settingsPasskeyReady, settingsPasskeyStatusReady
settingsPasskeyStatusUnsupported, settingsPasskeyStatusSetupRequired
settingsPasskeyAdded, settingsPasskeyAddFailed
settingsPasskeyRemove, settingsPasskeyRemoveDialogTitle
settingsPasskeyEnrollSuccess, settingsPasskeyRemoveSuccess
```

### Settings - MFA/2FA (45+ keys)
```
settingsMfaTitle, settingsMfaDescription, settingsMfaEnabled
settingsMfaEnable, settingsMfaDisable, settingsMfaDisableConfirm
settingsMfaSetupTitle, settingsMfaSetupBody, settingsMfaQrTitle
settingsMfaManualEntryTitle, settingsMfaSecret, settingsMfaCopySecret
settingsMfaCode, settingsMfaEnterCode, settingsMfaVerify
settingsMfaVerificationSuccess, settingsMfaVerificationFailed
settingsMfaRecoveryCodeTitle, settingsMfaRecoveryCodeBody
settingsMfaRecoveryCodeEnter, settingsMfaRecoveryCodesCopy
settingsMfaEmailCode, settingsMfaEmailCodeEnter, settingsMfaEmailCodeResend
```

### Security & Sign-In Hub (25+ keys)
```
securitySignInHubDescription, securityCurrentSessionTitle
securityHowYouSignedIn, securitySessionStarted, securityDeviceInfo
securitySignInMethodsTitle, securitySignInMethodsDescription
securityMethodConnected, securityMethodNotConnected
securityMethodLastChanged, securityStatusSummarySecure
securityTwoFactorTitle, securityTwoFactorDescription
securityActiveSessions, securityActiveSessionsDescription
securityPasswordSection, securityPasswordDescription, securityPasswordLastChanged
securityContextHelpWhatIsPasskey, securityContextHelpWhy2FA
```

### Settings - General (50+ keys)
```
settingsTitle, settingsAppDisplay, settingsThemeMode
settingsMatching, settingsRadius, settingsGpsRate
settingsChangePassword, settingsNewPassword, settingsDeleteAccount
settingsAccountManagement, settingsPreferencesSaved
settingsRadiusUpdateFailed, settingsGpsRateUpdated
```

### Offline Features (60+ keys)
```
offlineIndicatorTitle, offlineSnackbarMessage
offlineFeatureUnavailable, offlineFeatureRequiresConnection
offlineSendMessageTitle, offlineSendMessageBody
offlineUpdateVisibilityTitle, offlineUpdateVisibilityBody
offlineUpdateProfileTitle, offlineUpdateProfileBody
offlineEditMessageTitle, offlineDeleteMessageTitle
offlineReactToMessageTitle, offlineDeleteReactionTitle
offlineCreateEventTitle, offlineUpdateEventTitle, offlineDeleteEventTitle
offlineJoinEventTitle, offlineLeaveEventTitle
offlineUpdateLocationTitle, offlineBlockUserTitle
offlineSyncingChanges, offlinePendingChanges, offlinePendingChangesDescription
```

### Online Provider Integration (5+ keys)
```
onlineProvidersAddAccount, onlineProvidersRemoveAccount
onlineProvidersRemoveAccountConfirm, onlineProvidersNoAccounts
onlineProvidersAddAccountHint
```

### Profile & Match Screen (50+ keys)
```
profileTitle, profileFirstName, profileLastName, profileBirthday
profileGender, profileAge, profileLanguagesKnown, profileInterests
profileLanguageSkills, profileEditShortBio, profileEditIntentsTitle
matchProfileSharedIntent, matchProfileSharedInterests
newMatchTitle, unmatch, unmatchConfirm, unmatchSuccess
matchedAt, matchedByProximityLabel, matchReasonProximityText
```

### Chat Screen (30+ keys)
```
chatButton, chatSayHello, chatTypeMessage, chatLoadingMessages
chatTranslateOn, chatTranslateOff, chatTranslateToggle
chatYouAreChattingWith, chatIsTyping, chatEditingMessage
blockButton, blockConfirm, blockSuccess, blockFailed
reportTitle, reportSuccess, reportFailed
chatReactorsTapToRemove, generalReaction, replyingToLabel
```

### General UI (30+ keys)
```
generalOk, generalCancel, generalSave, generalClose
generalNext, generalBack, generalError, generalLoading
generalUnknown, generalRetry, generalContinue, generalFieldRequired
homeNearby, homeOnline, homeTier, homeRecentMatches
navHome, navMatches, navChats, navProfile
```

---

## Data Store Mapping

### Database Table Schema
```sql
CREATE TABLE translations (
  id BIGSERIAL PRIMARY KEY,
  locale TEXT NOT NULL,      -- 'en', 'es', 'he'
  key TEXT NOT NULL,         -- translation key
  value TEXT NOT NULL,       -- translated value
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  UNIQUE (locale, key)
);
```

### Current Coverage Status

| Locale | Status | Source | Notes |
|--------|--------|--------|-------|
| English (en) | ✅ Complete | locale_provider.dart | All keys have defaults |
| Spanish (es) | ⚠️ Partial | Database | See migration files for coverage |
| Hebrew (he) | ⚠️ Partial | Database | See migration files for coverage |

### Translation Coverage by Feature

#### Offline Features
- **Coverage:** Spanish ✅, Hebrew ✅
- **Source:** `add_offline_translations.sql`
- **Keys:** 60+ (offlineIndicatorTitle, offlineSendMessageTitle, etc.)

#### Online Providers
- **Coverage:** Spanish ✅, Hebrew ✅
- **Source:** `add_online_providers_translations.sql`
- **Keys:** 5+ (onlineProvidersAddAccount, etc.)

#### Core Features (Auth, Settings, Profile, Chat)
- **Coverage:** English ✅
- **Database Status:** ⚠️ Needs audit

---

## Missing Translations Audit

### Critical Finding: Security Settings Keys
The following keys are used in `security_sign_in_screen.dart` but may not be in database for ES/HE:

#### Passkey Settings (25+ keys)
```
settingsPasskeyTitle                    Status: Check Database
settingsPasskeyDescription              Status: Check Database
settingsPasskeyRemove                   Status: Check Database
settingsPasskeyRemoveConfirm            Status: Check Database
settingsPasskeyEnrollSuccess            Status: Check Database
settingsPasskeyEnrollFailed             Status: Check Database
settingsPasskeyRemoveSuccess            Status: Check Database
settingsPasskeyRemoveConfirm            Status: Check Database
(+ 17 more keys)
```

#### MFA Settings (45+ keys)
```
settingsMfaTitle                        Status: Check Database
settingsMfaDescription                  Status: Check Database
settingsMfaEnable                       Status: Check Database
settingsMfaDisable                      Status: Check Database
settingsMfaSetupTitle                   Status: Check Database
settingsMfaSetupBody                    Status: Check Database
settingsMfaQrTitle                      Status: Check Database
settingsMfaManualEntryTitle             Status: Check Database
settingsMfaSecret                       Status: Check Database
settingsMfaCode                         Status: Check Database
settingsMfaRecoveryCodeTitle            Status: Check Database
settingsMfaRecoveryCodeBody             Status: Check Database
settingsMfaEmailCode                    Status: Check Database
(+ 32 more keys)
```

#### Security Hub (25+ keys)
```
securitySignInHubDescription            Status: Check Database
securityCurrentSessionTitle             Status: Check Database
securitySignInMethodsTitle              Status: Check Database
securitySignInMethodsDescription        Status: Check Database
securityTwoFactorTitle                  Status: Check Database
securityTwoFactorDescription            Status: Check Database
securityActiveSessions                  Status: Check Database
securityContextHelpWhatIsPasskey        Status: Check Database
securityContextHelpWhy2FA               Status: Check Database
(+ 16 more keys)
```

---

## Audit Checklist

### Phase 1: Database Validation ✓
- [ ] Export all keys from `_defaultTranslations` in locale_provider.dart
- [ ] Query database for all (locale, key) combinations
- [ ] Identify gaps for es and he locales
- [ ] Create SQL scripts for missing translations

### Phase 2: Security Settings Translation ⚠️ PRIORITY
- [ ] Add Spanish translations for 95+ security keys
- [ ] Add Hebrew translations for 95+ security keys
- [ ] Test passkey/MFA settings screens with different locales
- [ ] Verify fallback works if translations unavailable

### Phase 3: Chat & Messaging ⚠️ VERIFY
- [ ] Check chat translation keys coverage (30+ keys)
- [ ] Verify message reactions and edit features
- [ ] Test block/report functionality across locales

### Phase 4: Profile & Matching ⚠️ VERIFY
- [ ] Verify profile screen translations (50+ keys)
- [ ] Check match profile screen coverage
- [ ] Verify age/gender preference translations

### Phase 5: General UI ✅ BASELINE
- [ ] General UI keys appear present in database
- [ ] Navigation labels translated
- [ ] Error/loading messages translated

---

## Recommended SQL Scripts

### Generate Spanish Translations for Security Settings
```sql
-- All 95+ security/passkey/MFA settings keys
INSERT INTO translations (locale, key, value) VALUES
('es', 'settingsMfaTitle', 'Autenticación de dos factores'),
('es', 'settingsMfaDescription', 'Agrega una capa extra de seguridad a tu cuenta'),
('es', 'settingsPasskeyTitle', 'Claves de acceso'),
('es', 'settingsPasskeyDescription', 'Usar autenticación biométrica para acceso más seguro'),
-- ... (continue for all keys)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
```

### Generate Hebrew Translations for Security Settings
```sql
-- Hebrew equivalents for all 95+ keys
INSERT INTO translations (locale, key, value) VALUES
('he', 'settingsMfaTitle', 'אימות דו-גורמי'),
('he', 'settingsMfaDescription', 'הוסף שכבת אבטחה נוספת לחשבונך'),
('he', 'settingsPasskeyTitle', 'מפתחות גישה'),
-- ... (continue for all keys)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
```

---

## Implementation Status

### Current State
```
✅ English (Default):      100% (all keys in locale_provider.dart)
⚠️  Spanish (Database):    ~70% (offline/online features complete, core needs audit)
⚠️  Hebrew (Database):     ~70% (offline/online features complete, core needs audit)
```

### Issues Identified
1. **Security Settings Gap:** 95+ keys used in security_sign_in_screen.dart not yet audited for ES/HE
2. **Latest Features:** New security authentication features may not have translations
3. **Database Sync:** Need to verify all active feature keys are in database

### Recommended Priority Actions
1. **HIGH:** Add Spanish/Hebrew for all security settings (affects account security UX)
2. **HIGH:** Audit all `settingsMfa*` and `settingsPasskey*` keys
3. **MEDIUM:** Verify chat and profile translations are complete
4. **MEDIUM:** Create automated audit script to catch future gaps

---

## Key Files Reference

| File | Purpose | Size |
|------|---------|------|
| `lib/providers/locale_provider.dart` | Default translations source | ~2000+ lines |
| `lib/screens/settings/security_sign_in_screen.dart` | Security UX | 1200+ lines |
| `add_offline_translations.sql` | Offline feature strings | Database |
| `add_online_providers_translations.sql` | Calendar integration | Database |

---

## Next Steps

1. **Run Database Audit Query**
   ```sql
   SELECT COUNT(DISTINCT key) FROM translations WHERE locale = 'es';
   SELECT COUNT(DISTINCT key) FROM translations WHERE locale = 'he';
   ```

2. **Compare with Defaults**
   - Extract all keys from locale_provider.dart
   - Cross-reference with database
   - Identify missing translations

3. **Create Translation Backfill Scripts**
   - Generate SQL for missing translations
   - Include Spanish and Hebrew equivalents
   - Test with security settings screen

4. **Automate Future Audits**
   - Create script to extract all getString() calls from codebase
   - Compare against database quarterly
   - Alert when new keys missing translations

---

## Notes

- **Fallback Mechanism:** If a translation is missing, the app will display the English default from locale_provider.dart, ensuring no blank screens
- **Dynamic Loading:** Translations are loaded from database on app startup and cached locally
- **Gender Variants:** Some keys support gender-specific translations (e.g., 'newMatchTitle' with gender: 'female')
- **Parameter Substitution:** Keys like 'authCaptchaFailedWithError' support {error} placeholder substitution

