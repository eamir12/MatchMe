BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adsSponsoredLabel', 'Sponsored'),
  ('es', 'adsSponsoredLabel', 'Patrocinado'),
  ('he', 'adsSponsoredLabel', 'ממומן'),

  ('en', 'adsLearnMore', 'Learn more'),
  ('es', 'adsLearnMore', 'Más información'),
  ('he', 'adsLearnMore', 'למידע נוסף'),

  ('en', 'adsWhyAmISeeingThisTitle', 'Why am I seeing this?'),
  ('es', 'adsWhyAmISeeingThisTitle', '¿Por qué veo esto?'),
  ('he', 'adsWhyAmISeeingThisTitle', 'למה אני רואה את זה?'),

  ('en', 'adsWhyAmISeeingThisBody', 'This sponsored card is shown only to free-tier users. MatchMe limits ad frequency and only allows approved family-safe campaigns.'),
  ('es', 'adsWhyAmISeeingThisBody', 'Esta tarjeta patrocinada se muestra solo a usuarios del nivel gratuito. MatchMe limita la frecuencia de los anuncios y solo permite campañas aprobadas aptas para toda la familia.'),
  ('he', 'adsWhyAmISeeingThisBody', 'כרטיס ממומן זה מוצג רק למשתמשים במסלול החינמי. MatchMe מגבילה את תדירות המודעות ומאפשרת רק קמפיינים מאושרים ובטוחים למשפחה.'),

  ('en', 'adsReportAction', 'Report ad'),
  ('es', 'adsReportAction', 'Reportar anuncio'),
  ('he', 'adsReportAction', 'דווח על מודעה'),

  ('en', 'adsReportSubmitted', 'Thanks for the report.'),
  ('es', 'adsReportSubmitted', 'Gracias por tu reporte.'),
  ('he', 'adsReportSubmitted', 'תודה על הדיווח.'),

  ('en', 'adsReportFailed', 'We could not submit your ad report right now. Please try again.'),
  ('es', 'adsReportFailed', 'No pudimos enviar tu reporte del anuncio en este momento. Inténtalo de nuevo.'),
  ('he', 'adsReportFailed', 'לא הצלחנו לשלוח את הדיווח על המודעה כרגע. נסה שוב.'),

  ('en', 'adsOpenLinkFailed', 'We could not open the sponsor link right now.'),
  ('es', 'adsOpenLinkFailed', 'No pudimos abrir el enlace del patrocinador en este momento.'),
  ('he', 'adsOpenLinkFailed', 'לא הצלחנו לפתוח את הקישור של נותן החסות כרגע.'),

  ('en', 'adsSponsoredBy', 'Sponsored by {sponsor}'),
  ('es', 'adsSponsoredBy', 'Patrocinado por {sponsor}'),
  ('he', 'adsSponsoredBy', 'בחסות {sponsor}')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
