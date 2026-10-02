BEGIN;

INSERT INTO public.translations (key, value, locale)
VALUES
  ('promoCodeLabel', 'Promo Code', 'en'),
  ('promoCodeLabel', 'Código promocional', 'es'),
  ('promoCodeLabel', 'קוד הטבה', 'he'),

  ('promoCodePlaceholder', 'Enter promo code', 'en'),
  ('promoCodePlaceholder', 'Ingresa un código promocional', 'es'),
  ('promoCodePlaceholder', 'הזן קוד הטבה', 'he'),

  ('promoCodeApplyBtn', 'Apply', 'en'),
  ('promoCodeApplyBtn', 'Aplicar', 'es'),
  ('promoCodeApplyBtn', 'החל', 'he'),

  ('promoCodeSection', 'Promo Code', 'en'),
  ('promoCodeSection', 'Código promocional', 'es'),
  ('promoCodeSection', 'קוד הטבה', 'he'),

  ('promoCodeDescription', 'Apply a promotional or discount code to get a special offer', 'en'),
  ('promoCodeDescription', 'Aplica un código promocional o de descuento para obtener una oferta especial', 'es'),
  ('promoCodeDescription', 'החל קוד הטבה או קוד הנחה כדי לקבל הצעה מיוחדת', 'he'),

  ('promoCodeEmpty', 'Please enter a promo code', 'en'),
  ('promoCodeEmpty', 'Por favor ingresa un código promocional', 'es'),
  ('promoCodeEmpty', 'אנא הזן קוד הטבה', 'he'),

  ('promoCodeValid', 'Promo code applied successfully!', 'en'),
  ('promoCodeValid', '¡Código promocional aplicado con éxito!', 'es'),
  ('promoCodeValid', 'קוד ההטבה הוחל בהצלחה!', 'he'),

  ('promoCodeInvalid', 'Invalid or expired promo code', 'en'),
  ('promoCodeInvalid', 'Código promocional inválido o vencido', 'es'),
  ('promoCodeInvalid', 'קוד הטבה לא תקין או שפג תוקפו', 'he'),

  ('promoCodeInvalidFallback', 'Invalid promo code', 'en'),
  ('promoCodeInvalidFallback', 'Código promocional inválido', 'es'),
  ('promoCodeInvalidFallback', 'קוד הטבה לא תקין', 'he'),

  ('promoCodeValidationError', 'Error validating code: {error}', 'en'),
  ('promoCodeValidationError', 'Error al validar el código: {error}', 'es'),
  ('promoCodeValidationError', 'שגיאה באימות הקוד: {error}', 'he'),

  ('promoCodeValidation', 'Validating code...', 'en'),
  ('promoCodeValidation', 'Validando código...', 'es'),
  ('promoCodeValidation', 'מאמת קוד...', 'he'),

  ('promoCodeExpired', 'This promo code has expired', 'en'),
  ('promoCodeExpired', 'Este código promocional ha vencido', 'es'),
  ('promoCodeExpired', 'תוקף קוד ההטבה הזה פג', 'he'),

  ('promoCodeStatusExpired', 'Expired', 'en'),
  ('promoCodeStatusExpired', 'Vencido', 'es'),
  ('promoCodeStatusExpired', 'פג תוקף', 'he'),

  ('promoCodeButtonExpired', 'Code Expired', 'en'),
  ('promoCodeButtonExpired', 'Código vencido', 'es'),
  ('promoCodeButtonExpired', 'תוקף הקוד פג', 'he'),

  ('promoCodeNotYetValid', 'This promo code is not yet valid', 'en'),
  ('promoCodeNotYetValid', 'Este código promocional todavía no es válido', 'es'),
  ('promoCodeNotYetValid', 'קוד ההטבה הזה עדיין לא בתוקף', 'he'),

  ('promoCodeNotApplicable', 'This promo code is not applicable for your selected tier', 'en'),
  ('promoCodeNotApplicable', 'Este código promocional no aplica al nivel seleccionado', 'es'),
  ('promoCodeNotApplicable', 'קוד ההטבה הזה לא חל על הרמה שנבחרה', 'he'),

  ('promoCodeNotApplicableForTier', 'This promo code is not applicable for the {tier} tier', 'en'),
  ('promoCodeNotApplicableForTier', 'Este código promocional no aplica al nivel {tier}', 'es'),
  ('promoCodeNotApplicableForTier', 'קוד ההטבה הזה לא חל על רמת {tier}', 'he'),

  ('promoCodeLimitReached', 'You have already used this promo code the maximum number of times', 'en'),
  ('promoCodeLimitReached', 'Ya usaste este código promocional el número máximo de veces', 'es'),
  ('promoCodeLimitReached', 'כבר השתמשת בקוד ההטבה הזה במספר הפעמים המרבי', 'he'),

  ('promoCodeGlobalLimitReached', 'This promo code has reached its usage limit', 'en'),
  ('promoCodeGlobalLimitReached', 'Este código promocional alcanzó su límite de uso', 'es'),
  ('promoCodeGlobalLimitReached', 'קוד ההטבה הזה הגיע למגבלת השימוש שלו', 'he'),

  ('promoCodeAlreadyUsed', 'You have already used this code', 'en'),
  ('promoCodeAlreadyUsed', 'Ya usaste este código', 'es'),
  ('promoCodeAlreadyUsed', 'כבר השתמשת בקוד הזה', 'he'),

  ('promoCodeUseCount', '{used} of {max} uses remaining', 'en'),
  ('promoCodeUseCount', '{used} de {max} usos restantes', 'es'),
  ('promoCodeUseCount', 'נותרו {used} מתוך {max} שימושים', 'he'),

  ('promoCodeUnlimitedUses', 'Unlimited uses', 'en'),
  ('promoCodeUnlimitedUses', 'Usos ilimitados', 'es'),
  ('promoCodeUnlimitedUses', 'שימושים ללא הגבלה', 'he'),

  ('promoCodeApplied', 'Promo Code Applied', 'en'),
  ('promoCodeApplied', 'Código promocional aplicado', 'es'),
  ('promoCodeApplied', 'קוד הטבה הוחל', 'he'),

  ('promoCodeRemove', 'Remove', 'en'),
  ('promoCodeRemove', 'Quitar', 'es'),
  ('promoCodeRemove', 'הסר', 'he'),

  ('promoCodeRemoveQuestion', 'Remove this promo code?', 'en'),
  ('promoCodeRemoveQuestion', '¿Quitar este código promocional?', 'es'),
  ('promoCodeRemoveQuestion', 'להסיר את קוד ההטבה הזה?', 'he'),

  ('promoCodeCurrentDiscount', 'Current Discount', 'en'),
  ('promoCodeCurrentDiscount', 'Descuento actual', 'es'),
  ('promoCodeCurrentDiscount', 'הנחה נוכחית', 'he'),

  ('promoCodeSavings', 'You save', 'en'),
  ('promoCodeSavings', 'Ahorras', 'es'),
  ('promoCodeSavings', 'אתה חוסך', 'he'),

  ('promoCodeRegularPrice', 'Regular Price', 'en'),
  ('promoCodeRegularPrice', 'Precio regular', 'es'),
  ('promoCodeRegularPrice', 'מחיר רגיל', 'he'),

  ('promoCodeYouPay', 'You Pay', 'en'),
  ('promoCodeYouPay', 'Tú pagas', 'es'),
  ('promoCodeYouPay', 'לתשלום', 'he'),

  ('promoCodeNoExpiry', 'No expiry', 'en'),
  ('promoCodeNoExpiry', 'Sin vencimiento', 'es'),
  ('promoCodeNoExpiry', 'ללא תפוגה', 'he'),

  ('promoCodeExpiresIn', 'Expires in {days} days', 'en'),
  ('promoCodeExpiresIn', 'Vence en {days} días', 'es'),
  ('promoCodeExpiresIn', 'יפוג בעוד {days} ימים', 'he'),

  ('promoCodeExpiresInSingular', 'Expires in {days} day', 'en'),
  ('promoCodeExpiresInSingular', 'Vence en {days} día', 'es'),
  ('promoCodeExpiresInSingular', 'יפוג בעוד {days} יום', 'he'),

  ('promoCodeExpiresInHours', 'Expires in {hours} hours', 'en'),
  ('promoCodeExpiresInHours', 'Vence en {hours} horas', 'es'),
  ('promoCodeExpiresInHours', 'יפוג בעוד {hours} שעות', 'he'),

  ('promoCodeExpiresToday', 'Expires today', 'en'),
  ('promoCodeExpiresToday', 'Vence hoy', 'es'),
  ('promoCodeExpiresToday', 'יפוג היום', 'he'),

  ('promoDiscountPercentageFormat', '{amount}% Off', 'en'),
  ('promoDiscountPercentageFormat', '{amount}% de descuento', 'es'),
  ('promoDiscountPercentageFormat', '{amount}% הנחה', 'he'),

  ('promoDiscountFixedFormat', '{amount} Off', 'en'),
  ('promoDiscountFixedFormat', '{amount} de descuento', 'es'),
  ('promoDiscountFixedFormat', '{amount} הנחה', 'he'),

  ('promoDiscountFreeDaysOneFormat', '{days} day Free', 'en'),
  ('promoDiscountFreeDaysOneFormat', '{days} día gratis', 'es'),
  ('promoDiscountFreeDaysOneFormat', '{days} יום חינם', 'he'),

  ('promoDiscountFreeDaysManyFormat', '{days} days Free', 'en'),
  ('promoDiscountFreeDaysManyFormat', '{days} días gratis', 'es'),
  ('promoDiscountFreeDaysManyFormat', '{days} ימים חינם', 'he'),

  ('promoDiscountTierUpgradeFormat', 'Upgrade to {tier}', 'en'),
  ('promoDiscountTierUpgradeFormat', 'Mejora a {tier}', 'es'),
  ('promoDiscountTierUpgradeFormat', 'שדרג ל-{tier}', 'he'),

  ('promoDiscountSpecialOffer', 'Special Offer', 'en'),
  ('promoDiscountSpecialOffer', 'Oferta especial', 'es'),
  ('promoDiscountSpecialOffer', 'הצעה מיוחדת', 'he'),

  ('paymentTotal', 'Total', 'en'),
  ('paymentTotal', 'Total', 'es'),
  ('paymentTotal', 'סך הכל', 'he'),

  ('paymentPromoRedemptionWarning', 'Warning: Promo code redemption failed: {error}', 'en'),
  ('paymentPromoRedemptionWarning', 'Advertencia: no se pudo canjear el código promocional: {error}', 'es'),
  ('paymentPromoRedemptionWarning', 'אזהרה: מימוש קוד ההטבה נכשל: {error}', 'he'),

  ('paymentFailed', 'Payment failed: {error}', 'en'),
  ('paymentFailed', 'El pago falló: {error}', 'es'),
  ('paymentFailed', 'התשלום נכשל: {error}', 'he')
ON CONFLICT (key, locale) DO UPDATE
SET value = EXCLUDED.value;

COMMIT;
