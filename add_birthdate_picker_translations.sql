-- Add translations for the birthday wheel picker in the profile wizard
-- Ensures all user-facing text comes from Supabase translations table (en/es/he)
-- English fallback is also in lib/providers/locale_provider.dart

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'birthdayPickerInstruction', 'Spin each wheel to choose your birthday. Pick the month, then the day, then the year.'),
  ('es', 'birthdayPickerInstruction', 'Gira cada rueda para elegir tu fecha de nacimiento. Elige el mes, luego el día y luego el año.'),
  ('he', 'birthdayPickerInstruction', 'סובבו כל גלגל כדי לבחור את תאריך הלידה שלכם. בחרו תחילה את החודש, ואז את היום ולבסוף את השנה.'),
  ('en', 'birthdayWheelMonth', 'Month'),
  ('es', 'birthdayWheelMonth', 'Mes'),
  ('he', 'birthdayWheelMonth', 'חודש'),
  ('en', 'birthdayWheelDay', 'Day'),
  ('es', 'birthdayWheelDay', 'Día'),
  ('he', 'birthdayWheelDay', 'יום'),
  ('en', 'birthdayWheelYear', 'Year'),
  ('es', 'birthdayWheelYear', 'Año'),
  ('he', 'birthdayWheelYear', 'שנה'),
  ('en', 'profileAgeRequirementNote', 'You must be at least 18 years old to use MatchMe.'),
  ('es', 'profileAgeRequirementNote', 'Debes tener al menos 18 años para usar MatchMe.'),
  ('he', 'profileAgeRequirementNote', 'עליך להיות בן 18 לפחות כדי להשתמש ב-MatchMe.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
