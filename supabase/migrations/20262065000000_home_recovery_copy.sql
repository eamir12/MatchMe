INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'homeRecoveryOfflineTitle', 'You’re offline'),
  ('en', 'homeRecoveryOfflineMessage', 'You’re offline. Reconnect to refresh matches, chats and stats.'),
  ('en', 'homeRecoveryStaleTitle', 'Home may be out of date'),
  ('en', 'homeRecoveryStaleMessage', 'We couldn’t refresh your home. Showing the last saved data.'),
  ('es', 'homeRecoveryOfflineTitle', 'Estás sin conexión'),
  ('es', 'homeRecoveryOfflineMessage', 'Estás sin conexión. Vuelve a conectarte para actualizar tus coincidencias, chats y estadísticas.'),
  ('es', 'homeRecoveryStaleTitle', 'El inicio puede estar desactualizado'),
  ('es', 'homeRecoveryStaleMessage', 'No pudimos actualizar tu inicio. Se muestran los últimos datos guardados.'),
  ('he', 'homeRecoveryOfflineTitle', 'אתה במצב לא מקוון'),
  ('he', 'homeRecoveryOfflineMessage', 'אתה במצב לא מקוון. התחבר שוב כדי לרענן התאמות, צ׳אטים וסטטיסטיקות.'),
  ('he', 'homeRecoveryStaleTitle', 'מסך הבית עשוי להיות לא מעודכן'),
  ('he', 'homeRecoveryStaleMessage', 'לא הצלחנו לרענן את מסך הבית. מוצגים הנתונים האחרונים שנשמרו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
