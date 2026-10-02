# Debug Session: chat-retranslation-miss [OPEN]

## Symptom
- After switching the app UI language and reopening a translation-enabled chat, previously received incoming messages that are visible on screen are not shown translated in the new UI language.
- Logs show `translationFamilyProvider` reaching `Case A` for those messages, but the bubbles still render only the original text.

## Expected
- On entering the chat, all currently displayed incoming messages should show translations in the app's current UI language immediately after the translation flow completes.

## Reproduction
1. Open a translation-enabled chat with older incoming messages visible.
2. Switch UI language to another supported language.
3. Return to the chat.
4. Observe visible past incoming messages stay untranslated.

## Hypotheses
1. `TranslationProxy.invoke()` succeeds, but the follow-up fetch from `chat_messages` does not yet contain the new encrypted translation when the provider checks.
2. The encrypted translation is fetched, but `decryptMessageTranslatedContent()` returns `null` for the newly requested target language.
3. The provider gets a translated value, but `localDb.mergeMessages()` or `updateChatLastMessageTranslation()` is not persisting the translated payload used by the bubble UI.
4. The bubble render path receives a translated value, but `showTranslated` stays false because the translated text is not propagated into the watched provider result for the visible widget instance.
5. A concurrency guard (`isRunningForMessage`) or proxy cooldown path is causing the provider to exit before the translated result is written back.

## Evidence To Collect
- For one visible message: request target language, proxy call result, post-proxy fetch payload, decrypt result, local DB writeback status, and final rendered `translatedData`.

## Evidence Summary
- `A` rejected as root cause: the translate request usually succeeded and returned usable data.
- `B` rejected as root cause: post-request fetches contained encrypted payloads for the new target language, and decrypt succeeded.
- `C` rejected as root cause: local writeback completed for the translated messages.
- `D` rejected as root cause: when translation data arrived, the bubble render path set `showTranslated=true`.
- `E` confirmed as root cause: after a burst of per-bubble requests, `TranslationProxy` entered client cooldown and subsequent visible messages failed with `FunctionException(status: 403, details: {error: translate-proxy is unavailable (cooldown active)})`, after which the bubble render showed original-only content.

## Fix Applied
- Changed `translationFamilyProvider` to batch recent incoming message IDs for the current chat into a shared `translate-proxy` request during `Case A`, instead of sending one request per visible bubble.
- Kept the existing per-message fetch/decrypt/render flow after the shared batch completes, so the UI still resolves each bubble independently.

## Status
- Fix applied, awaiting verification.

## Fix Applied 2
- Isolated TranslationProxy cooldown state by request scope so chat message batches use a separate cooldown bucket from single-text translations elsewhere in the app.
- This prevents unrelated translation surfaces from poisoning chat retranslation after a UI language switch.

