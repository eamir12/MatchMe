-- Meet-up hub: "How it works" explainers and duration-free copy.
--
-- The hub rows and tiles no longer print tool timers; each tool carries a How it
-- works entry that opens a one-feature explainer sheet ("Best for / They see /
-- You do / How it ends / Location"). The row titles reuse meetupHubPlanName and
-- meetupHubLiveName, which 20262166000000_meetup_hub_copy.sql already provides,
-- so meetupHubPlanTitle, meetupHubLiveTitle, meetupHubPlanSection,
-- meetupHubLiveSection, meetupHubNoticedTitle, meetupHubDetailsShow and
-- meetupHubDetailsHide lose their call sites; their rows are left in place
-- because deleting prod translation rows needs a separate decision.
--
-- The English fallback lives in lib/providers/locale_provider.dart; these rows
-- keep en/es/he aligned so an explainer never mixes a translated label with an
-- English value. The "Lasts" column becomes "How it ends" and its values stop
-- quoting timers, except live location, whose duration is the user's own choice.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupHubNothingYet', 'Nothing set yet'),
('es', 'meetupHubNothingYet', 'Nada acordado todavía'),
('he', 'meetupHubNothingYet', 'עוד לא נקבע כלום'),
('en', 'meetupHubHowItWorks', 'How it works'),
('es', 'meetupHubHowItWorks', 'Cómo funciona'),
('he', 'meetupHubHowItWorks', 'איך זה עובד'),
('en', 'meetupHubLiveIdle', 'Not sharing'),
('es', 'meetupHubLiveIdle', 'No se comparte'),
('he', 'meetupHubLiveIdle', 'לא משתפים'),
('en', 'meetupHubExplainYouDo', 'You do'),
('es', 'meetupHubExplainYouDo', 'Qué haces'),
('he', 'meetupHubExplainYouDo', 'מה אתם עושים'),
('en', 'meetupHubExplainNotNow', 'Not now'),
('es', 'meetupHubExplainNotNow', 'Ahora no'),
('he', 'meetupHubExplainNotNow', 'לא עכשיו'),
('en', 'meetupHubExplainPlanDo', 'Suggest places and pick one together'),
('es', 'meetupHubExplainPlanDo', 'Sugiere lugares y elijan uno juntos'),
('he', 'meetupHubExplainPlanDo', 'הציעו מקומות ובחרו אחד יחד'),
('en', 'meetupHubExplainLiveDo', 'Tap "Start sharing" and choose how long'),
('es', 'meetupHubExplainLiveDo', 'Toca "Empezar a compartir" y elige cuánto tiempo'),
('he', 'meetupHubExplainLiveDo', 'הקישו על "להתחיל שיתוף" ובחרו למשך כמה זמן'),
('en', 'meetupHubExplainSignalDo', 'Pick a gesture to show what you are doing'),
('es', 'meetupHubExplainSignalDo', 'Elige un gesto para mostrar qué estás haciendo'),
('he', 'meetupHubExplainSignalDo', 'בחרו תנועה שתראה מה אתם עושים'),
('en', 'meetupHubExplainBeaconDo', 'Hold your phone up, screen facing them'),
('es', 'meetupHubExplainBeaconDo', 'Levanta el teléfono con la pantalla hacia ellos'),
('he', 'meetupHubExplainBeaconDo', 'הרימו את הטלפון, המסך פונה אליהם'),
('en', 'meetupHubExplainSpotDo', 'Take a selfie, add what you wear, share'),
('es', 'meetupHubExplainSpotDo', 'Tómate una selfie, añade qué llevas puesto y comparte'),
('he', 'meetupHubExplainSpotDo', 'צלמו סלפי, הוסיפו מה אתם לובשים ושתפו'),
('en', 'meetupHubCompareLasts', 'How it ends'),
('es', 'meetupHubCompareLasts', 'Cómo termina'),
('he', 'meetupHubCompareLasts', 'איך זה נגמר'),
('en', 'meetupHubComparePlanLasts', 'You end it'),
('es', 'meetupHubComparePlanLasts', 'Tú lo terminas'),
('he', 'meetupHubComparePlanLasts', 'אתם מסיימים'),
('en', 'meetupHubCompareLiveLasts', 'Stops at the time you chose'),
('es', 'meetupHubCompareLiveLasts', 'Se detiene en el tiempo que elegiste'),
('he', 'meetupHubCompareLiveLasts', 'נעצר בזמן שבחרתם'),
('en', 'meetupHubCompareSignalLasts', 'Turns off on its own'),
('es', 'meetupHubCompareSignalLasts', 'Se apaga solo'),
('he', 'meetupHubCompareSignalLasts', 'נכבה מעצמו'),
('en', 'meetupHubCompareBeaconLasts', 'Turns off on its own, or you hide it'),
('es', 'meetupHubCompareBeaconLasts', 'Se apaga solo, o lo ocultas'),
('he', 'meetupHubCompareBeaconLasts', 'נכבה מעצמו, או שאתם מסתירים אותו'),
('en', 'meetupHubCompareSpotLasts', 'Goes away on its own, or you hide it'),
('es', 'meetupHubCompareSpotLasts', 'Desaparece solo, o lo ocultas'),
('he', 'meetupHubCompareSpotLasts', 'נעלם מעצמו, או שאתם מסתירים אותו')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
