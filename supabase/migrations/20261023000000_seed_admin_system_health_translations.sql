-- Seed admin System Health screen translations (en/es/he). Safe to re-run.
-- These keys exist in matchme_admin/lib/main.dart _defaultTranslations
-- (English fallback) but were missing from the Supabase translations table,
-- causing English-only text in the Hebrew/Spanish admin System Health screen.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminNavSystemHealth', $$System Health$$),
  ('es', 'adminNavSystemHealth', $$Estado del sistema$$),
  ('he', 'adminNavSystemHealth', $$מצב המערכת$$),

  ('en', 'adminHealthSubtitle', $$Supabase's official status plus live probes of this project's database, realtime, and notification queue. Updates automatically.$$),
  ('es', 'adminHealthSubtitle', $$Estado oficial de Supabase más sondas en vivo de la base de datos, realtime y la cola de notificaciones de este proyecto. Se actualiza automáticamente.$$),
  ('he', 'adminHealthSubtitle', $$הסטטוס הרשמי של Supabase יחד עם בדיקות חיות של מסד הנתונים, ה-realtime ותור ההתראות של הפרויקט הזה. מתעדכן אוטומטית.$$),

  ('en', 'adminHealthSupabaseStatus', $$Supabase status (official)$$),
  ('es', 'adminHealthSupabaseStatus', $$Estado de Supabase (oficial)$$),
  ('he', 'adminHealthSupabaseStatus', $$מצב Supabase (רשמי)$$),

  ('en', 'adminHealthSupabaseSource', $$status.supabase.com · updated {age} ago$$),
  ('es', 'adminHealthSupabaseSource', $$status.supabase.com · actualizado hace {age}$$),
  ('he', 'adminHealthSupabaseSource', $$status.supabase.com · עודכן לפני {age}$$),

  ('en', 'adminHealthSupabaseUnavailable', $$Could not load Supabase’s status page right now.$$),
  ('es', 'adminHealthSupabaseUnavailable', $$No se pudo cargar la página de estado de Supabase ahora mismo.$$),
  ('he', 'adminHealthSupabaseUnavailable', $$לא ניתן כרגע לטעון את עמוד הסטטוס של Supabase.$$),

  ('en', 'adminHealthComponentOperational', $$Operational$$),
  ('es', 'adminHealthComponentOperational', $$Operativo$$),
  ('he', 'adminHealthComponentOperational', $$תקין$$),

  ('en', 'adminHealthComponentDegraded', $$Degraded performance$$),
  ('es', 'adminHealthComponentDegraded', $$Rendimiento degradado$$),
  ('he', 'adminHealthComponentDegraded', $$ביצועים ירודים$$),

  ('en', 'adminHealthComponentPartialOutage', $$Partial outage$$),
  ('es', 'adminHealthComponentPartialOutage', $$Interrupción parcial$$),
  ('he', 'adminHealthComponentPartialOutage', $$השבתה חלקית$$),

  ('en', 'adminHealthComponentMajorOutage', $$Major outage$$),
  ('es', 'adminHealthComponentMajorOutage', $$Interrupción mayor$$),
  ('he', 'adminHealthComponentMajorOutage', $$השבתה נרחבת$$),

  ('en', 'adminHealthComponentMaintenance', $$Maintenance$$),
  ('es', 'adminHealthComponentMaintenance', $$Mantenimiento$$),
  ('he', 'adminHealthComponentMaintenance', $$תחזוקה$$),

  ('en', 'adminHealthRegionsLabel', $$Regions$$),
  ('es', 'adminHealthRegionsLabel', $$Regiones$$),
  ('he', 'adminHealthRegionsLabel', $$אזורים$$),

  ('en', 'adminHealthRegionsAllOk', $$All {total} regions operational$$),
  ('es', 'adminHealthRegionsAllOk', $$Las {total} regiones están operativas$$),
  ('he', 'adminHealthRegionsAllOk', $$כל {total} האזורים תקינים$$),

  ('en', 'adminHealthRegionsAffected', $${count} of {total} affected$$),
  ('es', 'adminHealthRegionsAffected', $${count} de {total} afectadas$$),
  ('he', 'adminHealthRegionsAffected', $${count} מתוך {total} מושפעים$$),

  ('en', 'adminHealthRegionsMore', $$+{count} more regions$$),
  ('es', 'adminHealthRegionsMore', $$+{count} regiones más$$),
  ('he', 'adminHealthRegionsMore', $$עוד {count} אזורים$$),

  ('en', 'adminHealthIncidents', $$Active incidents$$),
  ('es', 'adminHealthIncidents', $$Incidentes activos$$),
  ('he', 'adminHealthIncidents', $$תקלות פעילות$$),

  ('en', 'adminHealthNoIncidents', $$No active incidents$$),
  ('es', 'adminHealthNoIncidents', $$Sin incidentes activos$$),
  ('he', 'adminHealthNoIncidents', $$אין תקלות פעילות$$),

  ('en', 'adminHealthIncidentImpact', $$Impact: {impact}$$),
  ('es', 'adminHealthIncidentImpact', $$Impacto: {impact}$$),
  ('he', 'adminHealthIncidentImpact', $$השפעה: {impact}$$),

  ('en', 'adminHealthIncidentUpdated', $$Updated {age} ago$$),
  ('es', 'adminHealthIncidentUpdated', $$Actualizado hace {age}$$),
  ('he', 'adminHealthIncidentUpdated', $$עודכן לפני {age}$$),

  ('en', 'adminHealthStatusHealthy', $$Healthy$$),
  ('es', 'adminHealthStatusHealthy', $$Correcto$$),
  ('he', 'adminHealthStatusHealthy', $$תקין$$),

  ('en', 'adminHealthStatusDegraded', $$Degraded$$),
  ('es', 'adminHealthStatusDegraded', $$Degradado$$),
  ('he', 'adminHealthStatusDegraded', $$ירוד$$),

  ('en', 'adminHealthStatusDown', $$Down$$),
  ('es', 'adminHealthStatusDown', $$Caído$$),
  ('he', 'adminHealthStatusDown', $$מושבת$$),

  ('en', 'adminHealthStatusChecking', $$Checking…$$),
  ('es', 'adminHealthStatusChecking', $$Verificando…$$),
  ('he', 'adminHealthStatusChecking', $$בודק…$$),

  ('en', 'adminHealthUpdatedAgo', $$Updated {age} ago$$),
  ('es', 'adminHealthUpdatedAgo', $$Actualizado hace {age}$$),
  ('he', 'adminHealthUpdatedAgo', $$עודכן לפני {age}$$),

  ('en', 'adminHealthStaleData', $$Offline — showing the last known status.$$),
  ('es', 'adminHealthStaleData', $$Sin conexión; se muestra el último estado conocido.$$),
  ('he', 'adminHealthStaleData', $$לא מחובר — מוצג הסטטוס האחרון הידוע.$$),

  ('en', 'adminHealthDatabase', $$Database$$),
  ('es', 'adminHealthDatabase', $$Base de datos$$),
  ('he', 'adminHealthDatabase', $$מסד נתונים$$),

  ('en', 'adminHealthLatency', $$Latency$$),
  ('es', 'adminHealthLatency', $$Latencia$$),
  ('he', 'adminHealthLatency', $$זמן תגובה$$),

  ('en', 'adminHealthLatencyMs', $${ms} ms$$),
  ('es', 'adminHealthLatencyMs', $${ms} ms$$),
  ('he', 'adminHealthLatencyMs', $${ms} ms$$),

  ('en', 'adminHealthLatencyCaption', $$Each bar is one probe from this device. Orange = slow (>1.5s), which is usually the path (app resume, Wi-Fi/cell switch) — not a Supabase outage. Tap a bar for its exact reading.$$),
  ('es', 'adminHealthLatencyCaption', $$Cada barra es una sonda desde este dispositivo. Naranja = lenta (>1,5 s), lo que suele deberse a la ruta (reanudación de la app, cambio de Wi-Fi/celular) — no a una interrupción de Supabase. Toca una barra para ver su lectura exacta.$$),
  ('he', 'adminHealthLatencyCaption', $$כל עמודה היא בדיקה מהמכשיר הזה. כתום = איטי (מעל 1.5 שניות), שבדרך כלל נובע מהרשת (חזרה מהשהייה, מעבר בין Wi-Fi לרשת סלולרית) — לא השבתה של Supabase. הקש על עמודה כדי לראות את הקריאה המדויקת שלה.$$),

  ('en', 'adminHealthLatencySlowCount', $$Slow samples in view: {count}$$),
  ('es', 'adminHealthLatencySlowCount', $$Muestras lentas a la vista: {count}$$),
  ('he', 'adminHealthLatencySlowCount', $$דגימות איטיות בתצוגה: {count}$$),

  ('en', 'adminHealthLatencySample', $${ms} ms at {time}$$),
  ('es', 'adminHealthLatencySample', $${ms} ms a las {time}$$),
  ('he', 'adminHealthLatencySample', $${ms} ms בשעה {time}$$),

  ('en', 'adminHealthLastChecked', $$Last checked (ago)$$),
  ('es', 'adminHealthLastChecked', $$Última verificación (hace)$$),
  ('he', 'adminHealthLastChecked', $$נבדק לאחרונה (לפני)$$),

  ('en', 'adminHealthLastOk', $$Last OK (ago)$$),
  ('es', 'adminHealthLastOk', $$Última OK (hace)$$),
  ('he', 'adminHealthLastOk', $$תקין לאחרונה (לפני)$$),

  ('en', 'adminHealthConsecutiveFailures', $$Consecutive failures$$),
  ('es', 'adminHealthConsecutiveFailures', $$Fallos consecutivos$$),
  ('he', 'adminHealthConsecutiveFailures', $$כשלים רצופים$$),

  ('en', 'adminHealthDbError', $$Error: {error}$$),
  ('es', 'adminHealthDbError', $$Error: {error}$$),
  ('he', 'adminHealthDbError', $$שגיאה: {error}$$),

  ('en', 'adminHealthRealtime', $$Realtime$$),
  ('es', 'adminHealthRealtime', $$Realtime$$),
  ('he', 'adminHealthRealtime', $$Realtime$$),

  ('en', 'adminHealthSocketLabel', $$WebSocket$$),
  ('es', 'adminHealthSocketLabel', $$WebSocket$$),
  ('he', 'adminHealthSocketLabel', $$WebSocket$$),

  ('en', 'adminHealthSocketState', $$Socket: {state}$$),
  ('es', 'adminHealthSocketState', $$Socket: {state}$$),
  ('he', 'adminHealthSocketState', $$סוקט: {state}$$),

  ('en', 'adminHealthLastTickLabel', $$Heartbeat (tick)$$),
  ('es', 'adminHealthLastTickLabel', $$Latido (tick)$$),
  ('he', 'adminHealthLastTickLabel', $$פעימת לב (tick)$$),

  ('en', 'adminHealthLastTick', $${age} ago$$),
  ('es', 'adminHealthLastTick', $$hace {age}$$),
  ('he', 'adminHealthLastTick', $$לפני {age}$$),

  ('en', 'adminHealthNoTicksYet', $$No activity tick yet$$),
  ('es', 'adminHealthNoTicksYet', $$Aún sin ticks de actividad$$),
  ('he', 'adminHealthNoTicksYet', $$עדיין אין פעימת פעילות$$),

  ('en', 'adminHealthQueue', $$Notification queue$$),
  ('es', 'adminHealthQueue', $$Cola de notificaciones$$),
  ('he', 'adminHealthQueue', $$תור התראות$$),

  ('en', 'adminHealthQueuePending', $$Pending$$),
  ('es', 'adminHealthQueuePending', $$Pendientes$$),
  ('he', 'adminHealthQueuePending', $$ממתינים$$),

  ('en', 'adminHealthQueueProcessing', $$Processing$$),
  ('es', 'adminHealthQueueProcessing', $$En proceso$$),
  ('he', 'adminHealthQueueProcessing', $$בטיפול$$),

  ('en', 'adminHealthQueueFailedHour', $$Failed (1h)$$),
  ('es', 'adminHealthQueueFailedHour', $$Fallidas (1 h)$$),
  ('he', 'adminHealthQueueFailedHour', $$כשלים (שעה)$$),

  ('en', 'adminHealthQueueOldestPending', $$Oldest pending$$),
  ('es', 'adminHealthQueueOldestPending', $$Pendiente más antigua$$),
  ('he', 'adminHealthQueueOldestPending', $$הממתין הוותיק ביותר$$),

  ('en', 'adminHealthQueueCheckedAgo', $$Checked {age} ago$$),
  ('es', 'adminHealthQueueCheckedAgo', $$Verificado hace {age}$$),
  ('he', 'adminHealthQueueCheckedAgo', $$נבדק לפני {age}$$),

  ('en', 'adminHealthQueueAlertDetail', $$Queue alert: backlog growing or sender stuck. Check the Delivery section.$$),
  ('es', 'adminHealthQueueAlertDetail', $$Alerta de la cola: la deuda crece o el remitente está atascado. Revisa la sección de entrega.$$),
  ('he', 'adminHealthQueueAlertDetail', $$התראה בתור: התור גדל או השולח נתקע. בדוק את אזור המסירה.$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
