-- Seed admin System Health History screen translations (en/es/he).
-- Keys exist in matchme_admin/lib/main.dart _defaultTranslations (English
-- fallback). Safe to re-run (upsert semantics via primary key on
-- (locale, key) where applicable; plain INSERT tolerated on fresh DBs).

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminHealthHistoryButton', $$History$$),
  ('es', 'adminHealthHistoryButton', $$Historial$$),
  ('he', 'adminHealthHistoryButton', $$היסטוריה$$),

  ('en', 'adminHealthHistoryTitle', $$System health history$$),
  ('es', 'adminHealthHistoryTitle', $$Historial del estado del sistema$$),
  ('he', 'adminHealthHistoryTitle', $$היסטוריית בריאות המערכת$$),

  ('en', 'adminHealthHistorySubtitle', $$Snapshots every ~5 minutes · last 7 days$$),
  ('es', 'adminHealthHistorySubtitle', $$Instantáneas cada ~5 minutos · últimos 7 días$$),
  ('he', 'adminHealthHistorySubtitle', $$צילום מצב כל ~5 דקות · 7 הימים האחרונים$$),

  ('en', 'adminHealthHistoryRangeFrom', $$From$$),
  ('es', 'adminHealthHistoryRangeFrom', $$Desde$$),
  ('he', 'adminHealthHistoryRangeFrom', $$מ$$),

  ('en', 'adminHealthHistoryRangeTo', $$To$$),
  ('es', 'adminHealthHistoryRangeTo', $$Hasta$$),
  ('he', 'adminHealthHistoryRangeTo', $$עד$$),

  ('en', 'adminHealthHistoryPreset1h', $$1 hour$$),
  ('es', 'adminHealthHistoryPreset1h', $$1 hora$$),
  ('he', 'adminHealthHistoryPreset1h', $$שעה$$),

  ('en', 'adminHealthHistoryPreset6h', $$6 hours$$),
  ('es', 'adminHealthHistoryPreset6h', $$6 horas$$),
  ('he', 'adminHealthHistoryPreset6h', $$6 שעות$$),

  ('en', 'adminHealthHistoryPreset24h', $$24 hours$$),
  ('es', 'adminHealthHistoryPreset24h', $$24 horas$$),
  ('he', 'adminHealthHistoryPreset24h', $$24 שעות$$),

  ('en', 'adminHealthHistoryPreset7d', $$7 days$$),
  ('es', 'adminHealthHistoryPreset7d', $$7 días$$),
  ('he', 'adminHealthHistoryPreset7d', $$7 ימים$$),

  ('en', 'adminHealthHistoryApply', $$Apply$$),
  ('es', 'adminHealthHistoryApply', $$Aplicar$$),
  ('he', 'adminHealthHistoryApply', $$החל$$),

  ('en', 'adminHealthHistoryViewRange', $$Charts$$),
  ('es', 'adminHealthHistoryViewRange', $$Gráficos$$),
  ('he', 'adminHealthHistoryViewRange', $$גרפים$$),

  ('en', 'adminHealthHistoryViewReplay', $$Replay$$),
  ('es', 'adminHealthHistoryViewReplay', $$Reproducción$$),
  ('he', 'adminHealthHistoryViewReplay', $$הפעלה$$),

  ('en', 'adminHealthHistoryReplayBanner', $$Replay — as of {time}$$),
  ('es', 'adminHealthHistoryReplayBanner', $$Reproducción — a partir de {time}$$),
  ('he', 'adminHealthHistoryReplayBanner', $$הפעלה — נכון ל-{time}$$),

  ('en', 'adminHealthHistoryReplayAsOf', $$As of$$),
  ('es', 'adminHealthHistoryReplayAsOf', $$A partir de$$),
  ('he', 'adminHealthHistoryReplayAsOf', $$נכון ל$$),

  ('en', 'adminHealthHistoryEmpty', $$No snapshots in this range yet.$$),
  ('es', 'adminHealthHistoryEmpty', $$Aún no hay instantáneas en este intervalo.$$),
  ('he', 'adminHealthHistoryEmpty', $$אין עדיין נתוני צילום בטווח הזה.$$),

  ('en', 'adminHealthHistoryLoading', $$Loading history…$$),
  ('es', 'adminHealthHistoryLoading', $$Cargando historial…$$),
  ('he', 'adminHealthHistoryLoading', $$טוען היסטוריה…$$),

  ('en', 'adminHealthHistoryError', $$Could not load history: {error}$$),
  ('es', 'adminHealthHistoryError', $$No se pudo cargar el historial: {error}$$),
  ('he', 'adminHealthHistoryError', $$לא ניתן לטעון היסטוריה: {error}$$),

  ('en', 'adminHealthHistoryOutOfRange', $$Pick a range within the last 7 days.$$),
  ('es', 'adminHealthHistoryOutOfRange', $$Elige un intervalo de los últimos 7 días.$$),
  ('he', 'adminHealthHistoryOutOfRange', $$בחר טווח מ-7 הימים האחרונים.$$),

  ('en', 'adminHealthHistoryChartQueue', $$Queue pending$$),
  ('es', 'adminHealthHistoryChartQueue', $$Pendientes en la cola$$),
  ('he', 'adminHealthHistoryChartQueue', $$ממתינים בתור$$),

  ('en', 'adminHealthHistoryChartApiRate', $$API requests per interval$$),
  ('es', 'adminHealthHistoryChartApiRate', $$Solicitudes API por intervalo$$),
  ('he', 'adminHealthHistoryChartApiRate', $$בקשות API לכל מרווח$$),

  ('en', 'adminHealthHistoryErrorsTitle', $$Failures in selected range$$),
  ('es', 'adminHealthHistoryErrorsTitle', $$Fallos en el intervalo seleccionado$$),
  ('he', 'adminHealthHistoryErrorsTitle', $$תקלות בטווח שנבחר$$),

  ('en', 'adminHealthHistoryErrorsEdge', $$Edge function failures (5xx)$$),
  ('es', 'adminHealthHistoryErrorsEdge', $$Fallos de funciones edge (5xx)$$),
  ('he', 'adminHealthHistoryErrorsEdge', $$תקלות פונקציות edge (5xx)$$),

  ('en', 'adminHealthHistoryErrorsCron', $$Cron invocations with failed tasks$$),
  ('es', 'adminHealthHistoryErrorsCron', $$Invocaciones cron con tareas fallidas$$),
  ('he', 'adminHealthHistoryErrorsCron', $$קריאות cron עם משימות כושלות$$),

  ('en', 'adminHealthHistoryErrorsApp', $$App errors$$),
  ('es', 'adminHealthHistoryErrorsApp', $$Errores de la app$$),
  ('he', 'adminHealthHistoryErrorsApp', $$שגיאות אפליקציה$$),

  ('en', 'adminHealthHistoryStatuspageTitle', $$Supabase status timeline$$),
  ('es', 'adminHealthHistoryStatuspageTitle', $$Cronología del estado de Supabase$$),
  ('he', 'adminHealthHistoryStatuspageTitle', $$ציר זמן מצב Supabase$$),

  ('en', 'adminHealthHistorySocketTitle', $$Realtime socket transitions$$),
  ('es', 'adminHealthHistorySocketTitle', $$Transiciones del socket realtime$$),
  ('he', 'adminHealthHistorySocketTitle', $$מעברי socket של Realtime$$),

  ('en', 'adminHealthHistorySocketOpen', $$Open$$),
  ('es', 'adminHealthHistorySocketOpen', $$Abierto$$),
  ('he', 'adminHealthHistorySocketOpen', $$פתוח$$),

  ('en', 'adminHealthHistorySocketClosed', $$Closed$$),
  ('es', 'adminHealthHistorySocketClosed', $$Cerrado$$),
  ('he', 'adminHealthHistorySocketClosed', $$סגור$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
