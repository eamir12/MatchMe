# Translation Flow - Verified Implementation

## Requirement 1: Smart Retranslation on Language Switch
**WHEN:** User changes UI language  
**WHERE:** `lib/providers/locale_provider.dart:_retranslateAllMessages()`

**WHAT HAPPENS:**
1. ✅ Find all translation-enabled chats for current user
2. ✅ Validate each match exists and user is a participant
3. ✅ For each chat:
   - Get absolute last message (regardless of sender)
   - Get last incoming message (`.neq('sender_id', userId)`)
   - **ONLY** if last incoming IS absolute last:
     - Translate that message to new UI language via translate-proxy
     - Update chat-list preview immediately
4. ✅ Clear cached translations for ALL OTHER incoming messages
   - This forces them to retranslate when chat is opened

**VERIFICATION:**
- Line 4200: Validates match exists and user is participant
- Line 4215-4230: Gets absolute last message
- Line 4235-4245: Gets last incoming message only (`.neq('sender_id', userId)`)
- Line 4250: Checks `isAlsoAbsoluteLast` before translating
- Line 4265+: Skips translation if not absolute last, but clears cache
- Line 2190-2208 (chat_provider.dart): Clears other messages but NOT the last

---

## Requirement 2: Lazy Per-Message Translation
**WHEN:** User opens chat and scrolls to view messages  
**WHERE:** `lib/providers/chat_provider.dart:translationFamilyProvider`

**WHAT HAPPENS:**
1. ✅ `translationFamilyProvider` is `FutureProvider.autoDispose.family`
   - Lazy evaluation: only called when a message is accessed
   - Auto-dispose: cleaned up when message is no longer displayed
2. ✅ Called from `_MessageBubble.build()` (chat_screen.dart:2166)
   - Only invoked when rendering visible bubbles
   - NOT pre-fetched for off-screen messages
3. ✅ Per-message Case A/B/C logic:
   - **Case B:** UI language == message source → Show original (no translation)
   - **Case C:** UI language == stored target → Reuse existing translation
   - **Case A:** UI != source AND UI != target → Translate on-demand

**VERIFICATION:**
- Line 2592 (chat_provider.dart): Family provider definition
- Line 2166 (chat_screen.dart): Called from `_MessageBubble.build()`
- Line 2908-2911: Case A translation only when viewed
- Line 3103: `TranslationProxy.invoke()` only called in Case A

---

## Data Flow Summary

### On Language Switch (Immediate)
```
User changes language
  ↓
_retranslateAllMessages() runs:
  ├─ For each translation-enabled chat:
  │  ├─ Get absolute last message
  │  ├─ Get last incoming message
  │  └─ If last_incoming == absolute_last:
  │     └─ Translate via translate-proxy → chat-list preview updates
  │
  └─ Clear cached translations for all other incoming messages
     (forces re-evaluation next time chat is opened)
```

### When User Opens Chat (Lazy)
```
User opens chat → scrolls to view messages
  ↓
Message bubble renders
  ↓
translationFamilyProvider[messageId] evaluated:
  ├─ Case B: Show original (if UI == source)
  ├─ Case C: Reuse translation (if UI == stored target)
  └─ Case A: Fetch+translate on-demand (if UI != source && UI != target)
```

### Offline/Reconnect
```
translate-proxy becomes available
  ↓
translationVersionProvider.increment() triggers refresh
  ↓
Visible message bubbles re-evaluate translationFamilyProvider
  ↓
Case A translations fetch from translate-proxy
```

---

## Authorization & Validation

### At Language Switch
✅ Match validation (line 4200): Verify user is participant before translation attempt  
✅ 403 error handling (chat_provider.dart line 2180): Catches orphaned matches, logs CRITICAL, skips

### During Per-Message Translation
✅ Chat screen (translationFamilyProvider): Only translates incoming messages (checks `senderId`)  
✅ No pre-fetching: Messages only translate when rendered, not proactively

---

## Configuration Options (None Required)
- ✅ Default behavior: Smart retranslation on absolute-last, lazy on others
- ✅ No feature flags or config needed
- ✅ Works with both encrypted and non-encrypted messages
