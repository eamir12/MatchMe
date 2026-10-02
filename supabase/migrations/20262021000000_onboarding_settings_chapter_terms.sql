-- Onboarding settings chapter: "Matching vs Match preferences" wording fix
-- The tour narration swapped the two settings sections: distance/age/gender/
-- height/lifestyle/family plans/religion filters live under "Match
-- preferences", while "Matching" is where background matching keeps finding
-- people. Corrects all three locales and also fixes the Spanish title
-- (Coincidencias -> Preferencias de coincidencias) and Hebrew (התאמות ->
-- העדפות התאמה) for the same section.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (later migration wins over earlier seeds).

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatSettings2', 'Under match preferences, you set the distance, age range, gender, height, lifestyle, family plans and religion you are looking for… Under matching, background matching keeps finding people for you while you are away.'),
  ('es', 'onboardingBeatSettings2', 'En preferencias de coincidencias, defines la distancia, el rango de edad, el género, la altura, el estilo de vida, los planes familiares y la religión que buscas… En coincidencias, la búsqueda en segundo plano sigue encontrando personas para ti mientras estás fuera.'),
  ('he', 'onboardingBeatSettings2', 'תחת העדפות התאמה אתם מגדירים מרחק, גילאים, מגדר, גובה, סגנון חיים, תוכניות משפחה ודת… תחת התאמות, ההתאמה ברקע ממשיכה למצוא אנשים בשבילכם גם כשאתם לא כאן.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;