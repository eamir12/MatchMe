-- Create table for tracking referral link visits
CREATE TABLE IF NOT EXISTS referral_visits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_code TEXT NOT NULL,
    ip_address TEXT,
    user_agent TEXT,
    claimed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    claimed_at TIMESTAMPTZ
);

-- Index for faster fingerprint lookups
CREATE INDEX IF NOT EXISTS idx_referral_visits_fingerprint 
ON referral_visits(ip_address, user_agent, created_at);

-- Update App Config to point to Edge Function
-- NOTE: User must replace 'YOUR_PROJECT_REF' with actual project ID after deployment
-- For now, we assume a placeholder or user will update it manually.
-- Or better, we set it to a generic value and user updates it.
UPDATE app_config 
SET config_value = '"https://YOUR_PROJECT_REF.supabase.co/functions/v1/invite"' 
WHERE config_key = 'referral.base_url';

-- Insert Translations for Referral UI
INSERT INTO translations (key, locale, value) VALUES
-- English
('inviteFriendsTitle', 'en', 'Invite Friends'),
('inviteFriendsSubtitle', 'en', 'Give Rewards, Get Rewards'),
('inviteFriendsDescription', 'en', 'Share your link. Friends will be guided to download the app.'),
('inviteFriendsShareBtn', 'en', 'Share Link'),
('inviteFriendsCredits', 'en', 'Your Credits: {0}'),
('inviteFriendsError', 'en', 'Could not generate referral code.'),
('inviteFriendsRetry', 'en', 'Retry'),
('inviteFriendsCopied', 'en', 'Code copied to clipboard'),

-- Spanish
('inviteFriendsTitle', 'es', 'Invitar Amigos'),
('inviteFriendsSubtitle', 'es', 'Da Recompensas, Obtén Recompensas'),
('inviteFriendsDescription', 'es', 'Comparte tu enlace. Se guiará a tus amigos para que descarguen la aplicación.'),
('inviteFriendsShareBtn', 'es', 'Compartir Enlace'),
('inviteFriendsCredits', 'es', 'Tus Créditos: {0}'),
('inviteFriendsError', 'es', 'No se pudo generar el código de referencia.'),
('inviteFriendsRetry', 'es', 'Reintentar'),
('inviteFriendsCopied', 'es', 'Código copiado al portapapeles'),

-- Hebrew
('inviteFriendsTitle', 'he', 'הזמן חברים'),
('inviteFriendsSubtitle', 'he', 'תן הטבות, קבל הטבות'),
('inviteFriendsDescription', 'he', 'שתף את הקישור שלך. חברים יודרכו להוריד את האפליקציה.'),
('inviteFriendsShareBtn', 'he', 'שתף קישור'),
('inviteFriendsCredits', 'he', 'הקרדיטים שלך: {0}'),
('inviteFriendsError', 'he', 'לא ניתן היה לייצר קוד הפניה.'),
('inviteFriendsRetry', 'he', 'נסה שוב'),
('inviteFriendsCopied', 'he', 'הקוד הועתק ללוח')

ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;
