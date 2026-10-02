-- Migration: Add translations for match chat-start extension feature
-- Purpose: All user-facing strings for the "Extend match time" feature come from the
--   translations table (en/es/he). English fallbacks are in lib/providers/locale_provider.dart::_defaultTranslations.
-- Reference: See supabase/migrations/20260830000000_add_height_mandatory_translations.sql for pattern.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'matchExtendButton', $$Extend$$),
  ('en', 'matchExtendConfirmTitle', $$Extend match time?$$),
  ('en', 'matchExtendConfirmBody', $$Add {duration} more time before this match expires? You can only extend once per match.$$) ,
  ('en', 'matchExtendConfirmBodyBoth', $$Add {duration} more time before this match expires? Both you and {name} can extend once, for the same amount.$$) ,
  ('en', 'matchExtendCancel', $$Cancel$$),
  ('en', 'matchExtendConfirm', $$Extend$$),
  ('en', 'matchExtendSuccess', $$Match extended by {duration}. New time left: {remaining}.$$),
  ('en', 'matchExtendSuccessTitle', $$Match extended$$),
  ('en', 'matchExtendAlreadyExtended', $$You have already extended this match.$$),
  ('en', 'matchExtendOtherExtended', $${name} has already extended this match.$$),
  ('en', 'matchExtendBothExtended', $$Both of you have extended this match.$$),
  ('en', 'matchExtendChatStarted', $$A chat has already started, so this match will no longer expire.$$),
  ('en', 'matchExtendExpired', $$This match has already expired.$$),
  ('en', 'matchExtendError', $$Could not extend the match. Please try again.$$),
  ('en', 'matchExtendMaxReached', $$This match cannot be extended further.$$),
  ('en', 'matchExtendTimeLeftExtended', $$Extended time left: {time}$$) ,
  ('en', 'matchExtendLabel', $$Extend time$$),
  ('en', 'matchExtendHint', $$Add more time before the match expires$$),
  ('en', 'matchExtendedBadge', $$Extended$$),
  ('en', 'matchExtendedByYou', $$Extended by you$$),
  ('en', 'matchExtendedByOther', $$Extended by {name}$$),
  ('en', 'matchExtensionDurationHours', $${count} hour$$),
  ('en', 'matchExtensionDurationHoursPlural', $${count} hours$$),
  ('en', 'matchExtensionDurationMinutes', $${count} minute$$),
  ('en', 'matchExtensionDurationMinutesPlural', $${count} minutes$$),
  ('en', 'matchExtensionDurationDays', $${count} day$$),
  ('en', 'matchExtensionDurationDaysPlural', $${count} days$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish
  ('es', 'matchExtendButton', $$Extender$$),
  ('es', 'matchExtendConfirmTitle', $$¿Extender el tiempo del match?$$),
  ('es', 'matchExtendConfirmBody', $$¿Añadir {duration} más antes de que expire este match? Solo puedes extender una vez por match.$$),
  ('es', 'matchExtendConfirmBodyBoth', $$¿Añadir {duration} más antes de que expire este match? Tanto tú como {name} podéis extender una vez, por la misma cantidad.$$),
  ('es', 'matchExtendCancel', $$Cancelar$$),
  ('es', 'matchExtendConfirm', $$Extender$$),
  ('es', 'matchExtendSuccess', $$Match extendido por {duration}. Nuevo tiempo restante: {remaining}.$$),
  ('es', 'matchExtendSuccessTitle', $$Match extendido$$),
  ('es', 'matchExtendAlreadyExtended', $$Ya has extendido este match.$$),
  ('es', 'matchExtendOtherExtended', $${name} ya ha extendido este match.$$),
  ('es', 'matchExtendBothExtended', $$Ambos habéis extendido este match.$$),
  ('es', 'matchExtendChatStarted', $$Ya se ha iniciado un chat, por lo que este match ya no expirará.$$),
  ('es', 'matchExtendExpired', $$Este match ya ha expirado.$$),
  ('es', 'matchExtendError', $$No se pudo extender el match. Inténtalo de nuevo.$$),
  ('es', 'matchExtendMaxReached', $$Este match no se puede extender más.$$),
  ('es', 'matchExtendTimeLeftExtended', $$Tiempo restante extendido: {time}$$),
  ('es', 'matchExtendLabel', $$Extender tiempo$$),
  ('es', 'matchExtendHint', $$Añade más tiempo antes de que expire el match$$),
  ('es', 'matchExtendedBadge', $$Extendido$$),
  ('es', 'matchExtendedByYou', $$Extendido por ti$$),
  ('es', 'matchExtendedByOther', $$Extendido por {name}$$),
  ('es', 'matchExtensionDurationHours', $${count} hora$$),
  ('es', 'matchExtensionDurationHoursPlural', $${count} horas$$),
  ('es', 'matchExtensionDurationMinutes', $${count} minuto$$),
  ('es', 'matchExtensionDurationMinutesPlural', $${count} minutos$$),
  ('es', 'matchExtensionDurationDays', $${count} día$$),
  ('es', 'matchExtensionDurationDaysPlural', $${count} días$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew
  ('he', 'matchExtendButton', $$הארך$$),
  ('he', 'matchExtendConfirmTitle', $$להאריך את זמן ההתאמה?$$),
  ('he', 'matchExtendConfirmBody', $$להוסיף {duration} נוספים לפני שההתאמה תפוג? ניתן להאריך פעם אחת בלבד לכל התאמה.$$),
  ('he', 'matchExtendConfirmBodyBoth', $$להוסיף {duration} נוספים לפני שההתאמה תפוג? גם אתה וגם {name} יכולים להאריך פעם אחת, לאותו משך זמן.$$),
  ('he', 'matchExtendCancel', $$ביטול$$),
  ('he', 'matchExtendConfirm', $$הארך$$),
  ('he', 'matchExtendSuccess', $$ההתאמה הוארכה ב-{duration}. זמן שנותר חדש: {remaining}.$$),
  ('he', 'matchExtendSuccessTitle', $$ההתאמה הוארכה$$),
  ('he', 'matchExtendAlreadyExtended', $$כבר הארכת את ההתאמה הזו.$$),
  ('he', 'matchExtendOtherExtended', $${name} כבר האריך את ההתאמה הזו.$$),
  ('he', 'matchExtendBothExtended', $$שניכם הארכתם את ההתאמה הזו.$$),
  ('he', 'matchExtendChatStarted', $$כבר התחיל צ׳אט, לכן ההתאמה הזו לא תפוג עוד.$$),
  ('he', 'matchExtendExpired', $$ההתאמה הזו כבר פגה.$$),
  ('he', 'matchExtendError', $$לא ניתן להאריך את ההתאמה. נסה שוב.$$),
  ('he', 'matchExtendMaxReached', $$לא ניתן להאריך את ההתאמה הזו יותר.$$),
  ('he', 'matchExtendTimeLeftExtended', $$זמן שנותר מוארך: {time}$$),
  ('he', 'matchExtendLabel', $$הארך זמן$$),
  ('he', 'matchExtendHint', $$הוסף עוד זמן לפני שההתאמה פגה$$),
  ('he', 'matchExtendedBadge', $$הוארך$$),
  ('he', 'matchExtendedByYou', $$הוארך על ידך$$),
  ('he', 'matchExtendedByOther', $$הוארך על ידי {name}$$),
  ('he', 'matchExtensionDurationHours', $${count} שעה$$),
  ('he', 'matchExtensionDurationHoursPlural', $${count} שעות$$),
  ('he', 'matchExtensionDurationMinutes', $${count} דקה$$),
  ('he', 'matchExtensionDurationMinutesPlural', $${count} דקות$$),
  ('he', 'matchExtensionDurationDays', $${count} יום$$),
  ('he', 'matchExtensionDurationDaysPlural', $${count} ימים$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
