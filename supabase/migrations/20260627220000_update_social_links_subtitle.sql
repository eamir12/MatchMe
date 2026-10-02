-- Update the social links subtitle to indicate the step is optional
UPDATE public.translations
SET value = 'Add links to your profiles. This step is optional.'
WHERE key = 'profileSocialLinksSubtitle' AND locale = 'en';

UPDATE public.translations
SET value = 'Añade enlaces a tus perfiles. Este paso es opcional.'
WHERE key = 'profileSocialLinksSubtitle' AND locale = 'es';

UPDATE public.translations
SET value = 'הוסף קישורים לפרופילים שלך. שלב זה הוא אופציונלי.'
WHERE key = 'profileSocialLinksSubtitle' AND locale = 'he';
