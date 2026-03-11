# Outlook Calendar Integration - Cross-Platform Support

## Overview
This document explains how Outlook calendar integration works across all platforms (web, Android, iOS).

## Architecture

### Platform-Specific Implementations

#### Web Platform
- **Library**: Microsoft MSAL.js v2.38.3
- **File**: `lib/services/outlook_web_auth.dart`
- **Authentication Flow**:
  1. Initialize MSAL PublicClientApplication with Azure AD config
  2. Interactive login via popup (`loginPopup`)
  3. Silent token refresh (`acquireTokenSilent`)
  4. Fallback to popup if silent fails (`acquireTokenPopup`)

#### Mobile Platforms (Android/iOS)
- **Package**: `aad_oauth: ^1.0.1`
- **Authentication Flow**:
  1. Native OAuth flow via `aad_oauth` package
  2. Standard token refresh mechanism

### Configuration

#### Azure AD App Registration
Required environment variables in `.env`:
```
OUTLOOK_TENANT_ID=<your-tenant-id>
OUTLOOK_CLIENT_ID=<your-client-id>
OUTLOOK_REDIRECT_URI=<your-redirect-uri>
```

#### Web Configuration
MSAL.js library is loaded in `web/index.html`:
```html
<script src="https://alcdn.msauth.net/browser/2.38.3/js/msal-browser.min.js"></script>
```

### Implementation Details

#### OutlookWebAuth Service
Key methods:
- `initialize()`: Sets up MSAL with Azure AD configuration
- `signIn()`: Interactive login with popup
- `getAccessToken()`: Silent token acquisition with fallback to popup
- `signOut()`: Logout via popup

#### CalendarSyncService Integration
The service automatically detects the platform and uses the appropriate OAuth implementation:

```dart
if (kIsWeb) {
  // Use MSAL.js via OutlookWebAuth
  await OutlookWebAuth.instance.initialize(...);
  final token = await OutlookWebAuth.instance.signIn();
} else {
  // Use aad_oauth for mobile
  final oauth = AadOAuth(config);
  final result = await oauth.login();
}
```

### Token Management

#### Caching
- Tokens are cached in SharedPreferences
- Web: MSAL.js also maintains its own localStorage cache
- Mobile: Token cached locally

#### Expiration
- Tokens expire after 1 hour (Microsoft standard)
- 5-minute buffer before expiry for refresh
- Automatic silent refresh on web
- Manual refresh on mobile

### API Scopes
Required Microsoft Graph API scopes:
- `https://graph.microsoft.com/User.Read` - Basic user info
- `https://graph.microsoft.com/Calendars.Read` - Read calendar events
- `offline_access` - Refresh token support

### Error Handling
- Platform detection prevents unsupported operations
- Graceful fallback from silent to interactive auth
- User-friendly error messages via CalendarSyncException

## Testing

### Web Testing
1. Run app in Chrome: `flutter run -d chrome`
2. Navigate to calendar sync settings
3. Click "Connect Outlook Calendar"
4. MSAL popup should appear for Microsoft login
5. After auth, calendars should be retrieved via Graph API

### Mobile Testing
1. Run on Android/iOS device or simulator
2. Navigate to calendar sync settings
3. Click "Connect Outlook Calendar"
4. Native OAuth flow should launch
5. After auth, calendars should sync

## Troubleshooting

### Web Issues
- **MSAL not found**: Check that script is loaded in index.html
- **Popup blocked**: Ensure browser allows popups for the app
- **Token not acquired**: Check browser console for MSAL errors
- **CORS errors**: Verify redirect URI matches Azure AD config

### Mobile Issues
- **aad_oauth errors**: Ensure package is properly installed
- **Auth fails**: Verify Azure AD app supports mobile redirect URIs
- **Token refresh fails**: Check token expiry and refresh logic

## Future Enhancements
- Support for calendar write operations (create/update/delete events)
- Offline calendar sync with background refresh
- Multiple calendar account support
- Calendar event notifications
