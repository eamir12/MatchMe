INSERT INTO public.translations (key, value, locale)
VALUES
  ('adminPromoCodesTabControls', 'Controls', 'en'),
  ('adminPromoCodesTabControls', 'Controles', 'es'),
  ('adminPromoCodesTabControls', 'בקרה', 'he'),

  ('adminPromoCodesControlsTitle', 'Promo Code Controls', 'en'),
  ('adminPromoCodesControlsTitle', 'Controles de codigos promocionales', 'es'),
  ('adminPromoCodesControlsTitle', 'בקרת קודי קידום', 'he'),

  ('adminPromoCodesControlsSubtitle', 'Manage global promo code settings', 'en'),
  ('adminPromoCodesControlsSubtitle', 'Administrar la configuracion global de codigos promocionales', 'es'),
  ('adminPromoCodesControlsSubtitle', 'ניהול הגדרות קודי קידום גלובליות', 'he'),

  ('adminPromoCodesControlsEnabled', 'Enable Promo Codes', 'en'),
  ('adminPromoCodesControlsEnabled', 'Habilitar codigos promocionales', 'es'),
  ('adminPromoCodesControlsEnabled', 'הפעלת קודי קידום', 'he'),

  ('adminPromoCodesControlsEnabledSubtitle', 'Allow users to redeem promo codes', 'en'),
  ('adminPromoCodesControlsEnabledSubtitle', 'Permitir que los usuarios canjeen codigos promocionales', 'es'),
  ('adminPromoCodesControlsEnabledSubtitle', 'לאפשר למשתמשים לממש קודי קידום', 'he'),

  ('adminPromoCodesAnalyticsTitle', 'Promo Code Analytics', 'en'),
  ('adminPromoCodesAnalyticsTitle', 'Analiticas de codigos promocionales', 'es'),
  ('adminPromoCodesAnalyticsTitle', 'ניתוח נתוני קודי קידום', 'he'),

  ('adminPromoCodesAnalyticsSubtitle', 'View redemption statistics and usage trends', 'en'),
  ('adminPromoCodesAnalyticsSubtitle', 'Ver estadisticas de canje y tendencias de uso', 'es'),
  ('adminPromoCodesAnalyticsSubtitle', 'צפה בסטטיסטיקות מימוש ומגמות שימוש', 'he'),

  ('adminPromoCodesDrillDownTotalUses', 'Total Redemptions', 'en'),
  ('adminPromoCodesDrillDownTotalUses', 'Canjes totales', 'es'),
  ('adminPromoCodesDrillDownTotalUses', 'סה''כ מימושים', 'he'),

  ('adminPromoCodesDrillDownUniqueUsers', 'Unique Users', 'en'),
  ('adminPromoCodesDrillDownUniqueUsers', 'Usuarios unicos', 'es'),
  ('adminPromoCodesDrillDownUniqueUsers', 'משתמשים ייחודיים', 'he'),

  ('adminPromoCodesDrillDownTotalDiscount', 'Total Discount', 'en'),
  ('adminPromoCodesDrillDownTotalDiscount', 'Descuento total', 'es'),
  ('adminPromoCodesDrillDownTotalDiscount', 'סה''כ הנחה', 'he'),

  ('adminPromoCodesDrillDownAvgDiscount', 'Average Discount per Use', 'en'),
  ('adminPromoCodesDrillDownAvgDiscount', 'Descuento promedio por uso', 'es'),
  ('adminPromoCodesDrillDownAvgDiscount', 'הנחה ממוצעת למימוש', 'he'),

  ('adminPromoCodesDrillDownDescription', 'Overview: {total_uses} total redemptions by {unique_users} unique users, totaling {total_discount} in discounts.', 'en'),
  ('adminPromoCodesDrillDownDescription', 'Resumen: {total_uses} canjes totales por {unique_users} usuarios unicos, totalizando {total_discount} en descuentos.', 'es'),
  ('adminPromoCodesDrillDownDescription', 'סקירה כללית: {total_uses} מימושים סה''כ על ידי {unique_users} משתמשים ייחודיים, בסך הכל {total_discount} בהנחות.', 'he'),

  ('adminPromoCodesConfigSaveSuccess', 'Configuration saved successfully', 'en'),
  ('adminPromoCodesConfigSaveSuccess', 'Configuracion guardada correctamente', 'es'),
  ('adminPromoCodesConfigSaveSuccess', 'התצורה נשמרה בהצלחה', 'he'),

  ('adminPromoCodesConfigSaveError', 'Error saving configuration: {error}', 'en'),
  ('adminPromoCodesConfigSaveError', 'Error al guardar la configuracion: {error}', 'es'),
  ('adminPromoCodesConfigSaveError', 'שגיאה בשמירת התצורה: {error}', 'he')
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;
