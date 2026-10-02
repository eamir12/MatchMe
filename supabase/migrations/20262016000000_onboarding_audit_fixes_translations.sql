-- Onboarding tour audit fixes (en/es/he)
-- Corrects inaccurate narration and covers features the tour omitted:
--  * matches: 24-hour default (was "a few days"), one-time extension per
--    side, chatting removes expiry permanently
--  * events: calendar is one-way IMPORT (Google/Outlook/Apple/device) into
--    MatchMe, not "add to calendar"; creating via the plus button and
--    importing from link/ticket photo are now mentioned
--  * chats: edit/delete/reactions/read receipts/offline queue + block/report
--    safety and per-match live location sharing
--  * nearby: visibility toggle, invisibility rules, pinned home base
--  * settings: full matching filters (gender/height/lifestyle/family/
--    religion) + background matching, passkeys/authenticator/email security,
--    subscriptions + promo codes, granular notification controls
--  * finish: background matching + referrals
-- English values match the built-in fallbacks in locale_provider.dart.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatMatches2', 'Matches last 24 hours by default… The countdown on each card shows how long you have to say hello. Either of you can extend a match once for extra time… and once you start chatting, the match never expires.'),
  ('en', 'onboardingBeatNearby4', 'You are in control of being seen… Switch yourself invisible any time, set automatic invisibility rules for places or times, pin a home base instead of sharing live GPS, and share live location per match only while you choose.'),
  ('en', 'onboardingBeatChats3', 'Tap a chat to open it… Send messages, emojis, replies and reactions, edit or delete your own messages, and see read ticks and when the other person is typing… If you go offline, your messages wait in a queue and send when you are back.'),
  ('en', 'onboardingBeatChats4', 'Stay safe while chatting… You can block or report anyone from the chat menu, and share your live location with one match at a time, only for as long as you choose.'),
  ('en', 'onboardingBeatEvents1', 'Events let you meet people in person… Join something nearby, or tap the plus button to create your own event for members who share your interests. You can even import an event from a link, a ticket photo, or your calendar.'),
  ('en', 'onboardingBeatEvents2', 'Bring your plans with you… Import events from your Google, Outlook, Apple or device calendar into MatchMe, then meet members who are going too.'),
  ('en', 'onboardingBeatSettings2', 'Under matching, you set the distance, age range, gender, height, lifestyle, family plans and religion you are looking for… Background matching keeps finding people for you while you are away.'),
  ('en', 'onboardingBeatSettings4', 'Your security center lives here too… Sign in with passkeys, protect your account with an authenticator app and recovery codes, change your email, and manage your account.'),
  ('en', 'onboardingBeatSettings5', 'Subscriptions live here as well… Compare the Free, Plus, Gold and Platinum tiers, or redeem a promo code to unlock premium features.'),
  ('en', 'onboardingBeatSettings6', 'Under notifications, you choose exactly what reaches you… New matches, messages, expiring matches and announcements, each with its own push, sound and vibration… You can pause everything for a while when you need quiet.'),
  ('en', 'onboardingBeatFinish1', 'That is the end of the tour… Everything is ready for you. Matching keeps working quietly in the background, and inviting friends with your referral link earns rewards for you both… Explore at your own pace, and replay this tour any time from the settings screen.'),
  ('en', 'onboardingDemoAddToCalendar', 'Import from calendar')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatMatches2', 'Las coincidencias duran 24 horas por defecto… La cuenta regresiva en cada tarjeta muestra cuánto tiempo tienes para saludar. Cada uno puede extender una coincidencia una vez para tener más tiempo… y cuando empiezan a chatear, la coincidencia ya no caduca.'),
  ('es', 'onboardingBeatNearby4', 'Tú controlas tu visibilidad… Puedes volverte invisible en cualquier momento, crear reglas automáticas de invisibilidad para lugares u horarios, fijar una base en casa en vez de compartir tu GPS en vivo, y compartir tu ubicación en vivo con cada coincidencia solo mientras tú quieras.'),
  ('es', 'onboardingBeatChats3', 'Toca un chat para abrirlo… Envía mensajes, emojis, respuestas y reacciones, edita o elimina tus propios mensajes, y ve las confirmaciones de lectura y cuándo la otra persona está escribiendo… Si te quedas sin conexión, tus mensajes esperan en una cola y se envían cuando vuelves.'),
  ('es', 'onboardingBeatChats4', 'Mantente a salvo mientras chateas… Puedes bloquear o reportar a cualquiera desde el menú del chat, y compartir tu ubicación en vivo con una coincidencia a la vez, solo durante el tiempo que elijas.'),
  ('es', 'onboardingBeatEvents1', 'Los eventos te permiten conocer personas en persona… Únete a algo cerca, o toca el botón más para crear tu propio evento para miembros que comparten tus intereses. Incluso puedes importar un evento desde un enlace, una foto de tu boleto o tu calendario.'),
  ('es', 'onboardingBeatEvents2', 'Trae tus planes contigo… Importa eventos desde tu calendario de Google, Outlook, Apple o del dispositivo a MatchMe, y conoce a los miembros que también van.'),
  ('es', 'onboardingBeatSettings2', 'En Coincidencias, defines la distancia, el rango de edad, el género, la altura, el estilo de vida, los planes familiares y la religión que buscas… La búsqueda en segundo plano sigue encontrando personas para ti mientras estás fuera.'),
  ('es', 'onboardingBeatSettings4', 'Tu centro de seguridad también vive aquí… Inicia sesión con llaves de acceso, protege tu cuenta con una app de autenticación y códigos de recuperación, cambia tu correo y gestiona tu cuenta.'),
  ('es', 'onboardingBeatSettings5', 'Las suscripciones también viven aquí… Compara los niveles Gratis, Plus, Oro y Platino, o canjea un código promocional para desbloquear funciones premium.'),
  ('es', 'onboardingBeatSettings6', 'En notificaciones, tú eliges exactamente lo que te llega… Nuevas coincidencias, mensajes, coincidencias por vencer y anuncios, cada uno con su propio aviso, sonido y vibración… Puedes pausar todo por un tiempo cuando necesites tranquilidad.'),
  ('es', 'onboardingBeatFinish1', 'Este es el final del recorrido… Todo está listo para ti. La búsqueda sigue trabajando en silencio en segundo plano, e invitar amigos con tu enlace de referidos les da recompensas a ambos… Explora a tu ritmo, y repite este recorrido cuando quieras desde la pantalla de configuración.'),
  ('es', 'onboardingDemoAddToCalendar', 'Importar del calendario')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatMatches2', 'התאמות תקפות 24 שעות כברירת מחדל… הספירה לאחור בכל כרטיס מראה כמה זמן נותר לשלוח ברכה. כל אחד מכם יכול להאריך התאמה פעם אחת כדי לקבל עוד זמן… וברגע שמתחילים לשוחח, ההתאמה לא פגה יותר.'),
  ('he', 'onboardingBeatNearby4', 'אתם שולטים בנראות שלכם… אפשר להפוך לבלתי נראים בכל רגע, להגדיר כללי אי נראות אוטומטיים למקומות או לשעות, לנעוץ בסיס בית במקום לשתף GPS חי, ולשתף מיקום חי עם כל התאמה רק כל עוד תבחרו.'),
  ('he', 'onboardingBeatChats3', 'הקישו על שיחה כדי לפתוח אותה… שלחו הודעות, אימוג׳ים, תשובות ותגובות, ערכו או מחקו את ההודעות שלכם, וראו אישורי קריאה ומתי הצד השני מקליד… אם מתנתקים, ההודעות ממתינות בתור ונשלחות כשחוזרים.'),
  ('he', 'onboardingBeatChats4', 'שמרו על בטיחות בזמן השיחה… אפשר לחסום או לדווח על כל אחד מתפריט השיחה, ולשתף מיקום חי עם התאמה אחת בכל פעם, רק למשך הזמן שתבחרו.'),
  ('he', 'onboardingBeatEvents1', 'אירועים מאפשרים להיפגש פנים אל פנים… הצטרפו למשהו בסביבה, או הקישו על כפתור הפלוס כדי ליצור אירוע משלכם לחברים שחולקים את תחומי העניין שלכם. אפשר אפילו לייבא אירוע מקישור, מתמונת כרטיס או מהיומן שלכם.'),
  ('he', 'onboardingBeatEvents2', 'הביאו את התוכניות איתכם… ייבאו אירועים מיומן גוגל, אאוטלוק, אפל או מהמכשיר אל MatchMe, ואז פגשו חברים שמגיעים גם הם.'),
  ('he', 'onboardingBeatSettings2', 'תחת התאמות אתם מגדירים מרחק, גילאים, מגדר, גובה, סגנון חיים, תוכניות משפחה ודת… ההתאמה ברקע ממשיכה למצוא אנשים בשבילכם גם כשאתם לא כאן.'),
  ('he', 'onboardingBeatSettings4', 'מרכז האבטחה שלכם נמצא גם כאן… התחברו עם מפתחות גישה, הגנו על החשבון עם אפליקציית אימות וקודי שחזור, החליפו כתובת דוא״ל ונהלו את החשבון.'),
  ('he', 'onboardingBeatSettings5', 'המנויים נמצאים גם כאן… השוו בין המסלולים חינם, פלוס, גולד ופלטינום, או ממשו קוד הטבה כדי לפתוח תכונות פרימיום.'),
  ('he', 'onboardingBeatSettings6', 'תחת התראות אתם בוחרים בדיוק מה מגיע אליכם… התאמות חדשות, הודעות, התאמות שעומדות לפוג והודעות, כל אחד עם התראה, צליל ורטט משלו… אפשר להשהות הכול לזמן מה כשצריך שקט.'),
  ('he', 'onboardingBeatFinish1', 'זהו סוף הסיור… הכול מוכן בשבילכם. ההתאמה ממשיכה לעבוד בשקט ברקע, והזמנת חברים עם קישור ההפניה מזכה את שניכם בפרסים… חקרו בקצב שלכם, וחזרו על הסיור בכל עת ממסך ההגדרות.'),
  ('he', 'onboardingDemoAddToCalendar', 'ייבוא מהיומן')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
