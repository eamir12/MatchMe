-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyMode', 'High Accuracy Mode') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc', 'Increases location precision and frequency.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_android', 'Increases location precision and frequency.
• Updates every 30s-15m (requires persistent notification).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_ios', 'Increases location precision and frequency.
• Updates every ~10m of movement (uses more battery).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsHighAccuracyModeDesc_web', 'Increases location precision.
• No background updates (foreground only).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsSmartGpsThrottling', 'Smart GPS Throttling') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsSmartGpsThrottlingDesc', 'Automatically reduces update frequency to save battery.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsSmartGpsThrottlingDesc_android', 'Automatically reduces update frequency to save battery when:
• Device is stationary
• Battery is below 15%') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsSmartGpsThrottlingDesc_ios', 'iOS manages power automatically. This setting is disabled.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsSmartGpsThrottlingDesc_web', 'Smart throttling is not available on Web.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyMode', 'Modo de Alta Precisión') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc', 'Aumenta la precisión y frecuencia de la ubicación.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_android', 'Aumenta la precisión y frecuencia.
• Actualiza cada 30s-15m (requiere notificación persistente).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_ios', 'Aumenta la precisión y frecuencia.
• Actualiza cada ~10m de movimiento (usa más batería).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsHighAccuracyModeDesc_web', 'Aumenta la precisión.
• Sin actualizaciones en segundo plano (solo primer plano).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsSmartGpsThrottling', 'Ahorro de GPS Inteligente') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsSmartGpsThrottlingDesc', 'Reduce automáticamente la frecuencia de actualización para ahorrar batería.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsSmartGpsThrottlingDesc_android', 'Reduce automáticamente la frecuencia para ahorrar batería cuando:
• El dispositivo está inmóvil
• La batería está por debajo del 15%') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsSmartGpsThrottlingDesc_ios', 'iOS gestiona el ahorro automáticamente. Este ajuste está desactivado.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsSmartGpsThrottlingDesc_web', 'El ahorro inteligente no está disponible en Web.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyMode', 'מצב דיוק גבוה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc', 'מגביר את דיוק ותדירות המיקום.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_android', 'מגביר דיוק ותדירות.
• מתעדכן כל 30 שניות עד 15 דקות (דורש התראה קבועה).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_ios', 'מגביר דיוק ותדירות.
• מתעדכן כל ~10 מטרים של תנועה (צורך יותר סוללה).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsHighAccuracyModeDesc_web', 'מגביר דיוק.
• אין עדכונים ברקע (קדמה בלבד).') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsSmartGpsThrottling', 'חיסכון GPS חכם') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsSmartGpsThrottlingDesc', 'מפחית אוטומטית את תדירות העדכון לחיסכון בסוללה.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsSmartGpsThrottlingDesc_android', 'מפחית אוטומטית את תדירות העדכון לחיסכון בסוללה כאשר:
• המכשיר ללא תנועה
• הסוללה מתחת ל-15%') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsSmartGpsThrottlingDesc_ios', 'iOS מנהלת חיסכון אוטומטית. הגדרה זו מבוטלת.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsSmartGpsThrottlingDesc_web', 'חיסכון חכם אינו זמין בדפדפן.') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
