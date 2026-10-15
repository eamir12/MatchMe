-- Seed admin System Health "Project errors", "Sign-ins", and "Project usage"
-- card translations (en/es/he). Safe to re-run (upsert).
-- These keys exist in matchme_admin/lib/main.dart _defaultTranslations
-- (English fallback) but were missing from the Supabase translations table.
-- Also updates adminHealthSubtitle to mention the new cards; the upsert
-- supersedes the earlier seed value whether or not it was already applied.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminHealthSubtitle', $$Supabase's official status plus live probes of this project's database, realtime, notification queue, recent failures, sign-ins, and usage. Updates automatically.$$),
  ('es', 'adminHealthSubtitle', $$Estado oficial de Supabase más sondas en vivo de la base de datos, realtime, cola de notificaciones, fallos recientes, inicios de sesión y uso de este proyecto. Se actualiza automáticamente.$$),
  ('he', 'adminHealthSubtitle', $$הסטטוס הרשמי של Supabase יחד עם בדיקות חיות של מסד הנתונים, ה-realtime, תור ההתראות, תקלות אחרונות, כניסות ושימוש של הפרויקט הזה. מתעדכן אוטומטית.$$),

  ('en', 'adminHealthErrorsTitle', $$Project errors$$),
  ('es', 'adminHealthErrorsTitle', $$Errores del proyecto$$),
  ('he', 'adminHealthErrorsTitle', $$שגיאות הפרויקט$$),

  ('en', 'adminHealthErrorsNone', $$None$$),
  ('es', 'adminHealthErrorsNone', $$Ninguno$$),
  ('he', 'adminHealthErrorsNone', $$אין$$),

  ('en', 'adminHealthErrorsValue', $${count} · {age} ago$$),
  ('es', 'adminHealthErrorsValue', $${count} · hace {age}$$),
  ('he', 'adminHealthErrorsValue', $${count} · לפני {age}$$),

  ('en', 'adminHealthErrorsEdge', $$Edge functions (15m)$$),
  ('es', 'adminHealthErrorsEdge', $$Funciones edge (15 min)$$),
  ('he', 'adminHealthErrorsEdge', $$פונקציות edge (15 דק׳)$$),

  ('en', 'adminHealthErrorsCron', $$Cron jobs (1h)$$),
  ('es', 'adminHealthErrorsCron', $$Tareas cron (1 h)$$),
  ('he', 'adminHealthErrorsCron', $$משימות cron (שעה)$$),

  ('en', 'adminHealthErrorsApp', $$App errors (15m)$$),
  ('es', 'adminHealthErrorsApp', $$Errores de la app (15 min)$$),
  ('he', 'adminHealthErrorsApp', $$שגיאות האפליקציה (15 דק׳)$$),

  ('en', 'adminHealthErrorsFailedTasks', $$Failed tasks: {tasks}$$),
  ('es', 'adminHealthErrorsFailedTasks', $$Tareas fallidas: {tasks}$$),
  ('he', 'adminHealthErrorsFailedTasks', $$משימות שנכשלו: {tasks}$$),

  ('en', 'adminHealthErrorsAppLast', $$Last: {source} — {message}$$),
  ('es', 'adminHealthErrorsAppLast', $$Último: {source} — {message}$$),
  ('he', 'adminHealthErrorsAppLast', $$אחרון: {source} — {message}$$),

  ('en', 'adminHealthErrorsAlertDetail', $$Recent project failures are above the alert threshold.$$),
  ('es', 'adminHealthErrorsAlertDetail', $$Los fallos recientes del proyecto superan el umbral de alerta.$$),
  ('he', 'adminHealthErrorsAlertDetail', $$תקלות פרויקט אחרונות מעל סף ההתראה.$$),

  ('en', 'adminHealthSignInsTitle', $$Sign-ins$$),
  ('es', 'adminHealthSignInsTitle', $$Inicios de sesión$$),
  ('he', 'adminHealthSignInsTitle', $$כניסות$$),

  ('en', 'adminHealthSignIns15m', $$Sign-ins (15m)$$),
  ('es', 'adminHealthSignIns15m', $$Inicios de sesión (15 min)$$),
  ('he', 'adminHealthSignIns15m', $$כניסות (15 דק׳)$$),

  ('en', 'adminHealthSignInsLast', $$Last sign-in {age} ago$$),
  ('es', 'adminHealthSignInsLast', $$Último inicio de sesión hace {age}$$),
  ('he', 'adminHealthSignInsLast', $$כניסה אחרונה לפני {age}$$),

  ('en', 'adminHealthAuthErrors15m', $$Auth errors (15m)$$),
  ('es', 'adminHealthAuthErrors15m', $$Errores de autenticación (15 min)$$),
  ('he', 'adminHealthAuthErrors15m', $$שגיאות אימות (15 דק׳)$$),

  ('en', 'adminHealthAuthLastError', $$Last error: {action} — {message}$$),
  ('es', 'adminHealthAuthLastError', $$Último error: {action} — {message}$$),
  ('he', 'adminHealthAuthLastError', $$שגיאה אחרונה: {action} — {message}$$),

  ('en', 'adminHealthAuthAlertDetail', $${count} auth failures in the last 15 minutes$$),
  ('es', 'adminHealthAuthAlertDetail', $${count} fallos de autenticación en los últimos 15 minutos$$),
  ('he', 'adminHealthAuthAlertDetail', $${count} כשלונות אימות ב-15 הדקות האחרונות$$),

  ('en', 'adminHealthUsageTitle', $$Project usage$$),
  ('es', 'adminHealthUsageTitle', $$Uso del proyecto$$),
  ('he', 'adminHealthUsageTitle', $$שימוש בפרויקט$$),

  ('en', 'adminHealthDiskUsage', $$Database disk$$),
  ('es', 'adminHealthDiskUsage', $$Disco de la base de datos$$),
  ('he', 'adminHealthDiskUsage', $$דיסק מסד הנתונים$$),

  ('en', 'adminHealthDiskUsageValue', $${used} GB of {size} GB ({pct}%)$$),
  ('es', 'adminHealthDiskUsageValue', $${used} GB de {size} GB ({pct}%)$$),
  ('he', 'adminHealthDiskUsageValue', $${used} ג׳ב מתוך {size} ג׳ב ({pct}%)$$),

  ('en', 'adminHealthDiskAlertDetail', $$Database disk {pct}% full$$),
  ('es', 'adminHealthDiskAlertDetail', $$Disco de la base de datos al {pct} %$$),
  ('he', 'adminHealthDiskAlertDetail', $$דיסק מסד הנתונים מלא ב-{pct}%$$),

  ('en', 'adminHealthApiRequests', $$API requests$$),
  ('es', 'adminHealthApiRequests', $$Solicitudes a la API$$),
  ('he', 'adminHealthApiRequests', $$קריאות API$$),

  ('en', 'adminHealthNotConfigured', $$Not configured — set MANAGEMENT_API_TOKEN on the project-logs-health function to enable these signals.$$),
  ('es', 'adminHealthNotConfigured', $$Sin configurar — define MANAGEMENT_API_TOKEN en la función project-logs-health para habilitar estas señales.$$),
  ('he', 'adminHealthNotConfigured', $$לא מוגדר — הגדר את MANAGEMENT_API_TOKEN בפונקציית project-logs-health כדי להפעיל את הסיגנלים האלה.$$),

  ('en', 'adminHealthLogsWarnings', $$Some sources unavailable: {warnings}$$),
  ('es', 'adminHealthLogsWarnings', $$Algunas fuentes no disponibles: {warnings}$$),
  ('he', 'adminHealthLogsWarnings', $$כמה מקורות אינם זמינים: {warnings}$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
