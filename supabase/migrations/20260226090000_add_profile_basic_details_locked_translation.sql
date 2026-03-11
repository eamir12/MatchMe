INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileEditBasicDetailsLocked', $$These details are locked. Please request approval to edit them.$$),
  ('es', 'profileEditBasicDetailsLocked', $$Estos datos están bloqueados. Solicita aprobación para editarlos.$$),
  ('he', 'profileEditBasicDetailsLocked', $$פרטים אלה נעולים. נא לבקש אישור כדי לערוך אותם.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
