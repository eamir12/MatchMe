# Server-Side Translation - Client Code Cleanup

## Status: ⚠️ NEEDS CLEANUP

The system is now doing **server-side translation via webhooks**, but there is still **old client-side translation code** that should be removed or disabled.

## What's Running Now (Server-Side - CORRECT):

1. **Message inserted** → chat_messages table
2. **Webhook fires** → calls `translate-proxy` Edge Function  
3. **`translate-proxy` translates** the message using DeepL
4. **Translation saved** to `content_translated` column
5. **Client receives** translated message from database

## What Needs to Be Removed (Client-Side - OLD):

### 1. `translationFamilyProvider` (lib/providers/translation_family_provider.dart)
- This provider does client-side real-time translation
- **Status:** Being called in multiple places but is now redundant
- **Action:** Can be removed or disabled since server handles translation
- **Locations used:**
  - lib/screens/chats/chat_screen.dart:983
  - lib/providers/home_providers.dart:232
  - lib/providers/chat_provider.dart:335, 389

### 2. Translation Function Calls in chat_provider.dart (lines ~1360-1410)
- Calls `translate-message` Edge Function
- Makes direct database updates
- **Status:** Redundant - server already doing this via webhook
- **Action:** Should be removed

### 3. Direct Message Translation Updates in home_providers.dart (lines ~203-210, ~499-516)
- Updates `content_translated` directly
- **Status:** Conflicts with server-side translation
- **Action:** Should be removed

## Verification Checklist:

- [ ] Remove `translationFamilyProvider` calls from chat_screen.dart
- [ ] Remove `translate-message` Edge Function calls from chat_provider.dart
- [ ] Remove direct `content_translated` updates from home_providers.dart  
- [ ] Test that messages still appear translated when received
- [ ] Verify no duplicate translations or race conditions

## Result After Cleanup:

The client will:
1. Send message with just `content_original`
2. Receive message with `content_translated` already populated by server
3. Display `content_translated` if available, else `content_original`
4. No client-side translation logic needed
