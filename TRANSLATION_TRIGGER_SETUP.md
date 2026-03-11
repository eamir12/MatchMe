# Server-Side Auto-Translation Setup with DeepL

## Overview

Messages are now translated **automatically on the server** using DeepL when they're inserted into `chat_messages`. Since you're already using DeepL in your app, the translation API is already configured and ready to use.

**Benefits:**
- ✅ Single source of truth - message translated once on server
- ✅ Background notifications show translated text immediately
- ✅ No app-side translation needed (but still works as fallback)
- ✅ Non-blocking - if translation fails, message still inserts
- ✅ Uses the same DeepL setup you already have

## How It Works

1. **Message arrives** from User A → inserted into `chat_messages` table
2. **Trigger fires** BEFORE INSERT
3. **Trigger checks:**
   - Is translation enabled for this chat?
   - Is there a target language set?
   - Is the message long enough to translate?
4. **Trigger calls** DeepL API (same as your app does)
5. **Translation is saved** to `content_translated` immediately
6. **Message is inserted** with translation included
7. **RPC query** returns translated message to User B's background service
8. **Notification shows** translated text right away

## Quick Deployment

### Step 1: Apply the Migration

The migration file `20260106004000_auto_translate_messages_on_insert.sql` creates the trigger function.

Apply it via Supabase:
1. Go to **SQL Editor** in Supabase Dashboard
2. Create a **New Query**
3. Copy and paste the entire migration file
4. Click **Run**

That's it! The trigger will use your existing DeepL configuration.

### Step 2: Verify Configuration

The trigger looks for the DeepL API key via `current_setting('app.deepl_api_key', true)`. If you already have it configured for your app, it should work. If not, set it:

```sql
SELECT set_config('app.deepl_api_key', 'YOUR_DEEPL_API_KEY', false);
```

### Step 3: Test It

Send a message from User A to User B (who has translation enabled):

1. **Check the database** to see if translation was saved:
```sql
SELECT id, content_original, content_translated 
FROM chat_messages 
ORDER BY created_at DESC 
LIMIT 1;
```

2. **Check the notification** - should show translated text

3. **Check for errors** in Supabase logs (Logs → Function Logs) if translation doesn't work

## Endpoint Configuration

The trigger uses the free tier endpoint: `https://api-free.deepl.com/v1/translate`

If you're using DeepL Pro, make sure to update the endpoint in the trigger function:
- Find this line: `'https://api-free.deepl.com/v1/translate',`
- Replace with: `'https://api.deepl.com/v1/translate',`

## Rolling Back (If Needed)

If you need to disable the trigger temporarily:

```sql
DROP TRIGGER auto_translate_on_insert ON chat_messages;
```

To re-enable:

```sql
CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();
```

## Important Notes

- **Non-blocking**: If the API call fails, the message still inserts
- **Error handling**: Failures are logged but don't prevent message delivery
- **Fallback**: If translation fails on server, the client-side translation provider still works
- **Performance**: HTTP calls add ~200-500ms latency to message insertion

## Context & Gender Hints

The translate proxy now attempts to pass small machine-readable context hints to DeepL to improve chat translation quality (especially for gendered languages like Hebrew):

- **speaker_gender** and **recipient_gender** are inferred from the sender and recipient user records (when available) and passed as `context` to DeepL (e.g., `"speaker_gender: female; recipient_gender: male; tone: informal"`).
- A simple **count** hint is added if a small integer appears in the message (e.g., `count: 5`).
- This helps DeepL produce correct verb conjugations and pronouns without modifying the user-visible source text.

Notes:
- The proxy respects an explicit `context` parameter if supplied by a direct API call (useful for testing or edge cases).
- We intentionally do not inject parenthetical markers into the user-visible text (e.g., `(female)`) because that produces literal text in translations.

## Monitoring

To check recent translations:
```sql
SELECT 
  id, 
  content_original, 
  content_translated,
  created_at
FROM chat_messages
WHERE content_translated IS NOT NULL
ORDER BY created_at DESC
LIMIT 10;
```
