-- Migration: Update settings descriptions in app_config (if used)
-- Purpose: Store precise, user-friendly descriptions for settings to be fetched by the app
-- Note: The app currently uses local strings in locale_provider.dart, but this allows for remote updates.

INSERT INTO app_config (key, value, description)
VALUES 
(
  'settings.high_accuracy_mode_desc', 
  'Increases location precision and frequency.
• Android: Updates every 30s-15m (requires persistent notification).
• iOS: Updates every ~10m of movement (high battery usage).
• Web: No background updates (foreground only).',
  'Description for High Accuracy Mode setting'
),
(
  'settings.smart_gps_throttling_desc',
  'Automatically reduces update frequency to save battery when:
• Device is stationary (Android only)
• Battery is below 15% (Android only)
• Ignored on iOS (system manages power automatically).',
  'Description for Smart GPS Throttling setting'
)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
