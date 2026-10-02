# MatchMe Codebase: Error Handling, Translations & Locale Management

**Date:** April 13, 2026  
**Project:** MatchMe (Flutter/Dart + Supabase)  
**Scope:** Main app + Admin app

---

## 1. Error Handling Architecture

### 1.1 Display Methods

#### **SnackBars** (Lower-priority, in-app notifications)
- **Implementation:** `ScaffoldMessenger.of(context).showSnackBar(SnackBar(...))`
- **Common usage:** Settings changes, GPS updates, sync status
- **Examples:**
  - `settingsSmartGpsThrottlingUpdated` → "Smart GPS Throttling updated"
  - `offlineSnackbarMessage` → "MatchMe is offline - using cached data"
  - GPS rate updates, profile changes, etc.

**File:** [lib/screens/settings/settings_screen.dart](lib/screens/settings/settings_screen.dart#L134)

#### **Dialog Boxes** (Critical interactions)
- **Implementation:** `showDialog<T>(context: context, builder: (context) => AlertDialog(...))`
- **Common usage:** Confirmation dialogs, critical errors, MFA setup
- **Examples:**
  - Match profile screen confirmation when unmatching
  - MFA verification dialogs
  - Password reset confirmation
  - Account deletion confirmation

**File:** [lib/screens/auth/auth_screen.dart](lib/screens/auth/auth_screen.dart#L1205)

#### **Error Message State** (Form-level errors)
- **Implementation:** State variable `_errorMessage` displayed in decorated box
- **Common usage:** Authentication screen, password validation
- **Display:** Red background (error indicator) + "Error Outline" icon
- **Examples:**
  - `authIncorrectPassword` → "Incorrect password."
  - `authEmailAlreadyRegistered` → "An account with this email already exists."
  - Password validation errors (too short, missing uppercase, etc.)

**File:** [lib/screens/auth/auth_screen.dart](lib/screens/auth/auth_screen.dart#L1691)

```dart
if (_errorMessage != null)
  Padding(
    padding: const EdgeInsets.only(top: 16.0),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(_errorMessage!)),
          ],
        ),
      ),
    ),
  ),
```

#### **Global Riverpod Provider** (OAuth/auth flow errors)
- **Implementation:** `authUiMessageProvider` notifier
- **Common usage:** OAuth errors, network errors during auth
- **Flow:** Error caught → Provider updated → Listener in auth screen shows message

**File:** [lib/providers/auth_provider.dart](lib/providers/auth_provider.dart#L1)

```dart
final authUiMessageProvider = NotifierProvider<AuthUiMessageNotifier, String?>(() {
  return AuthUiMessageNotifier();
});
```

---

### 1.2 Error Categories and Handling Patterns

#### **Authentication Errors**

**Password-based errors** (mapped in `_mapPasswordAuthError()`):
```dart
String _mapPasswordAuthError(AuthException e, LocalizationState l10n) {
  final msg = e.message.toLowerCase();
  if (msg.contains('invalid login credentials') ||
      msg.contains('invalid') && msg.contains('credentials')) {
    return l10n.getString('authIncorrectPassword');
  }
  return msg;
}
```

**Specific error messages:**
- `authIncorrectPassword` → "Incorrect password."
- `authInvalidCredentials` → "Invalid email or password"
- `authEmailAlreadyRegistered` → "An account with this email already exists."
- `authPasswordRequired` → "Password is required"
- `authPasswordTooShort` → "Password must be at least 8 characters"

**OAuth errors** (mapped in `_mapOAuthAuthError()`):
- `authOAuthCancelled` → "User cancelled OAuth"
- `authOAuthAccountExists` → "Email already registered with OAuth"
- `authOAuthFailed` → Generic OAuth failure

**Passkey errors:**
- `authPasskeyNotSupported` → "Passkey authentication is not supported on this device"
- `authPasskeyNotAvailable` → "This account does not have a passkey registered"
- `authPasskeyCancelled` → "Passkey authentication was cancelled"
- `authPasskeySecurityError` → "A security error occurred during passkey authentication"

**File:** [lib/screens/auth/auth_screen.dart](lib/screens/auth/auth_screen.dart#L75)

#### **Secure Signup Errors** (mapped in `_mapSecureSignupError()`)

**Custom SignUp exceptions:**
```dart
class SecureSignUpException implements Exception {
  const SecureSignUpException({
    required this.code,
    required this.message,
  });
  final String code;
  final String message;
}
```

**Error code mapping:**
- `already_registered` → `authEmailAlreadyRegistered`
- `disposable_email_blocked` → `authDisposableEmailBlocked`
- `email_recent_abuse_blocked`, `email_high_risk_blocked`, `invalid_email_blocked` → `authEmailRejected`
- `fraud_blocked`, `device_reuse_blocked`, `device_reuse_same_network_blocked`, `install_reuse_blocked` → `authSignUpBlocked`
- `payment_processor_declined` → `authPaymentFailed`

**File:** [lib/services/secure_signup_service.dart](lib/services/secure_signup_service.dart#L1)

#### **Network and Session Errors**

**Error detection in `auth_provider.dart`:**

```dart
bool isLikelyNetworkAuthError(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('socketexception') ||
         msg.contains('clientexception') ||
         msg.contains('failed host lookup') ||
         msg.contains('no address associated with hostname') ||
         msg.contains('network is unreachable') ||
         msg.contains('connection refused') ||
         msg.contains('connection reset') ||
         msg.contains('timed out');
}

bool shouldSignOutForError(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('refresh_token_not_found') ||
         msg.contains('invalid refresh token') ||
         msg.contains('invalid jwt') ||
         msg.contains('jwt expired') ||
         msg.contains('unauthorized');
}
```

**File:** [lib/providers/auth_provider.dart](lib/providers/auth_provider.dart#L50)

#### **CAPTCHA Errors**

- `authCaptchaTitle` → "Security Check"
- `authCaptchaVerificationFailed` → "Security check could not be verified. Please try again."
- `authCaptchaRequiredAfterFailures` → "After 3 failed password attempts, a security check is required before you can try again."
- `authCaptchaExpiredRetry` → "Security check expired. Please retry."
- `authCaptchaTimedOutRetry` → "Security check timed out. Please retry."

#### **Offline Mode Errors**

**Offline indicator SnackBar:**
```dart
void showOfflineSnackbar(BuildContext context, WidgetRef? ref) {
  final localization = ref?.read(localizationProvider);
  String message = localization?.getString('offlineSnackbarMessage') ??
                   'MatchMe is offline - using cached data';
  
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
```

**Feature-specific offline dialogs:**
- `offlineSendMessageTitle/Body` - Cannot send message while offline
- `offlineUpdateVisibilityTitle/Body` - Cannot update visibility while offline
- `offlineUpdateProfileTitle/Body` - Cannot update profile while offline
- `offlineEditMessageTitle/Body` - Cannot edit message while offline
- `offlineDeleteMessageTitle/Body` - Cannot delete message while offline
- `offlineReactToMessageTitle/Body` - Cannot add reaction while offline
- Similar for events, location, rules, notifications, block/report, etc.

**File:** [lib/widgets/offline_indicator.dart](lib/widgets/offline_indicator.dart#L57)

#### **Validation Errors**

**Password requirements (displayed in locale_provider):**
- `authPasswordRequirementsTitle` → "Your password must include:"
- `authPasswordRuleMinLength` → "At least 8 characters"
- `authPasswordRuleUppercase` → "At least 1 uppercase letter"
- `authPasswordRuleLowercase` → "At least 1 lowercase letter"
- `authPasswordRuleNumber` → "At least 1 number"
- `authPasswordRuleSpecial` → "At least 1 special character: @$!%*?&"

**File:** [lib/providers/locale_provider.dart](lib/providers/locale_provider.dart#L321)

#### **MFA Errors**

- `settingsMfaVerificationFailed` → "MFA verification failed. Please try again."
- `settingsMfaEnrollmentFailed` → "Failed to enable two-factor authentication"
- `settingsMfaDisableFailed` → "Failed to disable two-factor authentication"
- `settingsMfaCodeInvalid` → "Invalid code. Please try again."

#### **Other Common Errors**

- `generalErrorLoadingProfile` → "Error loading profile"
- `settingsRadiusUpdateFailed` → "Failed to update radius"
- `settingsGpsRateUpdateFailed` → "Failed to update GPS rate"
- `settingsPasswordChangeFailed` → "Failed to change password"
- `settingsDeleteAccountFailed` → "Failed to delete account"
- `failedToLoadImage` → "Failed to load image"
- `chatSendFailed` → "Failed to send/edit message"

---

## 2. Translations Table Structure

### 2.1 Database Schema

**Location:** Supabase public schema

```sql
CREATE TABLE translations (
  id BIGSERIAL PRIMARY KEY,
  locale TEXT NOT NULL,           -- 'en', 'es', 'he'
  key TEXT NOT NULL,              -- translation key identifier
  value TEXT NOT NULL,            -- translated string value
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  UNIQUE (locale, key)            -- Prevent duplicate translations
);
```

**Indexes:** Implicit index on (`locale`, `key`) via UNIQUE constraint

**Row policy example:**
```sql
INSERT INTO translations (locale, key, value) VALUES
  ('en', 'authPassword', 'Password'),
  ('es', 'authPassword', 'Contraseña'),
  ('he', 'authPassword', 'סיסמה'),
  ('en', 'offlineSnackbarMessage', 'MatchMe is offline - using cached data'),
  ('es', 'offlineSnackbarMessage', 'MatchMe está sin conexión - usando datos en caché'),
  ('he', 'offlineSnackbarMessage', 'MatchMe אחוז מהרשת - שימוש בנתונים שמורים');
```

**File examples:**
- [add_offline_translations.sql](add_offline_translations.sql) - 60+ offline feature translations
- [supabase_translations.sql](supabase_translations.sql) - GPS/settings translations
- [supabase/migrations/20260223002000_admin_translations_rpcs.sql](supabase/migrations/20260223002000_admin_translations_rpcs.sql) - Admin RPC for bulk upsert

### 2.2 Admin RPC for Translations Management

```dart
// File: supabase/migrations/20260223002000_admin_translations_rpcs.sql
CREATE OR REPLACE FUNCTION public.admin_bulk_upsert_translations(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- Accepts JSON array like:
-- [
--   {"locale": "en", "key": "authPassword", "value": "Password"},
--   {"locale": "es", "key": "authPassword", "value": "Contraseña"}
-- ]
```

---

## 3. Locale and Language Handling

### 3.1 LocalizationState Architecture

**File:** [lib/providers/locale_provider.dart](lib/providers/locale_provider.dart)

```dart
class LocalizationState {
  final Locale currentLocale;           // System Locale (e.g., 'en', 'es', 'he')
  final TextDirection textDirection;    // LTR or RTL (for Hebrew)
  final Map<String, String> strings;    // Translation key→value map
  final List<AppLanguage> supportedLanguages;
  final bool isLoading;
  final Set<String> dbKeys;             // Keys fetched from DB (for coverage tracking)
  final String translationSource;       // 'defaults', 'supabase', or 'cache'
  
  // Helper: Get translation with fallback
  String getString(String key, {String? gender, Map<String, String>? params}) {
    // Try gendered key first (e.g., 'invisibleDueTo_male')
    if (gender != null) {
      final suffix = _normalizeGenderSuffix(gender);
      final gKey = '${key}_$suffix';
      final gTranslation = strings[gKey] ?? _defaultTranslations[gKey];
      if (gTranslation != null) return _applyParams(gTranslation, params);
    }
    
    // Fall back to base key
    final translation = strings[key] ?? _defaultTranslations[key];
    if (translation != null) return _applyParams(translation, params);
    
    return '$key...'; // Show key as fallback
  }
  
  String formatCount(int count) {
    // Format numbers according to locale (e.g., "1,000" or "1.000")
    final localeTag = currentLocale.toLanguageTag();
    final formattedCount = NumberFormat.decimalPattern(localeTag).format(count);
    return '\u2066$formattedCount\u2069'; // BiDi isolation
  }
}
```

### 3.2 Language Detection and Selection

**Initialization flow:**
1. Get device locale: `WidgetsBinding.instance.platformDispatcher.locale`
2. Check if supported (en, es, he)
3. Fall back to English if unsupported
4. Persist choice to SharedPreferences: `'user_language_code'`

**Implementation:**
```dart
Future<void> _init() async {
  final supported = await _fetchSupportedLanguages();
  final prefs = await SharedPreferences.getInstance();
  String? langCode = prefs.getString('user_language_code');

  if (langCode == null) {
    try {
      final Locale deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
      langCode = supported.any((lang) => lang.code == deviceLocale.languageCode)
          ? deviceLocale.languageCode
          : 'en';
    } catch (e) {
      langCode = 'en';
    }
  }

  final AppLanguage initialLang = supported.firstWhere(
    (l) => l.code == langCode,
    orElse: () => AppLanguage(code: 'en', displayName: 'English'),
  );
  
  // Load translations from DB, then cache, then defaults
  await setLocale(initialLang.code, null, false);
}
```

### 3.3 Supported Languages

```dart
class AppLanguage {
  final String code;           // 'en', 'es', 'he'
  final String displayName;    // "English", "Español", "עברית"
  final TextDirection direction; // LTR or RTL
}
```

**Supported languages:**
| Code | Display Name | Direction | Coverage |
|------|-------------|-----------|----------|
| en | English | LTR | ✅ 100% (embedded defaults) |
| es | Español | LTR | ⚠️ Partial (DB) |
| he | עברית | RTL | ⚠️ Partial (DB) |

### 3.4 Language Detection (Text-based)

```dart
String guessLanguageCode(String text) {
  // Detects language from text content
  
  // Hebrew detection (Unicode range U+0590–U+05FF)
  final hasHebrew = RegExp(r'[\u0590-\u05FF]').hasMatch(text);
  if (hasHebrew) return 'he';

  // Spanish detection (¿¡ñ áéíóúü patterns)
  final hasSpanishMarks = text.toLowerCase().contains('¿') ||
                          text.toLowerCase().contains('¡') ||
                          text.toLowerCase().contains('ñ');
  if (hasSpanishMarks) return 'es';

  // Language score based on common word lists
  const spanishCommon = {'hola', 'que', 'cómo', 'gracias', ...};
  const englishCommon = {'hi', 'hello', 'thanks', 'you', ...};
  
  // Score and return language with highest match
  if (esScore >= 2 && esScore > enScore) return 'es';
  if (enScore >= 2 && enScore > esScore) return 'en';
  
  return 'en'; // Default
}
```

**File:** [lib/services/translation_service.dart](lib/services/translation_service.dart#L1)

### 3.5 Translation Loading Strategy

**Multi-level fallback system:**

1. **Supabase (Primary)** → Fresh translations if online
2. **SharedPreferences Cache** → Cached translations if offline
3. **Embedded Defaults** → Always available as fallback

**Implementation in `_init()`:**
```dart
// Try to fetch fresh translations from DB if Supabase is available
Map<String, String> strings = {};
bool fetchedFromDb = false;
String translationSource = 'defaults';

try {
  final dbStrings = await _fetchTranslationsFromDB(initialLang.code);
  if (dbStrings.isNotEmpty) {
    strings = dbStrings;
    fetchedFromDb = true;
    translationSource = 'supabase';
    
    // Cache for offline use
    await _saveTranslationsToCache(initialLang.code, dbStrings);
  }
} catch (e) {
  debugPrint('[L10N] DB fetch failed: $e');
}

// Fall back to cache if DB fetch failed
if (!fetchedFromDb) {
  try {
    final cachedStrings = await _loadTranslationsFromCache(initialLang.code);
    if (cachedStrings.isNotEmpty) {
      strings = cachedStrings;
      translationSource = 'cache';
    }
  } catch (cacheErr) {
    debugPrint('[L10N] Cache load failed: $cacheErr');
  }
}

// Final merge: defaults + cached/DB + live updates
final mergedStrings = <String, String>{}
  ..addAll(LocalizationState._defaultTranslations)  // Defaults first
  ..addAll(strings);                                 // DB/cache overrides
```

### 3.6 Real-time Translation Updates (RealtimeChannel)

When user changes language preference in settings, updates sync across devices:

```dart
void _ensureLanguageRealtimeSubscription() {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return;
  
  _languageRealtimeChannel = Supabase.instance.client
      .channel('user_language_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: userId,
        ),
        callback: (payload) {
          final remoteLanguage = payload.newRecord['preferred_language'];
          if (remoteLanguage != state.currentLocale.languageCode) {
            unawaited(setLocale(remoteLanguage, null, false));
          }
        },
      ).subscribe();
}
```

### 3.7 Gender-Specific Translations

Some keys support gender variants:

```dart
// Key patterns in DB:
'invisibleDueTo'           // Base key
'invisibleDueTo_male'      // Male variant
'invisibleDueTo_female'    // Female variant
'invisibleDueTo_non_binary'// Non-binary variant

// Usage in code:
final message = l10n.getString('invisibleDueTo', gender: 'male');
// Returns: 'invisibleDueTo' value with gender suffix applied if available

// Normalization:
static String _normalizeGenderSuffix(String raw) {
  var g = raw.toLowerCase().trim();
  if (g.startsWith('gender_')) g = g.substring('gender_'.length);
  g = g.replaceAll('-', '_');
  if (g == 'nonbinary' || g == 'non binary') g = 'non_binary';
  return g;
}
```

### 3.8 Parameter Substitution

Translations can include placeholders:

```dart
// In translations table:
'offlineFeatureRequiresConnectionDetailed': '{feature} requires an internet connection. MatchMe is currently offline.'

// Usage:
l10n.getString(
  'offlineFeatureRequiresConnectionDetailed',
  params: {'feature': 'Chat'}
)
// Returns: 'Chat requires an internet connection. MatchMe is currently offline.'

// Implementation:
static String _applyParams(String s, Map<String, String>? params) {
  if (params == null || params.isEmpty) return s;
  var out = s;
  params.forEach((k, v) {
    out = out.replaceAll('{$k}', v);
  });
  return out;
}
```

---

## 4. Key Files and Their Roles

### **Main App Error Handling**

| File | Purpose | Key Patterns |
|------|---------|--------------|
| [lib/providers/auth_provider.dart](lib/providers/auth_provider.dart) | Auth state management, error categorization | `isLikelyNetworkAuthError()`, `shouldSignOutForError()`, `isPkceCodeVerifierError()`, `authStateProvider` stream |
| [lib/screens/auth/auth_screen.dart](lib/screens/auth/auth_screen.dart) | Auth UI, error display, validation | `_mapPasswordAuthError()`, `_mapOAuthAuthError()`, `_mapSecureSignupError()`, `_errorMessage` state |
| [lib/services/secure_signup_service.dart](lib/services/secure_signup_service.dart) | Secure signup via Edge function | `SecureSignUpException`, device fingerprinting |
| [lib/services/passkey_auth_service.dart](lib/services/passkey_auth_service.dart) | Passkey authentication | `PasskeyAuthException`, platform-specific errors |
| [lib/screens/settings/settings_screen.dart](lib/screens/settings/settings_screen.dart) | Settings UI, error snackbars | `_showSnackBar()`, MFA/Passkey error handling |
| [lib/widgets/offline_indicator.dart](lib/widgets/offline_indicator.dart) | Offline mode indicator | `showOfflineSnackbar()`, offline feature dialogs |

### **Translation & Localization**

| File | Purpose | Key Patterns |
|------|---------|--------------|
| [lib/providers/locale_provider.dart](lib/providers/locale_provider.dart) | **Main localization provider** | `LocalizationState`, `getString()`, translation loading from DB/cache/defaults, real-time updates |
| [lib/services/translation_service.dart](lib/services/translation_service.dart) | Language detection & DeepL translation | `guessLanguageCode()`, platform-specific implementations |
| [lib/services/translation_cache_manager.dart](lib/services/translation_cache_manager.dart) | Translation caching to SharedPreferences | Cache save/load for offline mode |

### **Admin App**

| File | Purpose | Key Error Messages |
|------|---------|-------------------|
| [matchme_admin/lib/main.dart](matchme_admin/lib/main.dart) | Admin interface | `adminNotAuthorized`, `adminAuthCheckFailed`, `authLoginFailed`, `supabaseConfigMissing` |

### **Supabase Functions**

| File | Purpose |
|------|---------|
| [supabase/functions/secure-sign-up/index.ts](supabase/functions/secure-sign-up/index.ts) | Secure signup with fraud detection |
| [supabase/functions/compare-verification-photos/index.ts](supabase/functions/compare-verification-photos/index.ts) | Photo verification with error responses |
| [supabase/migrations/20260223002000_admin_translations_rpcs.sql](supabase/migrations/20260223002000_admin_translations_rpcs.sql) | Admin RPC: `admin_bulk_upsert_translations()` |

---

## 5. Error Message Examples by Feature

### **Authentication**
- `authIncorrectPassword` → "Incorrect password."
- `authEmailRequired` → "Email is required"
- `authEmailInvalid` → "Invalid email address"
- `authEmailAlreadyRegistered` → "An account with this email already exists."
- `authPasswordWeak` → "Password must contain uppercase, lowercase, number and special character"
- `authResetPasswordFailed` → "Failed to send reset email"
- `authCaptchaVerificationFailed` → "Security check could not be verified. Please try again."

### **Settings & MFA**
- `settingsMfaVerificationFailed` → "MFA verification failed. Please try again."
- `settingsMfaEnrollmentFailed` → "Failed to enable two-factor authentication"
- `settingsPasswordChangeFailed` → "Failed to change password"
- `settingsDeleteAccountFailed` → "Failed to delete account"
- `settingsRadiusUpdateFailed` → "Failed to update radius"
- `settingsGpsRateUpdateFailed` → "Failed to update GPS rate"

### **Offline Mode**
- `offlineSnackbarMessage` → "MatchMe is offline - using cached data"
- `offlineSendMessageTitle` → "Cannot send message while offline"
- `offlineUpdateProfileTitle` → "Cannot update profile while offline"
- `offlineFeatureRequiresConnectionDetailed` → "{feature} requires an internet connection. MatchMe is currently offline."

### **Calendar Sync**
- `calendarSyncNetworkError` → "Network error. Please check your internet connection."
- `calendarSyncTimeout` → "Request timed out. Please try again."
- `calendarSyncOutlookFailed` → "Failed to fetch Outlook calendars. Please try again later."
- `calendarSyncNoCalendarsFound` → "No calendars found"

### **Passkeys**
- `authPasskeyNotSupported` → "Passkey authentication is not supported on this device"
- `authPasskeyNotAvailable` → "This account does not have a passkey registered"
- `settingsPasskeyEnrollFailed` → "Failed to add passkey"
- `settingsPasskeyRemoveFailed` → "Failed to remove passkey"

### **Verification**
- `failedToSubmitVerification` → "Failed to submit verification"
- `primaryPhotoVerificationErrorNoPerson` → "No person found. Please show your face clearly."
- `primaryPhotoVerificationErrorMultipleFaces` → "Please use a photo with only you in it."
- `primaryPhotoVerificationErrorVerifiedMismatch` → "Your primary photo must match your verified identity."

---

## 6. Current Translation Coverage

### **English (en)**
- **Status:** ✅ 100% Complete
- **Source:** Built-in defaults in `locale_provider.dart`
- **Coverage:** 1000+ keys covering all features

### **Spanish (es)**
- **Status:** ⚠️ Partial
- **Source:** Database migrations (SQL)
- **Coverage:** 
  - Offline features: ✅ ~60 keys
  - Online providers: ✅ ~5 keys
  - GPS/Settings: ✅ Multiple keys
  - **Missing:** Security settings (45+ MFA keys, 25+ Passkey keys)

### **Hebrew (he)**
- **Status:** ⚠️ Partial
- **Source:** Database migrations (SQL)
- **Direction:** RTL (right-to-left)
- **Coverage:** Similar to Spanish
- **Missing:** Same security settings keys as Spanish

**Audit notes:**
- Security settings keys (`settingsMfaTitle`, `settingsPasskeyTitle`, etc.) marked for audit in [TRANSLATION_SYSTEM_AUDIT.md](TRANSLATION_SYSTEM_AUDIT.md#L187)
- Database source indicated as partial for ES/HE
- All keys have English defaults, so app never shows raw keys

---

## 7. Default Translations (Built-in Fallbacks)

**Location in code:** [lib/providers/locale_provider.dart#L1075+](lib/providers/locale_provider.dart#L1075)

**Sample of critical defaults:**
```dart
static const Map<String, String> _defaultTranslations = {
  'authStreamError': 'Auth Stream Error',
  'supabaseInitFailed': 'Supabase initialization failed',
  'supabaseConfigMissing': 'Supabase configuration missing',
  'supabaseUrlMissing': 'SUPABASE_URL is missing from .env or --dart-define',
  'supabaseAnonKeyMissing': 'SUPABASE_ANON_KEY is missing from .env or --dart-define',
  'authPassword': 'Password',
  'authEmail': 'Email',
  'authLogin': 'Log In',
  'authIncorrectPassword': 'Incorrect password.',
  'authEmailAlreadyRegistered': 'An account with this email already exists.',
  // ... 1000+ more entries
};
```

---

## 8. Error Handling Best Practices in the Codebase

### **Pattern 1: Specific Error Detection**
```dart
bool isPkceCodeVerifierError(Object error) {
  final msg = (error is AuthException) ? error.message : error.toString();
  return msg.toLowerCase().contains('code verifier could not be found');
}
```

### **Pattern 2: Error-to-Message Mapping**
```dart
String _mapSecureSignupError(SecureSignUpException e, LocalizationState l10n) {
  switch (e.code) {
    case 'already_registered':
      return l10n.getString('authEmailAlreadyRegistered');
    case 'disposable_email_blocked':
      return l10n.getString('authDisposableEmailBlocked');
    // ... more cases
    default:
      return e.message;
  }
}
```

### **Pattern 3: UI Error Display**
```dart
if (_errorMessage != null)
  ErrorBox(
    icon: Icons.error_outline,
    message: _errorMessage!,
    color: Colors.red,
  ),
```

### **Pattern 4: Offline Error Dialogs**
```dart
void _showOfflineDialog(BuildContext context, String titleKey, String bodyKey) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.getString(titleKey)),
      content: Text(l10n.getString(bodyKey)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.getString('offlineOkButton')),
        ),
      ],
    ),
  );
}
```

### **Pattern 5: Session Validation**
```dart
void validateSessionBestEffort(AuthState authState) {
  if (!offlineCacheManager.isSupabaseAvailable || 
      offlineCacheManager.shouldUseCachedData()) {
    return; // Skip validation if offline
  }
  
  final token = authState.session?.accessToken;
  // Validate token... if invalid, sign out
}
```

---

## 9. Summary Statistics

**Error Handling:**
- Display methods: 4 (SnackBar, Dialog, State, Provider)
- Error categories: 10+ (Auth, Network, Validation, Offline, MFA, Passkey, etc.)
- Specific error checks: 20+
- Error translation keys: 300+

**Translations:**
- Supported languages: 3 (English, Spanish, Hebrew)
- Total keys: 1000+
- English coverage: 100% (embedded)
- Spanish/Hebrew coverage: ⚠️ <50% (database)
- Real-time sync: Yes (Realtime channel per user)

**Key Services:**
- `LocalizationState` provider with 3-level fallback system
- `SecureSignUpService` with fraud detection
- `PasskeyAuthService` for biometric auth
- `TranslationCacheManager` for offline translations
- Multiple platform-specific implementations (web, iOS, Android, macOS, Linux, Windows)

---

## 10. For Adding/Improving Error Handling

### **Adding a new error message:**

1. **Add to defaults** in `locale_provider.dart`:
```dart
'myNewError': 'User-friendly error message here',
```

2. **Add to database** for each language:
```sql
INSERT INTO translations (locale, key, value) VALUES
  ('en', 'myNewError', 'User-friendly error message here'),
  ('es', 'myNewError', 'Mensaje de error amigable aquí'),
  ('he', 'myNewError', 'הודעת שגיאה ידידותית כאן');
```

3. **Display in UI:**
```dart
// SnackBar
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text(l10n.getString('myNewError'))),
);

// Dialog
showDialog(..., builder: (_) => AlertDialog(
  title: Text(l10n.getString('myNewError')),
  ...
));

// Form error
setState(() { _errorMessage = l10n.getString('myNewError'); });
```

---

**Document created:** April 13, 2026
