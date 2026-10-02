# Error Localization - Quick Reference for Developers

## When to Use ErrorLocalizationService

✅ **USE** in catch blocks for any exception that will be shown to users:
```dart
try {
  await operation();
} catch (e) {
  final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
  showUserError(l10n.getString(errorKey));
}
```

❌ **DON'T** show raw exceptions:
```dart
catch (e) {
  showError(e.toString());  // WRONG - shows technical details
  showError(e.message);      // WRONG - shows technical details
  showError('${l10n.getString("label")}: $e');  // WRONG - raw error
}
```

## Common Error Mapping Examples

### Network Error
```dart
// Input: SocketException: Failed host lookup: 'example.com'
// Mapped to: 'networkErrorNoInternet'
// Shows user: "No internet connection. Please check your network and try again."
```

### Auth Error
```dart
// Input: AuthException: Invalid login credentials
// Mapped to: 'authIncorrectPassword'
// Shows user: "Incorrect password."
```

### Timeout
```dart
// Input: TimeoutException after 30 seconds
// Mapped to: 'networkErrorTimeout'
// Shows user: "The request timed out. Please check your internet connection and try again."
```

## Implementation Steps for New Screens

1. **Add Import**
```dart
import 'package:matchme/services/error_localization_service.dart';
```

2. **Use in Error Handler**
```dart
try {
  // Do something
} catch (e) {
  final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
  setState(() {
    _errorMessage = l10n.getString(errorKey);
  });
  // OR show in snackbar:
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.getString(errorKey)))
  );
}
```

3. **Test Each Path**
- Network error: Disable internet and perform action
- Auth error: Use wrong credentials
- Business logic error: Trigger via invalid input

## Supported Error Types

The ErrorLocalizationService automatically detects and maps:

### Network Errors
- Timeout errors → `networkErrorTimeout`
- Connection refused → `networkErrorConnectionFailed`
- DNS failures → `networkErrorNoInternet`
- SSL certificate errors → `networkErrorSSLCertificate`
- Generic network issues → `networkErrorGeneric`

### Authentication Errors
- Invalid credentials → `authIncorrectPassword`
- Email already registered → `authEmailAlreadyRegistered`
- Invalid email → `authEmailInvalid`
- Invalid OTP/code → `authInvalidCode`
- Code expired → `authCodeExpired`
- Session invalid → `authSessionInvalid`
- Session expired → `authSessionExpired`
- MFA required → `authMFARequired`
- OAuth errors → `authOAuthFailed` or `authOAuthAccessDenied`
- Rate limited → `authRateLimitExceeded`
- And 10+ more...

### Unknown Errors
Default fallback: `authUnexpectedError` → "Unexpected error"

## Adding New Error Types

If you encounter an error that's not mapped:

1. **Add Translation Key** to `lib/providers/locale_provider.dart`:
```dart
'myNewError': 'User-friendly error message here',
```

2. **Add Mapping** to `lib/services/error_localization_service.dart._mapAuthException()` or similar:
```dart
if (msg.contains('specific_error_text')) {
  return 'myNewError';
}
```

3. **Add Database Translations** to `add_error_localization_translations.sql`:
```sql
('es', 'myNewError', 'Mensaje amigable en español'),
('he', 'myNewError', 'הודעה ידידותית בעברית'),
```

## Remaining Files to Fix

Replace $e or e.toString() with error mapping in these files:

```
□ lib/screens/profile/profile_wizard_screen.dart (6 locations, lines 954, 1256, 2873, 2998, 3014, 3031)
□ lib/screens/auth/signup_email_code_screen.dart (3 locations, lines 127-128, 143-144, and similar)
□ lib/screens/home/home_screen.dart (2 locations, lines 329, 359)
□ lib/screens/nearby/nearby_map_screen.dart (3 locations, lines 288, 695, 835)
□ lib/screens/events/online_providers_screen.dart (2 locations, lines 578, 580)
```

## Testing Checklist

Before deploying changes:

- [ ] Remove internet connection → See "No internet connection" message
- [ ] Trigger network timeout → See timeout message
- [ ] Wrong password login → See "Incorrect password"
- [ ] Invalid email → See "Invalid email address"
- [ ] Rate limited → See "Too many requests" message
- [ ] Switch to Spanish → See Spanish translations
- [ ] Switch to Hebrew → See Hebrew translations (RTL text)
- [ ] Back online → App recovers and shows success

## Translation Management

All user-facing strings come from:
1. **Database** (primary) - Updated via Supabase
2. **Cache** (offline) - Updated on next online sync
3. **Code defaults** (fallback) - Embedded English

Never hardcode error messages in UI - always use `l10n.getString(key)`.
