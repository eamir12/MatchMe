-- Migration: Additional Match Inspector Translations for remaining hardcoded strings
-- Covers: age unit, km unit, HUD format strings, system visibility labels
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES

  -- Age unit (suffix after age number)
  ('en', 'matchInspectorAgeUnit', $$years$$),
  ('es', 'matchInspectorAgeUnit', $$años$$),
  ('he', 'matchInspectorAgeUnit', $$שנים$$),

  -- Distance unit
  ('en', 'matchInspectorKmUnit', $$kilometers$$),
  ('es', 'matchInspectorKmUnit', $$kilómetros$$),
  ('he', 'matchInspectorKmUnit', $$קילומטרים$$),

  -- Distance radius subtitle: "A: {a} • B: {b}" (params: a, b include unit already)
  ('en', 'matchInspectorRadiusHint', $$A: {a} • B: {b}$$),
  ('es', 'matchInspectorRadiusHint', $$A: {a} • B: {b}$$),
  ('he', 'matchInspectorRadiusHint', $$א': {a} • ב': {b}$$),

  -- Visibility value line: "A: {a} • B: {b}" (params: a, b = localized visibility strings)
  ('en', 'matchInspectorVisibilityValue', $$A: {a} • B: {b}$$),
  ('es', 'matchInspectorVisibilityValue', $$A: {a} • B: {b}$$),
  ('he', 'matchInspectorVisibilityValue', $$א': {a} • ב': {b}$$),

  -- System visibility subtitle: "System: A[{a}] • B[{b}]" (params: a, b = localized sys values)
  ('en', 'matchInspectorSysVisibilityHint', $$System: A[{a}] • B[{b}]$$),
  ('es', 'matchInspectorSysVisibilityHint', $$Sistema: A[{a}] • B[{b}]$$),
  ('he', 'matchInspectorSysVisibilityHint', $$מערכת: א'[{a}] • ב'[{b}]$$),

  -- Activity value (main line for User A): "A: {status}"
  ('en', 'matchInspectorActivityValue', $$A: {status}$$),
  ('es', 'matchInspectorActivityValue', $$A: {status}$$),
  ('he', 'matchInspectorActivityValue', $$א': {status}$$),

  -- Activity subtitle (secondary line for User B): "B: {status}"
  ('en', 'matchInspectorActivitySubtitle', $$B: {status}$$),
  ('es', 'matchInspectorActivitySubtitle', $$B: {status}$$),
  ('he', 'matchInspectorActivitySubtitle', $$ב': {status}$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
