-- Update onboarding narrations that changed in locale_provider.dart.
-- This migration overrides the base values with the current fallbacks.
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).
-- Table: public.translations(locale, key, value)

-- English updates
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatHome3', 'Below, your most recent matches and chats are waiting, so you can pick up right where you left off. Filter both by intent — friends, dating, or both.'),
  ('en', 'onboardingBeatNearby1', 'The nearby map shows the match radius circle around your location… Only online and visible members inside this circle appear in your matches.'),
  ('en', 'onboardingBeatNearby2', 'The showing pill tracks how many online members are within your distance in this area… This count updates as people come and go.'),
  ('en', 'onboardingBeatNearby3', 'Nobody sees your exact location… Others only see an approximate distance within the circle, and only when you are visible.'),
  ('en', 'onboardingBeatMatches2', 'Matches last 24 hours by default… The countdown timer on each card shows how long you have to say hello. Either of you can tap Extend for extra time… and once you start chatting, the match never expires.'),
  ('en', 'onboardingBeatMatches3', 'Sort your matches, and tap a card to view the full profile before starting a chat.'),
  ('en', 'onboardingBeatMatches4', 'Use these intent filters — the same ones from your profile — to narrow matches to friends, dating, or both. These same filters also apply in Chats.'),
  ('en', 'onboardingBeatChats1', 'All your conversations live here… Unread chats are highlighted, and you can filter them by intent — the same filters as in Matches.'),
  ('en', 'onboardingBeatChats2', 'Messages are end to end encrypted, so your conversations stay private… They can even be translated automatically, so language is never a barrier. You can block or report anyone, and share your live location with one match at a time.'),
  ('en', 'onboardingBeatEvents1', 'Events are created by the community… Import from your calendar, upload a PDF ticket, paste an event link, or create one manually. Members who share your interests will show up here.'),
  ('en', 'onboardingBeatEvents2', 'Bring your plans with you… Import events from Google, Outlook, Apple or device calendar into MatchMe, then meet members going too.'),
  ('en', 'onboardingBeatProfile1', 'This is how others see you… AI-generated photos following the app photo rules, your age and bio, and your interests. A complete profile gets far more attention.'),
  ('en', 'onboardingBeatProfile2', 'You earned a Verified badge by completing the verification procedure from Settings… This badge shows on your profile and whenever others see you.'),
  ('en', 'onboardingBeatProfile3', 'Tap edit any time to update your photos or details through the same wizard you already know.'),
  ('en', 'onboardingBeatSettings1', 'Open settings with the gear icon at the top of the screen.'),
  ('en', 'onboardingBeatSettings2', 'Under Matching, you control the search distance and the matching modes. Tap to see all matching controls in one place.'),
  ('en', 'onboardingBeatSettings3', 'Under Match Preferences, you set the age range, gender preference, and lifestyle filters… These directly determine who can match with you.'),
  ('en', 'onboardingBeatSettings4', 'Under Invisibility Rules, you choose when you are automatically invisible… at work, at home, or on a schedule.'),
  ('en', 'onboardingBeatSettings5', 'Verification is launched from here… Complete a live selfie check to earn the Verified badge that appears on your profile and when others see you.'),
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
