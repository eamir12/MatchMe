-- Comprehensive fix: no abbreviations in user-facing text + all user-facing keys in translations table
-- Covers: age/height/distance/time/size units, Min/Max/Lang/Info/Avg/Sys, e.g./ej., s/ms/km/7d/10km,
--         hardcoded UI strings moved to translation keys, and missing keys backfilled.
-- Table: public.translations (locale, key, value)
-- Safe to re-run (upsert).

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- ============ MAIN APP: units / sizes / time (previously abbreviated) ============
  ('en', 'profileEditHeightHint', $$Height in centimeters (for example, 170)$$),
  ('es', 'profileEditHeightHint', $$Altura en centímetros (por ejemplo, 170)$$),
  ('he', 'profileEditHeightHint', $$גובה בסנטימטרים (למשל 170)$$),

  ('en', 'profileEditAttachmentTooLarge', $$File is too large. Maximum size is {maxMb} megabytes.$$),
  ('es', 'profileEditAttachmentTooLarge', $$El archivo es demasiado grande. El tamaño máximo es {maxMb} megabytes.$$),
  ('he', 'profileEditAttachmentTooLarge', $$הקובץ גדול מדי. הגודל המקסימלי הוא {maxMb} מגה-בייט.$$),

  ('en', 'settingsAccuracyMeters', $$Accuracy: ~{meters} meters$$),
  ('es', 'settingsAccuracyMeters', $$Precisión: ~{meters} metros$$),
  ('he', 'settingsAccuracyMeters', $$דיוק: ~{meters} מטרים$$),

  ('en', 'settingsLocationNameHint', $$For example: Home, Office, Gym$$),
  ('es', 'settingsLocationNameHint', $$Por ejemplo: Casa, Oficina, Gimnasio$$),
  ('he', 'settingsLocationNameHint', $$לדוגמה: בית, משרד, חדר כושר$$),

  ('en', 'settingsMfaEmailCodeResendIn', $$Resend in {seconds} seconds$$),
  ('es', 'settingsMfaEmailCodeResendIn', $$Reenviar en {seconds} segundos$$),
  ('he', 'settingsMfaEmailCodeResendIn', $$אפשר לשלוח שוב בעוד {seconds} שניות$$),

  -- ============ HEIGHT (feet / inches / centimeters — kept from prior fix) ============
  ('en', 'settingsHeightCm', $$centimeters$$),
  ('es', 'settingsHeightCm', $$centímetros$$),
  ('he', 'settingsHeightCm', $$סנטימטרים$$),

  ('en', 'profileHeightCm', $$centimeters$$),
  ('es', 'profileHeightCm', $$centímetros$$),
  ('he', 'profileHeightCm', $$סנטימטרים$$),

  ('en', 'profileHeightUnitCm', $$centimeters$$),
  ('es', 'profileHeightUnitCm', $$centímetros$$),
  ('he', 'profileHeightUnitCm', $$סנטימטרים$$),

  ('en', 'profileHeightUnitFeet', $$feet$$),
  ('es', 'profileHeightUnitFeet', $$pies$$),
  ('he', 'profileHeightUnitFeet', $$רגל$$),

  ('en', 'profileHeightUnitInches', $$inches$$),
  ('es', 'profileHeightUnitInches', $$pulgadas$$),
  ('he', 'profileHeightUnitInches', $$אינטש$$),

  ('en', 'profileHeightFeetInches', $${feet} feet {inches} inches$$),
  ('es', 'profileHeightFeetInches', $${feet} pies {inches} pulgadas$$),
  ('he', 'profileHeightFeetInches', $${feet} רגל {inches} אינטש$$),

  ('en', 'profileHeightInCm', $${cm} centimeters$$),
  ('es', 'profileHeightInCm', $${cm} centímetros$$),
  ('he', 'profileHeightInCm', $${cm} סנטימטרים$$),

  ('en', 'profileEditHeightInvalid', $$Height must be between 100 and 250 centimeters$$),
  ('es', 'profileEditHeightInvalid', $$La altura debe estar entre 100 y 250 centímetros$$),
  ('he', 'profileEditHeightInvalid', $$הגובה חייב להיות בין 100 ל-250 סנטימטרים$$),

  ('en', 'profileEditHeightInvalidFeet', $$Height must be between 3 feet 4 inches and 8 feet 2 inches$$),
  ('es', 'profileEditHeightInvalidFeet', $$La altura debe estar entre 3 pies 4 pulgadas y 8 pies 2 pulgadas$$),
  ('he', 'profileEditHeightInvalidFeet', $$הגובה חייב להיות בין 3 רגל 4 אינטש ל-8 רגל 2 אינטש$$),

  -- ============ MATCH INSPECTOR: age / distance / system (was y/a/km/Sys) ============
  ('en', 'matchInspectorAgeUnit', $$years$$),
  ('es', 'matchInspectorAgeUnit', $$años$$),
  ('he', 'matchInspectorAgeUnit', $$שנים$$),

  ('en', 'matchInspectorKmUnit', $$kilometers$$),
  ('es', 'matchInspectorKmUnit', $$kilómetros$$),
  ('he', 'matchInspectorKmUnit', $$קילומטרים$$),

  ('en', 'matchInspectorHeightUnit', $$centimeters$$),
  ('es', 'matchInspectorHeightUnit', $$centímetros$$),
  ('he', 'matchInspectorHeightUnit', $$סנטימטרים$$),

  ('en', 'matchInspectorSysVisibilityHint', $$System: A[{a}] • B[{b}]$$),
  ('es', 'matchInspectorSysVisibilityHint', $$Sistema: A[{a}] • B[{b}]$$),
  ('he', 'matchInspectorSysVisibilityHint', $$מערכת: א'[{a}] • ב'[{b}]$$),

  -- ============ KEYS MOVED OFF HARDCODED LITERALS (now sourced from this table) ============
  ('en', 'chatEdited', $$Edited$$),
  ('es', 'chatEdited', $$Editado$$),
  ('he', 'chatEdited', $$נערך$$),

  ('en', 'chatIsTyping', $$is typing…$$),
  ('es', 'chatIsTyping', $$está escribiendo…$$),
  ('he', 'chatIsTyping', $$מקליד…$$),
  ('en', 'chatIsTyping_male', $$is typing…$$),
  ('es', 'chatIsTyping_male', $$está escribiendo…$$),
  ('he', 'chatIsTyping_male', $$מקליד…$$),
  ('en', 'chatIsTyping_female', $$is typing…$$),
  ('es', 'chatIsTyping_female', $$está escribiendo…$$),
  ('he', 'chatIsTyping_female', $$מקלידה…$$),
  ('en', 'chatIsTyping_non_binary', $$is typing…$$),
  ('es', 'chatIsTyping_non_binary', $$está escribiendo…$$),
  ('he', 'chatIsTyping_non_binary', $$מקליד…$$),

  ('en', 'chatReplyYou', $$You$$),
  ('es', 'chatReplyYou', $$Tú$$),
  ('he', 'chatReplyYou', $$את/ה$$),

  ('en', 'chatReplyOriginalUnavailable', $$Original message unavailable$$),
  ('es', 'chatReplyOriginalUnavailable', $$Mensaje original no disponible$$),
  ('he', 'chatReplyOriginalUnavailable', $$ההודעה המקורית אינה זמינה$$),

  ('en', 'chatTranslateAutoDisabled', $$Auto-translation is disabled for this chat$$),
  ('es', 'chatTranslateAutoDisabled', $$La traducción automática está desactivada para este chat$$),
  ('he', 'chatTranslateAutoDisabled', $$התרגום האוטומטי מושבת עבור הצ'אט הזה$$),

  ('en', 'webAdSpecialOffer', $$Special Offer$$),
  ('es', 'webAdSpecialOffer', $$Oferta especial$$),
  ('he', 'webAdSpecialOffer', $$הצעה מיוחדת$$),

  ('en', 'webAdGetOffer', $$Get Offer$$),
  ('es', 'webAdGetOffer', $$Obtener oferta$$),
  ('he', 'webAdGetOffer', $$קבל הצעה$$),

  ('en', 'webAdPremiumOffer', $$50% Off Premium$$),
  ('es', 'webAdPremiumOffer', $$50% de descuento en Premium$$),
  ('he', 'webAdPremiumOffer', $$50% הנחה על פרימיום$$),

  ('en', 'settingsNotificationsPreviewTitle', $$Show message previews on this device$$),
  ('es', 'settingsNotificationsPreviewTitle', $$Mostrar vistas previas de mensajes en este dispositivo$$),
  ('he', 'settingsNotificationsPreviewTitle', $$הצג תצוגות מקדימות של הודעות במכשיר זה$$),

  ('en', 'settingsNotificationsPreviewDesc', $$Decrypt and show message content in notifications on this device only$$),
  ('es', 'settingsNotificationsPreviewDesc', $$Descifrar y mostrar el contenido de los mensajes en las notificaciones solo en este dispositivo$$),
  ('he', 'settingsNotificationsPreviewDesc', $$פענח והצג את תוכן ההודעות בהתראות במכשיר זה בלבד$$),

  ('en', 'offlineMutationId', $$Identifier: {id}$$),
  ('es', 'offlineMutationId', $$Identificador: {id}$$),
  ('he', 'offlineMutationId', $$מזהה: {id}$$),

  ('en', 'offlineMutationRetries', $$Retries: {count}$$),
  ('es', 'offlineMutationRetries', $$Reintentos: {count}$$),
  ('he', 'offlineMutationRetries', $$ניסיונות חוזרים: {count}$$),

  ('en', 'offlineMutationError', $$Error: {error}$$),
  ('es', 'offlineMutationError', $$Error: {error}$$),
  ('he', 'offlineMutationError', $$שגיאה: {error}$$),

  -- ============ ADMIN: Min/Max/Lang/Info/Avg/ms/s/km/7d/e.g. (was abbreviated) ============
  ('en', 'adminAppConfigMinValue', $$Minimum$$),
  ('es', 'adminAppConfigMinValue', $$Mínimo$$),
  ('he', 'adminAppConfigMinValue', $$מינימום$$),

  ('en', 'adminAppConfigMaxValue', $$Maximum$$),
  ('es', 'adminAppConfigMaxValue', $$Máximo$$),
  ('he', 'adminAppConfigMaxValue', $$מקסימום$$),

  ('en', 'adminBroadcastsLanguage', $$Language$$),
  ('es', 'adminBroadcastsLanguage', $$Idioma$$),
  ('he', 'adminBroadcastsLanguage', $$שפה$$),

  ('en', 'adminBroadcastsTypeInfo', $$Information$$),
  ('es', 'adminBroadcastsTypeInfo', $$Información$$),
  ('he', 'adminBroadcastsTypeInfo', $$מידע$$),

  ('en', 'adminDrilldownDurationMs', $$Duration (milliseconds)$$),
  ('es', 'adminDrilldownDurationMs', $$Duración (milisegundos)$$),
  ('he', 'adminDrilldownDurationMs', $$משך (מילישניות)$$),

  ('en', 'adminDashboardNearbyUsers', $$Nearby users (10 kilometers)$$),
  ('es', 'adminDashboardNearbyUsers', $$Usuarios cercanos (10 kilómetros)$$),
  ('he', 'adminDashboardNearbyUsers', $$משתמשים בקרבת מקום (10 קילומטרים)$$),

  ('en', 'adminDashboardPaidExpiring7d', $$Paid expiring (7 days)$$),
  ('es', 'adminDashboardPaidExpiring7d', $$Pagos que vencen (7 días)$$),
  ('he', 'adminDashboardPaidExpiring7d', $$מנויים בתשלום שפגים (7 ימים)$$),

  ('en', 'adminAdsRange7d', $$7 days$$),
  ('es', 'adminAdsRange7d', $$7 días$$),
  ('he', 'adminAdsRange7d', $$7 ימים$$),

  ('en', 'adminAdsRange30d', $$30 days$$),
  ('es', 'adminAdsRange30d', $$30 días$$),
  ('he', 'adminAdsRange30d', $$30 ימים$$),

  ('en', 'adminAdsRange90d', $$90 days$$),
  ('es', 'adminAdsRange90d', $$90 días$$),
  ('he', 'adminAdsRange90d', $$90 ימים$$),

  ('en', 'adminSponsoredAdsConfigMaxPerSession', $$Maximum per session$$),
  ('es', 'adminSponsoredAdsConfigMaxPerSession', $$Máximo por sesión$$),
  ('he', 'adminSponsoredAdsConfigMaxPerSession', $$מקסימום לסשן$$),

  ('en', 'adminSponsoredAdsConfigMinMinutes', $$Minimum minutes between ads$$),
  ('es', 'adminSponsoredAdsConfigMinMinutes', $$Minutos mínimos entre anuncios$$),
  ('he', 'adminSponsoredAdsConfigMinMinutes', $$מינימום דקות בין מודעות$$),

  ('en', 'adminSponsoredAdsAvgDwell', $$Average dwell$$),
  ('es', 'adminSponsoredAdsAvgDwell', $$Permanencia promedio$$),
  ('he', 'adminSponsoredAdsAvgDwell', $$שהייה ממוצעת$$),

  ('en', 'adminExternalAdsRateLimitPerHour', $$Maximum ads per user per hour$$),
  ('es', 'adminExternalAdsRateLimitPerHour', $$Máximo de anuncios por usuario por hora$$),
  ('he', 'adminExternalAdsRateLimitPerHour', $$מקסימום מודעות למשתמש לשעה$$),

  ('en', 'adminExternalAdsRateLimitPerUser', $$Maximum ads per user per day$$),
  ('es', 'adminExternalAdsRateLimitPerUser', $$Máximo de anuncios por usuario por día$$),
  ('he', 'adminExternalAdsRateLimitPerUser', $$מקסימום מודעות למשתמש ליום$$),

  ('en', 'adminPromoCodesFieldMaxUses', $$Maximum uses (leave empty for unlimited)$$),
  ('es', 'adminPromoCodesFieldMaxUses', $$Usos máximos (dejar vacío para ilimitado)$$),
  ('he', 'adminPromoCodesFieldMaxUses', $$שימושים מרביים (להשאיר ריק ללא הגבלה)$$),

  ('en', 'adminPromoCodesFieldMaxUsesPerUser', $$Maximum uses per user$$),
  ('es', 'adminPromoCodesFieldMaxUsesPerUser', $$Usos máximos por usuario$$),
  ('he', 'adminPromoCodesFieldMaxUsesPerUser', $$שימושים מרביים למשתמש$$),

  ('en', 'adminPromoCodesInfoMaxUses', $$Maximum uses$$),
  ('es', 'adminPromoCodesInfoMaxUses', $$Usos máximos$$),
  ('he', 'adminPromoCodesInfoMaxUses', $$שימושים מקסימליים$$),

  ('en', 'adminUnifiedAdMaxImpressions', $$Maximum impressions per session$$),
  ('es', 'adminUnifiedAdMaxImpressions', $$Máximo de impresiones por sesión$$),
  ('he', 'adminUnifiedAdMaxImpressions', $$מקסימום הופעות לכל סשן$$),

  ('en', 'adminUnifiedAdMinMinutes', $$Minimum minutes between ads$$),
  ('es', 'adminUnifiedAdMinMinutes', $$Minutos mínimos entre anuncios$$),
  ('he', 'adminUnifiedAdMinMinutes', $$מינימום דקות בין מודעות$$),

  ('en', 'adminUnifiedAdFirstImpressionDelay', $$First impression delay (seconds)$$),
  ('es', 'adminUnifiedAdFirstImpressionDelay', $$Retraso de primera impresión (segundos)$$),
  ('he', 'adminUnifiedAdFirstImpressionDelay', $$השהיית הופעה ראשונה (שניות)$$),

  ('en', 'adminAdUnitFieldAdUnitIdHint', $$For example: ca-app-pub-xxx/yyy$$),
  ('es', 'adminAdUnitFieldAdUnitIdHint', $$Por ejemplo: ca-app-pub-xxx/yyy$$),
  ('he', 'adminAdUnitFieldAdUnitIdHint', $$לדוגמה: ca-app-pub-xxx/yyy$$),

  ('en', 'adminNetworkFieldDisplayNameHint', $$For example: Google AdMob$$),
  ('es', 'adminNetworkFieldDisplayNameHint', $$Por ejemplo: Google AdMob$$),
  ('he', 'adminNetworkFieldDisplayNameHint', $$לדוגמה: Google AdMob$$),

  ('en', 'adminPromoCodesFieldCodeHint', $$For example: SUMMER2024$$),
  ('es', 'adminPromoCodesFieldCodeHint', $$Por ejemplo: VERANO2024$$),
  ('he', 'adminPromoCodesFieldCodeHint', $$לדוגמה: SUMMER2024$$),

  ('en', 'adminPromoCodesFieldDiscountPercentageHint', $$For example: 20 for 20%$$),
  ('es', 'adminPromoCodesFieldDiscountPercentageHint', $$Por ejemplo: 20 para 20%$$),
  ('he', 'adminPromoCodesFieldDiscountPercentageHint', $$לדוגמה: 20 עבור 20%$$),

  ('en', 'adminPromoCodesFieldDiscountAmountHint', $$For example: 500 for $5.00$$),
  ('es', 'adminPromoCodesFieldDiscountAmountHint', $$Por ejemplo: 500 para $5.00$$),
  ('he', 'adminPromoCodesFieldDiscountAmountHint', $$לדוגמה: 500 עבור $5.00$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Admin-visible config descriptions (shown in admin app-config screen).
UPDATE public.app_config SET description = 'Maximum impressions per user per day'
WHERE config_key = 'ads.external.max_impressions_per_user_per_day'
  AND description = 'Max impressions per user per day';
UPDATE public.app_config SET description = 'Maximum impressions per user per hour'
WHERE config_key = 'ads.external.max_impressions_per_user_per_hour'
  AND description = 'Max impressions per user per hour';

COMMIT;

-- Verification: should return 0 rows after the fix.
-- SELECT locale, key, value FROM public.translations
-- WHERE value IN ('cm', 'ft', 'in', 'pulg', 'y', 'a', 'km', 'ms', 'Min', 'Max', 'Lang', 'Info', 'Mín.', 'Máx.', 'Avg Dwell')
--    OR value LIKE '% e.g.%' OR value LIKE '%ej.%' OR value LIKE '% ft %' OR value LIKE '% in %'
--    OR value LIKE '%{seconds}s%' OR value LIKE '%(ms)%' OR value LIKE '%(s)%' OR value LIKE '%(10km)%' OR value LIKE '%(7d)%';
