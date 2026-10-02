-- Onboarding tour fourth feedback round.
--  * Nearby is a single beat: one circle (the match radius), one dot per
--    online and visible member, uniform dot size, no counts anywhere, and
--    the privacy note in the same breath.
--  * The online world map is a single beat: the total pill plus one label
--    per country sitting on its country.
--  * Settings now walks every sub-screen top to bottom: entry, tour,
--    display, matching, preferences, invisibility, notifications, premium,
--    billing, invite, verification, security, account.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatNearby1', 'This map shows your match radius circle… Each dot is one online and visible member inside it — the blue marker is you. Nobody sees your exact location… others only see an approximate distance, and only when you are visible.'),
  ('en', 'onboardingBeatWorldMap1', 'This is the online world map, opened from your home screen… The pill up top shows how many members are online, and each label counts them by country, so you can see where the community is most active.'),
  ('en', 'onboardingBeatSettingsTour', 'Start with the app tour… replay this guided walkthrough any time you want a refresher.'),
  ('en', 'onboardingBeatSettingsDisplay', 'Under App display, you change the language, the theme, and voice guidance… This tour speaks in your language too.'),
  ('en', 'onboardingBeatSettingsNotifs', 'Under Notifications, you choose what reaches you… new matches, messages, and announcements, each with its own push, sound, and vibration.'),
  ('en', 'onboardingBeatSettingsPaywall', 'Under Premium, you compare the Free, Plus, Gold, and Platinum tiers… and unlock extra features.'),
  ('en', 'onboardingBeatSettingsBilling', 'Under Billing, you manage payment methods and redeem promo codes…'),
  ('en', 'onboardingBeatSettingsInvite', 'Under Invite friends, you share your referral link… and earn rewards for you both.'),
  ('en', 'onboardingBeatSettingsSecurity', 'Under Security, you sign in with passkeys and protect your account with an authenticator app and recovery codes.'),
  ('en', 'onboardingBeatSettingsAccount', 'Under Account, you change your email and manage your account details…')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatNearby1', 'Este mapa muestra tu círculo de radio… Cada punto es un miembro en línea y visible dentro de él; el marcador azul eres tú. Nadie ve tu ubicación exacta… los demás solo ven una distancia aproximada, y solo cuando eres visible.'),
  ('es', 'onboardingBeatWorldMap1', 'Este es el mapa mundial en línea, abierto desde tu pantalla de inicio… La píldora de arriba muestra cuántos miembros están en línea, y cada etiqueta los cuenta por país, así ves dónde está más activa la comunidad.'),
  ('es', 'onboardingBeatSettingsTour', 'Empieza con el recorrido de la app… repite esta visita guiada cuando quieras repasar.'),
  ('es', 'onboardingBeatSettingsDisplay', 'Aquí puedes cambiar el idioma, el tema y la guía de voz… Este recorrido también habla tu idioma.'),
  ('es', 'onboardingBeatSettingsNotifs', 'En las notificaciones, eliges lo que te llega… nuevas coincidencias, mensajes y anuncios, cada uno con su aviso, sonido y vibración.'),
  ('es', 'onboardingBeatSettingsPaywall', 'En Premium, comparas los niveles Gratis, Plus, Oro y Platino… y desbloqueas funciones extra.'),
  ('es', 'onboardingBeatSettingsBilling', 'En la facturación, gestionas los métodos de pago y canjeas códigos promocionales…'),
  ('es', 'onboardingBeatSettingsInvite', 'En Invitar amigos, compartes tu enlace de referidos… y ganas recompensas para ambos.'),
  ('es', 'onboardingBeatSettingsSecurity', 'En Seguridad, inicias sesión con llaves de acceso y proteges tu cuenta con una app de autenticación y códigos de recuperación.'),
  ('es', 'onboardingBeatSettingsAccount', 'En la cuenta, cambias tu correo y gestionas los detalles de tu cuenta…')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatNearby1', 'המפה הזו מראה את מעגל הרדיוס שלכם… כל נקודה היא חבר מקוון וגלוי בתוכו; הסמן הכחול זה אתם. אף אחד לא רואה את המיקום המדויק שלכם… האחרים רואים רק מרחק משוער, ורק כשאתם גלויים.'),
  ('he', 'onboardingBeatWorldMap1', 'זוהי מפת העולם המקוונת, שנפתחת ממסך הבית שלכם… הבועה למעלה מראה כמה חברים מקוונים, וכל תווית סופרת אותם לפי מדינה, כך אתם רואים איפה הקהילה הכי פעילה.'),
  ('he', 'onboardingBeatSettingsTour', 'התחילו בסיור באפליקציה… חזרו על ההדרכה הזו בכל עת שתרצו לרענן.'),
  ('he', 'onboardingBeatSettingsDisplay', 'כאן אפשר להחליף שפה, ערכת נושא והדרכה קולית… הסיור הזה מדבר גם בשפה שלכם.'),
  ('he', 'onboardingBeatSettingsNotifs', 'תחת התראות אתם בוחרים מה מגיע אליכם… התאמות חדשות, הודעות והודעות, כל אחד עם התראה, צליל ורטט משלו.'),
  ('he', 'onboardingBeatSettingsPaywall', 'תחת פרימיום תוכלו להשוות בין המסלולים חינם, פלוס, גולד ופלטינום… ולפתוח תכונות נוספות.'),
  ('he', 'onboardingBeatSettingsBilling', 'תחת חיוב תוכלו לנהל אמצעי תשלום ולממש קודי הטבה…'),
  ('he', 'onboardingBeatSettingsInvite', 'תחת הזמנת חברים תוכלו לשתף את קישור ההפניה שלכם… ולזכות בפרסים לשניכם.'),
  ('he', 'onboardingBeatSettingsSecurity', 'תחת אבטחה תוכלו להתחבר עם מפתחות גישה ולהגן על החשבון עם אפליקציית אימות וקודי שחזור.'),
  ('he', 'onboardingBeatSettingsAccount', 'תחת חשבון תוכלו להחליף כתובת דוא״ל ולנהל את פרטי החשבון…')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
