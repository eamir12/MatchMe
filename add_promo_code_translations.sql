-- Add Promo Code Translations for Multi-Language Support
-- Languages: English (en), Spanish (es), Hebrew (he)

BEGIN;

INSERT INTO public.translations (key, value, locale) VALUES
  -- ENGLISH (en)
  ('promoCodeLabel', 'Promo Code', 'en'),
  ('promoCodePlaceholder', 'Enter promo code', 'en'),
  ('promoCodeApplyBtn', 'Apply', 'en'),
  ('promoCodeEmpty', 'Please enter a promo code', 'en'),
  ('promoCodeValid', 'Promo code applied successfully!', 'en'),
  ('promoCodeInvalid', 'Invalid or expired promo code', 'en'),
  ('promoCodeExpired', 'This promo code has expired', 'en'),
  ('promoCodeLimitReached', 'You have already used this promo code the maximum number of times', 'en'),
  ('promoCodeGlobalLimitReached', 'This promo code has reached its usage limit', 'en'),
  ('promoCodeNotYetValid', 'This promo code is not yet valid', 'en'),
  ('promoCodeNotApplicable', 'This promo code is not applicable for your selected tier', 'en'),
  ('promoCodeApplied', 'Promo Code Applied', 'en'),
  ('promoCodeRemove', 'Remove', 'en'),
  ('promoCodeRemoveQuestion', 'Remove this promo code?', 'en'),
  ('promoCodeSection', 'Have a promo code?', 'en'),
  ('promoCodeCurrentDiscount', 'Current Discount', 'en'),
  ('promoCodeSavings', 'You save', 'en'),
  ('promoCodeExpiresIn', 'Expires in {days} days', 'en'),
  ('promoCodeExpiresInSingular', 'Expires in {days} day', 'en'),
  ('promoCodeExpiresInHours', 'Expires in {hours} hours', 'en'),
  ('promoCodeExpiresToday', 'Expires today', 'en'),
  ('promoCodeAlreadyUsed', 'You have already used this code', 'en'),
  ('promoCodeUseCount', '{used} of {max} uses remaining', 'en'),
  ('promoCodeUnlimitedUses', 'Unlimited uses', 'en'),
  ('promoCodeValidation', 'Validating code...', 'en'),
  ('promoCodeDescription', 'Apply a promotional or discount code to get a special offer', 'en'),

  -- SPANISH (es)
  ('promoCodeLabel', 'Código promocional', 'es'),
  ('promoCodePlaceholder', 'Ingresa un código promocional', 'es'),
  ('promoCodeApplyBtn', 'Aplicar', 'es'),
  ('promoCodeEmpty', 'Por favor, ingresa un código de promoción', 'es'),
  ('promoCodeValid', '¡Código de promoción aplicado con éxito!', 'es'),
  ('promoCodeInvalid', 'Código de promoción inválido o expirado', 'es'),
  ('promoCodeExpired', 'Este código de promoción ha expirado', 'es'),
  ('promoCodeLimitReached', 'Ya has usado este código de promoción el máximo número de veces', 'es'),
  ('promoCodeGlobalLimitReached', 'Este código de promoción ha alcanzado su límite de uso', 'es'),
  ('promoCodeNotYetValid', 'Este código de promoción aún no es válido', 'es'),
  ('promoCodeNotApplicable', 'Este código de promoción no es aplicable a tu tier seleccionado', 'es'),
  ('promoCodeApplied', 'Código Promocional Aplicado', 'es'),
  ('promoCodeRemove', 'Eliminar', 'es'),
  ('promoCodeRemoveQuestion', '¿Eliminar este código de promoción?', 'es'),
  ('promoCodeSection', '¿Tienes un código de promoción?', 'es'),
  ('promoCodeCurrentDiscount', 'Descuento Actual', 'es'),
  ('promoCodeSavings', 'Ahorras', 'es'),
  ('promoCodeExpiresIn', 'Expira en {days} días', 'es'),
  ('promoCodeExpiresInSingular', 'Expira en {days} día', 'es'),
  ('promoCodeExpiresInHours', 'Expira en {hours} horas', 'es'),
  ('promoCodeExpiresToday', 'Expira hoy', 'es'),
  ('promoCodeAlreadyUsed', 'Ya has usado este código', 'es'),
  ('promoCodeUseCount', '{used} de {max} usos restantes', 'es'),
  ('promoCodeUnlimitedUses', 'Usos ilimitados', 'es'),
  ('promoCodeValidation', 'Validando código...', 'es'),
  ('promoCodeDescription', 'Aplica un código promocional o de descuento para obtener una oferta especial', 'es'),

  -- HEBREW (he)
  ('promoCodeLabel', 'קוד הטבה', 'he'),
  ('promoCodePlaceholder', 'הזן קוד הטבה', 'he'),
  ('promoCodeApplyBtn', 'החל', 'he'),
  ('promoCodeEmpty', 'אנא הזן קוד הטבה', 'he'),
  ('promoCodeValid', 'קוד ההטבה הוחל בהצלחה!', 'he'),
  ('promoCodeInvalid', 'קוד הטבה לא חוקי או פג תוקף', 'he'),
  ('promoCodeExpired', 'קוד ההטבה הזה פג תוקף', 'he'),
  ('promoCodeLimitReached', 'כבר השתמשת בקוד הטבה זה במספר הפעמים המרבי', 'he'),
  ('promoCodeGlobalLimitReached', 'קוד ההטבה הזה הגיע לגבול ההשימושים שלו', 'he'),
  ('promoCodeNotYetValid', 'קוד ההטבה הזה עדיין לא חוקי', 'he'),
  ('promoCodeNotApplicable', 'קוד הטבה זה אינו חל על השכבה שבחרת', 'he'),
  ('promoCodeApplied', 'קוד הטבה הוחל', 'he'),
  ('promoCodeRemove', 'הסר', 'he'),
  ('promoCodeRemoveQuestion', 'הסר את קוד ההטבה הזה?', 'he'),
  ('promoCodeSection', 'יש לך קוד הטבה?', 'he'),
  ('promoCodeCurrentDiscount', 'ההנחה הנוכחית', 'he'),
  ('promoCodeSavings', 'אתה חוסך', 'he'),
  ('promoCodeExpiresIn', 'פג תוקף בעוד {days} ימים', 'he'),
  ('promoCodeExpiresInSingular', 'פג תוקף בעוד {days} יום', 'he'),
  ('promoCodeExpiresInHours', 'פג תוקף בעוד {hours} שעות', 'he'),
  ('promoCodeExpiresToday', 'פג תוקף היום', 'he'),
  ('promoCodeAlreadyUsed', 'כבר השתמשת בקוד זה', 'he'),
  ('promoCodeUseCount', '{used} מתוך {max} שימושים נותרים', 'he'),
  ('promoCodeUnlimitedUses', 'שימושים בלתי מוגבלים', 'he'),
  ('promoCodeValidation', 'אימות קוד...', 'he'),
  ('promoCodeDescription', 'החל קוד הטבה או הנחה כדי לקבל הצעה מיוחדת', 'he')

ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;

COMMENT ON TABLE public.translations IS 'Updated with promo code translation keys for multi-language support';
