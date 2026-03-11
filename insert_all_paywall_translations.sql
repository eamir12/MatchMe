-- SQL script to insert ALL Paywall, Tier, and Settings translations
-- Languages: English (en), Spanish (es), Hebrew (he)
-- Uses ON CONFLICT to update existing keys

INSERT INTO translations (locale, key, value) VALUES

-- ==========================================
-- ENGLISH (en)
-- ==========================================

-- Subscription Tiers
('en', 'tierPlusTitle', 'MatchMe Plus'),
('en', 'tierPlusSubtitle', 'Stand out from the crowd'),
('en', 'tierPlusFeatures', '["Unlimited Likes", "Rewind last swipe", "5 Super Likes a day"]'),
('en', 'tierGoldTitle', 'MatchMe Gold'),
('en', 'tierGoldSubtitle', 'See who likes you'),
('en', 'tierGoldFeatures', '["See who likes you", "Unlimited Likes", "Rewind", "5 Super Likes", "1 Boost a month"]'),
('en', 'tierPlatinumTitle', 'MatchMe Platinum'),
('en', 'tierPlatinumSubtitle', 'Prioritized likes'),
('en', 'tierPlatinumFeatures', '["Priority Likes", "Message before matching", "See who likes you", "Unlimited Likes"]'),
('en', 'tierBadgeBestValue', 'Best Value'),
('en', 'tierBadgePopular', 'Most Popular'),

-- Paywall General
('en', 'paywallTitle', 'MatchMe Premium'),
('en', 'paywallWebError', 'Premium subscriptions are currently only available on the mobile app.'),
('en', 'paywallFeaturesTitle', 'Unlock everything'),
('en', 'paywallFeatureUnlimitedLikes', 'Unlimited likes'),
('en', 'paywallFeatureSeeWhoLikesYou', 'See who likes you'),
('en', 'paywallFeatureAdvancedFilters', 'Advanced filters'),
('en', 'paywallFeatureNoAds', 'No ads'),

-- Paywall Actions
('en', 'paywallRestore', 'Restore Purchases'),
('en', 'paywallTerms', 'Terms of Service'),
('en', 'paywallPrivacy', 'Privacy Policy'),
('en', 'paywallSubscribe', 'Subscribe'),

-- Subscription Periods
('en', 'paywallPeriodMonthly', 'Monthly'),
('en', 'paywallPeriodAnnual', 'Annual'),
('en', 'paywallPeriodWeekly', 'Weekly'),
('en', 'paywallPeriodLifetime', 'Lifetime'),

-- Badges and Savings
('en', 'paywallSavePercent', 'Save {percent}%'),
('en', 'paywallBestValue', 'Best Value'),
('en', 'paywallPopular', 'Most Popular'),

-- Success/Error Messages
('en', 'paywallPurchaseSuccess', 'Subscription active! Thank you for your support.'),
('en', 'paywallPurchaseFailed', 'Purchase failed. Please try again.'),
('en', 'paywallRestoreSuccess', 'Purchases restored successfully.'),
('en', 'paywallRestoreNoActive', 'No active subscriptions found to restore.'),
('en', 'paywallRestoreFailed', 'Failed to restore purchases.'),

-- Settings Screen (Premium Section)
('en', 'settingsGoPremium', 'Go Premium'),
('en', 'settingsUnlockExclusive', 'Unlock exclusive features'),
('en', 'settingsPremiumActive', 'Premium Active'),
('en', 'settingsPremiumThanks', 'Thanks for your support!'),
('en', 'settingsManageSubscription', 'Manage'),
('en', 'durationDay', '{count} day'),
('en', 'durationDays', '{count} days'),
('en', 'durationHour', '{count} hour'),
('en', 'durationHours', '{count} hours'),
('en', 'durationMinute', '{count} minute'),
('en', 'durationMinutes', '{count} minutes'),
('en', 'durationLessThanOneMinute', '< 1 minute'),


-- ==========================================
-- SPANISH (es)
-- ==========================================

-- Subscription Tiers
('es', 'tierPlusTitle', 'MatchMe Plus'),
('es', 'tierPlusSubtitle', 'Destaca entre la multitud'),
('es', 'tierPlusFeatures', '["Likes ilimitados", "Rebobinar último swipe", "5 Super Likes al día"]'),
('es', 'tierGoldTitle', 'MatchMe Gold'),
('es', 'tierGoldSubtitle', 'Mira a quién le gustas'),
('es', 'tierGoldFeatures', '["Mira a quién le gustas", "Likes ilimitados", "Rebobinar", "5 Super Likes", "1 Boost al mes"]'),
('es', 'tierPlatinumTitle', 'MatchMe Platinum'),
('es', 'tierPlatinumSubtitle', 'Likes prioritarios'),
('es', 'tierPlatinumFeatures', '["Likes prioritarios", "Mensaje antes de hacer match", "Mira a quién le gustas", "Likes ilimitados"]'),
('es', 'tierBadgeBestValue', 'Mejor valor'),
('es', 'tierBadgePopular', 'Más popular'),

-- Paywall General
('es', 'paywallTitle', 'MatchMe Premium'),
('es', 'paywallWebError', 'Las suscripciones Premium solo están disponibles en la aplicación móvil.'),
('es', 'paywallFeaturesTitle', 'Desbloquea todo'),
('es', 'paywallFeatureUnlimitedLikes', 'Likes ilimitados'),
('es', 'paywallFeatureSeeWhoLikesYou', 'Mira a quién le gustas'),
('es', 'paywallFeatureAdvancedFilters', 'Filtros avanzados'),
('es', 'paywallFeatureNoAds', 'Sin anuncios'),

-- Paywall Actions
('es', 'paywallRestore', 'Restaurar compras'),
('es', 'paywallTerms', 'Términos de servicio'),
('es', 'paywallPrivacy', 'Política de privacidad'),
('es', 'paywallSubscribe', 'Suscribirse'),

-- Subscription Periods
('es', 'paywallPeriodMonthly', 'Mensual'),
('es', 'paywallPeriodAnnual', 'Anual'),
('es', 'paywallPeriodWeekly', 'Semanal'),
('es', 'paywallPeriodLifetime', 'De por vida'),

-- Badges and Savings
('es', 'paywallSavePercent', 'Ahorra {percent}%'),
('es', 'paywallBestValue', 'Mejor valor'),
('es', 'paywallPopular', 'Más popular'),

-- Success/Error Messages
('es', 'paywallPurchaseSuccess', '¡Suscripción activa! Gracias por tu apoyo.'),
('es', 'paywallPurchaseFailed', 'La compra falló. Por favor inténtalo de nuevo.'),
('es', 'paywallRestoreSuccess', 'Compras restauradas con éxito.'),
('es', 'paywallRestoreNoActive', 'No se encontraron suscripciones activas para restaurar.'),
('es', 'paywallRestoreFailed', 'Error al restaurar las compras.'),

-- Settings Screen (Premium Section)
('es', 'settingsGoPremium', 'Hazte Premium'),
('es', 'settingsUnlockExclusive', 'Desbloquea funciones exclusivas'),
('es', 'settingsPremiumActive', 'Premium Activo'),
('es', 'settingsPremiumThanks', '¡Gracias por tu apoyo!'),
('es', 'settingsManageSubscription', 'Administrar'),
('es', 'durationDay', '{count} día'),
('es', 'durationDays', '{count} días'),
('es', 'durationHour', '{count} hora'),
('es', 'durationHours', '{count} horas'),
('es', 'durationMinute', '{count} minuto'),
('es', 'durationMinutes', '{count} minutos'),
('es', 'durationLessThanOneMinute', '< 1 minuto'),


-- ==========================================
-- HEBREW (he)
-- ==========================================

-- Subscription Tiers
('he', 'tierPlusTitle', 'MatchMe Plus'),
('he', 'tierPlusSubtitle', 'בלוט מעל כולם'),
('he', 'tierPlusFeatures', '["לייקים ללא הגבלה", "ביטול החלקה אחרונה", "5 סופר-לייקים ביום"]'),
('he', 'tierGoldTitle', 'MatchMe Gold'),
('he', 'tierGoldSubtitle', 'ראה מי אהב אותך'),
('he', 'tierGoldFeatures', '["ראה מי אהב אותך", "לייקים ללא הגבלה", "ביטול החלקה", "5 סופר-לייקים", "בוסט אחד בחודש"]'),
('he', 'tierPlatinumTitle', 'MatchMe Platinum'),
('he', 'tierPlatinumSubtitle', 'לייקים בעדיפות'),
('he', 'tierPlatinumFeatures', '["לייקים בעדיפות", "הודעה לפני התאמה", "ראה מי אהב אותך", "לייקים ללא הגבלה"]'),
('he', 'tierBadgeBestValue', 'המשתלם ביותר'),
('he', 'tierBadgePopular', 'הפופולרי ביותר'),

-- Paywall General
('he', 'paywallTitle', 'MatchMe Premium'),
('he', 'paywallWebError', 'מנויי פרימיום זמינים כרגע רק באפליקציה לנייד.'),
('he', 'paywallFeaturesTitle', 'לפתוח את הכל'),
('he', 'paywallFeatureUnlimitedLikes', 'לייקים ללא הגבלה'),
('he', 'paywallFeatureSeeWhoLikesYou', 'לראות מי עשה לך לייק'),
('he', 'paywallFeatureAdvancedFilters', 'מסננים מתקדמים'),
('he', 'paywallFeatureNoAds', 'ללא פרסומות'),

-- Paywall Actions
('he', 'paywallRestore', 'שחזור רכישות'),
('he', 'paywallTerms', 'תנאי שימוש'),
('he', 'paywallPrivacy', 'מדיניות פרטיות'),
('he', 'paywallSubscribe', 'הרשמה'),

-- Subscription Periods
('he', 'paywallPeriodMonthly', 'חודשי'),
('he', 'paywallPeriodAnnual', 'שנתי'),
('he', 'paywallPeriodWeekly', 'שבועי'),
('he', 'paywallPeriodLifetime', 'לכל החיים'),

-- Badges and Savings
('he', 'paywallSavePercent', 'חיסכון של {percent}%'),
('he', 'paywallBestValue', 'המשתלם ביותר'),
('he', 'paywallPopular', 'הפופולרי ביותר'),

-- Success/Error Messages
('he', 'paywallPurchaseSuccess', 'המנוי פעיל! תודה על התמיכה.'),
('he', 'paywallPurchaseFailed', 'הרכישה נכשלה. אנא נסה שנית.'),
('he', 'paywallRestoreSuccess', 'הרכישות שוחזרו בהצלחה.'),
('he', 'paywallRestoreNoActive', 'לא נמצאו מנויים פעילים לשחזור.'),
('he', 'paywallRestoreFailed', 'שחזור הרכישות נכשל.'),

-- Settings Screen (Premium Section)
('he', 'settingsGoPremium', 'עבור לפרימיום'),
('he', 'settingsUnlockExclusive', 'פתח תכונות בלעדיות'),
('he', 'settingsPremiumActive', 'פרימיום פעיל'),
('he', 'settingsPremiumThanks', 'תודה על התמיכה!'),
('he', 'settingsManageSubscription', 'ניהול'),
('he', 'durationDay', '{count} יום'),
('he', 'durationDays', '{count} ימים'),
('he', 'durationHour', '{count} שעה'),
('he', 'durationHours', '{count} שעות'),
('he', 'durationMinute', '{count} דקה'),
('he', 'durationMinutes', '{count} דקות'),
('he', 'durationLessThanOneMinute', '< 1 דקה')

ON CONFLICT (locale, key) DO UPDATE SET
    value = EXCLUDED.value;
