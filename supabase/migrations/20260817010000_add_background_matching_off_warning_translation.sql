INSERT INTO translations (locale, key, value) VALUES
  ('en', 'background_matching_off_warning', 'Turning off Background Matching Mode means your location will only update while the app is open and active. You won''t appear on the nearby map or receive match notifications when the app is closed or in the background. Are you sure you want to turn this off?'),
  ('en', 'settingsBackgroundMatchingTurnOff', 'Turn Off'),
  ('es', 'background_matching_off_warning', 'Si desactivas el Modo de Coincidencia en Segundo Plano, tu ubicación solo se actualizará cuando la app esté abierta y en uso. No aparecerás en el mapa cercano ni recibirás notificaciones de coincidencias cuando la app esté cerrada o en segundo plano. ¿Estás seguro de que quieres desactivarla?'),
  ('es', 'settingsBackgroundMatchingTurnOff', 'Desactivar'),
  ('he', 'background_matching_off_warning', 'ביטול מצב התאמה ברקע nghĩa שמיקומך יתעדכן רק כאשר האפליקציה פתוחה ופעילה. לא תופיע במפה הסמוכה ולא תקבל התראות על התאמות כאשר האפליקציה סגורה או ברקע. האם אתה בטוח שברצונך לבטל מצב זה?'),
  ('he', 'settingsBackgroundMatchingTurnOff', 'כבה')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;
