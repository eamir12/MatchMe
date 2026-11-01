-- One-time Basics notice: name, birthday and gender are set once.
--
-- The wizard shows a tappable info banner on the Basics page during the
-- initial run, plus a dialog on first arrival and a confirmation gate on
-- Next. The lock itself is enforced server-side by the
-- enforce_basic_details_one_time_edit trigger (20260225180000) - these rows
-- only explain it, so the copy must not promise anything the trigger does
-- not do: an unlock is possible through an admin-approved request.
--
-- Keys:
--   profileBasicsOneTimeBannerTitle / profileBasicsOneTimeBannerBody
--   profileBasicsOneTimeDialogTitle / profileBasicsOneTimeDialogBody /
--   profileBasicsOneTimeDialogOk
--   profileBasicsOneTimeConfirmTitle / profileBasicsOneTimeConfirmBody /
--   profileBasicsOneTimeConfirmCta
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileBasicsOneTimeBannerTitle', $$Name, birthday & gender can be set only once$$),
  ('en', 'profileBasicsOneTimeBannerBody', $$Once you confirm these details, they can't be changed later.$$),
  ('en', 'profileBasicsOneTimeDialogTitle', $$One-time details$$),
  ('en', 'profileBasicsOneTimeDialogBody', $$You can enter your name, birthday and gender once. After you confirm, they can't be changed later without approval from our team.$$),
  ('en', 'profileBasicsOneTimeDialogOk', $$I understand$$),
  ('en', 'profileBasicsOneTimeConfirmTitle', $$Confirm your details?$$),
  ('en', 'profileBasicsOneTimeConfirmBody', $$Your name, birthday and gender will be saved exactly as entered. Once you confirm, they can't be changed later without approval from our team.$$),
  ('en', 'profileBasicsOneTimeConfirmCta', $$Confirm$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'profileBasicsOneTimeBannerTitle', $$El nombre, el cumpleaños y el género solo se pueden definir una vez$$),
  ('es', 'profileBasicsOneTimeBannerBody', $$Una vez que confirmes estos datos, no se pueden cambiar después.$$),
  ('es', 'profileBasicsOneTimeDialogTitle', $$Datos de una sola vez$$),
  ('es', 'profileBasicsOneTimeDialogBody', $$Puedes introducir tu nombre, cumpleaños y género una sola vez. Una vez que los confirmes, no podrás cambiarlos después sin la aprobación de nuestro equipo.$$),
  ('es', 'profileBasicsOneTimeDialogOk', $$Entendido$$),
  ('es', 'profileBasicsOneTimeConfirmTitle', $$¿Confirmas tus datos?$$),
  ('es', 'profileBasicsOneTimeConfirmBody', $$Tu nombre, cumpleaños y género se guardarán tal como los has introducido. Una vez que los confirmes, no podrás cambiarlos después sin la aprobación de nuestro equipo.$$),
  ('es', 'profileBasicsOneTimeConfirmCta', $$Confirmar$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'profileBasicsOneTimeBannerTitle', $$שם, תאריך לידה ומגדר ניתן להגדיר פעם אחת בלבד$$),
  ('he', 'profileBasicsOneTimeBannerBody', $$לאחר אישור הפרטים לא ניתן יהיה לשנות אותם בהמשך.$$),
  ('he', 'profileBasicsOneTimeDialogTitle', $$פרטים חד-פעמיים$$),
  ('he', 'profileBasicsOneTimeDialogBody', $$ניתן להזין שם, תאריך לידה ומגדר פעם אחת בלבד. לאחר האישור לא ניתן יהיה לשנות אותם בהמשך ללא אישור מהצוות שלנו.$$),
  ('he', 'profileBasicsOneTimeDialogOk', $$הבנתי$$),
  ('he', 'profileBasicsOneTimeConfirmTitle', $$לאשר את הפרטים?$$),
  ('he', 'profileBasicsOneTimeConfirmBody', $$השם, תאריך הלידה והמגדר יישמרו בדיוק כפי שהוזנו. לאחר האישור לא ניתן יהיה לשנות אותם בהמשך ללא אישור מהצוות שלנו.$$),
  ('he', 'profileBasicsOneTimeConfirmCta', $$אישור$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;