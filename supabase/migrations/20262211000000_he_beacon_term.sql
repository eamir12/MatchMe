-- Hebrew meet-up terminology: beacon is איתות, not משואה.
--
-- The Hebrew meet-up copy was written with משואה for the beacon, while the newer
-- keys (inboxTypeMeetupBeacon, meetupBeaconPushBody, meetupFindEachOtherBody,
-- meetupHubBeacon* and settingsNotificationsMeetupToolsDesc) use איתות. איתות is
-- the correct term, so the older rows are brought in line with it here.
--
-- This is not a literal search-and-replace: משואה is feminine and איתות is
-- masculine, so the rows whose grammar agrees with the noun have to be
-- re-inflected — meetupBeaconActiveTitle becomes האיתות פעיל, meetupBeaconExpired
-- becomes האיתות הזה פג, and meetupBeaconExpires, which names no noun but answers
-- "what turns off", becomes יכבה בעוד {seconds} שנ׳. The remaining rows carry the
-- noun in a position that no adjective or verb has to agree with, and keep their
-- existing wording.
--
-- איתות does not collide with the gesture tool: the wave/signal copy already uses
-- תנועה, so both terms stay unambiguous. The English and Spanish rows are
-- untouched, and the English fallback in lib/providers/locale_provider.dart
-- keeps saying "Beacon".

INSERT INTO public.translations (locale, key, value) VALUES
('he', 'meetupBeacon', 'איתות'),
('he', 'meetupBeaconActiveTitle', 'האיתות פעיל'),
('he', 'meetupBeaconExpired', 'האיתות הזה פג.'),
('he', 'meetupBeaconExpires', 'יכבה בעוד {seconds} שנ׳'),
('he', 'meetupBeaconHide', 'הסתרת האיתות'),
('he', 'meetupBeaconIncomingTitle', '{name} מציג איתות'),
('he', 'meetupBannerBeacon', '{name} מציג איתות'),
('he', 'meetupBeaconRateLimited', 'המתינו רגע לפני הצגת האיתות שוב.'),
('he', 'meetupBeaconTapHint', 'אפשר לסמן, להציג איתות או לשתף כרטיס זיהוי לפני ואחרי בחירת נקודת מפגש.'),
('he', 'meetupEndCancelConfirmBody', 'המפגש יבוטל לשניכם והאיתות וכרטיסי הזיהוי יימחקו.'),
('he', 'meetupEndFoundConfirmBody', 'המפגש יסתיים לשניכם והאיתות וכרטיסי הזיהוי יימחקו.'),
('he', 'meetupActivityYourBeacon', 'האיתות שלכם')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
