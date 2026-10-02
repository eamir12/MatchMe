BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminBroadcastsAutomation', 'Automation'),
  ('en', 'adminBroadcastsAutomationBirthday', 'Birthday'),
  ('en', 'adminBroadcastsBirthdayAutomationToggle', 'Automatic birthday greeting'),
  ('en', 'adminBroadcastsBirthdayAutomationHelp', 'Queues this broadcast automatically each year when a recipient''s local birthday begins. It respects the existing admin-announcements notification setting.'),
  ('en', 'adminBroadcastsBirthdayPlaceholdersTitle', 'Birthday placeholders'),
  ('en', 'adminBroadcastsBirthdayPlaceholdersBody', 'Use {first_name} or {name} in the title, message, action URL text, or URL to personalize each birthday greeting.'),
  ('es', 'adminBroadcastsAutomation', 'Automatizacion'),
  ('es', 'adminBroadcastsAutomationBirthday', 'Cumpleanos'),
  ('es', 'adminBroadcastsBirthdayAutomationToggle', 'Saludo automatico de cumpleanos'),
  ('es', 'adminBroadcastsBirthdayAutomationHelp', 'Pone en cola esta difusion automaticamente cada ano cuando empieza el cumpleanos local del destinatario. Respeta la configuracion existente de notificaciones de anuncios administrativos.'),
  ('es', 'adminBroadcastsBirthdayPlaceholdersTitle', 'Marcadores de cumpleanos'),
  ('es', 'adminBroadcastsBirthdayPlaceholdersBody', 'Usa {first_name} o {name} en el titulo, el mensaje, el texto del boton o la URL para personalizar cada saludo de cumpleanos.'),
  ('he', 'adminBroadcastsAutomation', 'אוטומציה'),
  ('he', 'adminBroadcastsAutomationBirthday', 'יום הולדת'),
  ('he', 'adminBroadcastsBirthdayAutomationToggle', 'ברכת יום הולדת אוטומטית'),
  ('he', 'adminBroadcastsBirthdayAutomationHelp', 'מתזמן את השידור הזה אוטומטית בכל שנה כשהיום הולדת המקומי של הנמען מתחיל. מכבד את הגדרת ההתראות הקיימת של הודעות מנהל.'),
  ('he', 'adminBroadcastsBirthdayPlaceholdersTitle', 'משתני יום הולדת'),
  ('he', 'adminBroadcastsBirthdayPlaceholdersBody', 'השתמשו ב-{first_name} או ב-{name} בכותרת, בהודעה, בטקסט הכפתור או ב-URL כדי להתאים אישית כל ברכת יום הולדת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
