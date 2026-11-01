-- Notification settings copy for the consolidated meet-up hub.
--
-- The "Find each other" screen is retired; the same alerts are now configured
-- under the meet-up name and include meeting-point proposal and place-change
-- notifications.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'settingsNotificationsMeetupTools', 'Meet-up alerts'),
('es', 'settingsNotificationsMeetupTools', 'Avisos de encuentro'),
('he', 'settingsNotificationsMeetupTools', 'התראות מפגש'),
('en', 'settingsNotificationsMeetupToolsDesc', 'Waves, beacons, Spot me cards and meeting-point updates from your matches'),
('es', 'settingsNotificationsMeetupToolsDesc', 'Saludos, balizas, tarjetas de Ubícame y cambios de punto de encuentro de tus coincidencias'),
('he', 'settingsNotificationsMeetupToolsDesc', 'נופפים, איתותים, כרטיסי "מצא אותי" ועדכוני נקודת מפגש מההתאמות שלך')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
