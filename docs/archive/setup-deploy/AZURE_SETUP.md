# Azure App Registration Setup for Outlook Calendar Sync

To enable Outlook Calendar sync with support for both Work/School and Personal (Hotmail/Outlook.com) accounts, your Azure App Registration must be configured correctly.

## 1. Supported Account Types (Manifest)

If you encounter the error **"Application must accept Access Token Version 2"** or **"You can't sign in here with a personal account"**, you must update the **Manifest** in the Azure Portal.

1. Go to [Azure Portal](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade) -> Select your App.
2. Click **Manifest** in the left menu.
3. Locate the **Manifest** JSON editor.
4. If `accessTokenAcceptedVersion` is missing, **add it** at the top level of the JSON object.
5. Update or add the fields as follows:

```json
{
	"id": "...",
	"accessTokenAcceptedVersion": 2,
	"signInAudience": "AzureADandPersonalMicrosoftAccount",
	...
}
```

**Note:** You must set `accessTokenAcceptedVersion` to `2` *before* or *at the same time* as changing the `signInAudience`.

## 2. Platform Configuration (SPA)

1. Go to **Authentication** in the left menu.
2. Ensure you have added the **Single-page application** platform.
3. Add your Redirect URIs:
   - `http://localhost:5000` (for local development)
   - `https://your-production-domain.com`

## 3. API Permissions

Ensure the following **Microsoft Graph** permissions are added and granted:
- `User.Read`
- `Calendars.Read`
- `offline_access`
