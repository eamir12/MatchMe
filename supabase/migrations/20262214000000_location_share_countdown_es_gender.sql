-- Spanish live-location countdown: the adjective agreed with one unit only.
--
-- "por otras {duration}" was written for "otras dos horas". The client builds
-- that fragment unit by unit, so it also carries minutos, segundos and días,
-- where "otras" is the wrong gender, and a single hour reads "por otras 1
-- hora" — a plural article on a singular noun. The replacement names no noun
-- and agrees with nothing, so it is right whichever unit the countdown lands
-- on. The fragment appears in four places and composes in all of them: the
-- share banner and the share map wrap it in parentheses, the countdown line
-- joins it with a dash, and the Meet up hub puts it inside
-- meetupHubLiveSharingFor ("Estás compartiendo ubicación por 42 minutos más").
--
-- The English and Hebrew rows already name no noun and stay untouched.

INSERT INTO public.translations (locale, key, value) VALUES
('es', 'locationShareCountdownRemaining', 'por {duration} más')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
