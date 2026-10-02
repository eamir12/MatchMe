-- ============================================================================
-- Fixes for the Admin App "Internal Ad System" audit.
--
-- 1. Restore `generalAdd` to "Add". Migration
--    20261901001200_complete_match_inspector_translations.sql overwrote this
--    generic key with "Select User" so the Sponsored Ads Add/Edit tab
--    (and the ad-unit / ad-network prototypes) rendered as "Select User".
-- 2. Repair ad_creatives rows whose `platform` was corrupted to a placement
--    name by the admin app's offline cache round-trip (it wrote
--    placementEntry.key instead of platformEntry.key), deduplicate them, then
--    add UNIQUE (campaign_id, placement, platform). The corruption made the
--    editor re-INSERT creatives on every save instead of updating them, so
--    duplicates accumulated.
-- 3. REPLICA IDENTITY FULL on ad_campaigns / ad_creatives so realtime
--    UPDATE/DELETE payloads carry the full row (not just the PK).
-- 4. Remove the dead `ads.allowed_placements` config row. Nothing reads it;
--    the real key is `ads.internal.allowed_placements`.
-- 5. Seed the ad-screen translation keys that only existed in loose root-level
--    scripts (so Hebrew/Spanish admins stop seeing English), and add the new
--    ad-editor keys introduced by the client fixes.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Restore the hijacked generic `generalAdd` key.
-- ---------------------------------------------------------------------------
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'generalAdd', $$Add$$),
  ('es', 'generalAdd', $$Agregar$$),
  ('he', 'generalAdd', $$הוסף$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- ---------------------------------------------------------------------------
-- 2a) FIRST repair creatives whose `platform` was corrupted to a placement
--     name by the admin app's offline cache writer (it wrote
--     placementEntry.key instead of platformEntry.key). Map them onto the
--     'all' platform, which the ad_creatives platform CHECK constraint allows.
--
--     This must run BEFORE deduplication: repairing afterwards could collapse
--     two previously-distinct groups into one and make the UNIQUE index below
--     fail to build.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.ad_creatives
     WHERE platform IN ('home_inline', 'matches_inline', 'chats_inline',
                        'events_inline', 'profile_inline')
  ) THEN
    UPDATE public.ad_creatives
       SET platform = 'all'
     WHERE platform IN ('home_inline', 'matches_inline', 'chats_inline',
                        'events_inline', 'profile_inline');
    RAISE NOTICE 'Repaired ad_creatives rows with a placement value in platform';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2b) Deduplicate ad_creatives, then enforce uniqueness per
--     (campaign_id, placement, platform).
--
--     Keep the oldest row per group so historical impression/click/report
--     rows have a stable target. Any rows pointing at a removed duplicate are
--     re-pointed at the survivor first.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_removed_ids uuid[];
BEGIN
  SELECT COALESCE(array_agg(dup.id), '{}'::uuid[])
  INTO v_removed_ids
  FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY campaign_id, placement, platform
             ORDER BY created_at ASC, id ASC
           ) AS rn
    FROM public.ad_creatives
  ) dup
  WHERE dup.rn > 1;

  IF array_length(v_removed_ids, 1) IS NOT NULL THEN
    -- Re-point dependent rows at the surviving creative of the same group.
    UPDATE public.ad_impressions im
       SET creative_id = keep.id
      FROM public.ad_creatives dup
      JOIN public.ad_creatives keep
        ON keep.campaign_id = dup.campaign_id
       AND keep.placement = dup.placement
       AND keep.platform = dup.platform
     WHERE im.creative_id = dup.id
       AND dup.id = ANY (v_removed_ids);

    UPDATE public.ad_clicks cl
       SET creative_id = keep.id
      FROM public.ad_creatives dup
      JOIN public.ad_creatives keep
        ON keep.campaign_id = dup.campaign_id
       AND keep.placement = dup.placement
       AND keep.platform = dup.platform
     WHERE cl.creative_id = dup.id
       AND dup.id = ANY (v_removed_ids);

    UPDATE public.ad_reports rp
       SET creative_id = keep.id
      FROM public.ad_creatives dup
      JOIN public.ad_creatives keep
        ON keep.campaign_id = dup.campaign_id
       AND keep.placement = dup.placement
       AND keep.platform = dup.platform
     WHERE rp.creative_id = dup.id
       AND dup.id = ANY (v_removed_ids);

    DELETE FROM public.ad_creatives WHERE id = ANY (v_removed_ids);

    RAISE NOTICE 'Removed % duplicate ad_creatives rows', array_length(v_removed_ids, 1);
  END IF;
END $$;

-- Now that the data is clean, enforce one creative per campaign/placement/platform.
DROP INDEX IF EXISTS public.idx_ad_creatives_unique_combo;
CREATE UNIQUE INDEX IF NOT EXISTS idx_ad_creatives_unique_combo
  ON public.ad_creatives (campaign_id, placement, platform);

-- ---------------------------------------------------------------------------
-- 3) REPLICA IDENTITY FULL so realtime UPDATE/DELETE events carry full rows.
-- ---------------------------------------------------------------------------
ALTER TABLE public.ad_campaigns REPLICA IDENTITY FULL;
ALTER TABLE public.ad_creatives REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- 4) Drop the dead `ads.allowed_placements` row. The ad system reads
--    `ads.internal.allowed_placements`; nothing has ever read this key.
--    Do not touch `ads.external.allowed_placements`.
-- ---------------------------------------------------------------------------
DELETE FROM public.app_config WHERE config_key = 'ads.allowed_placements';

-- Ensure the internal master placement list matches what the admin UI offers
-- (5 placements, including profile_inline).
UPDATE public.app_config
   SET config_value = '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb,
       config_type = 'array',
       updated_at = NOW()
 WHERE config_key = 'ads.internal.allowed_placements'
   AND NOT (config_value @> '["profile_inline"]'::jsonb);

-- ---------------------------------------------------------------------------
-- 5) Translation keys.
-- ---------------------------------------------------------------------------

-- Date-range presets: previously only in the loose root file
-- fix_unabbreviated_units_and_missing_keys.sql, never in a migration.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminAdsRange7d', $$7 days$$),
  ('es', 'adminAdsRange7d', $$7 días$$),
  ('he', 'adminAdsRange7d', $$7 ימים$$),
  ('en', 'adminAdsRange30d', $$30 days$$),
  ('es', 'adminAdsRange30d', $$30 días$$),
  ('he', 'adminAdsRange30d', $$30 ימים$$),
  ('en', 'adminAdsRange90d', $$90 days$$),
  ('es', 'adminAdsRange90d', $$90 días$$),
  ('he', 'adminAdsRange90d', $$90 ימים$$),
  ('en', 'adminAdsRangeAll', $$All$$),
  ('es', 'adminAdsRangeAll', $$Todo$$),
  ('he', 'adminAdsRangeAll', $$הכול$$),
  ('en', 'adminAdsRangeCustom', $$Custom$$),
  ('es', 'adminAdsRangeCustom', $$Personalizado$$),
  ('he', 'adminAdsRangeCustom', $$מותאם אישית$$),
  ('en', 'adminAdsRangeCustomApplied', $$Custom range$$),
  ('es', 'adminAdsRangeCustomApplied', $$Intervalo personalizado$$),
  ('he', 'adminAdsRangeCustomApplied', $$טווח מותאם אישית$$),
  ('en', 'adminAdsRangeClear', $$Clear$$),
  ('es', 'adminAdsRangeClear', $$Limpiar$$),
  ('he', 'adminAdsRangeClear', $$נקה$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Previously English-only in main.dart.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminSponsoredAdsMetricLastEventTime', $$Last event: {time}$$),
  ('es', 'adminSponsoredAdsMetricLastEventTime', $$Último evento: {time}$$),
  ('he', 'adminSponsoredAdsMetricLastEventTime', $$אירוע אחרון: {time}$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- New keys introduced by the ad-editor fixes.
INSERT INTO public.translations (locale, key, value) VALUES

  -- Dedicated Add/Edit tab labels, so the tab no longer depends on the
  -- generic `generalAdd` / `generalEdit` keys.
  ('en', 'adminSponsoredAdsTabAdd', $$Add$$),
  ('es', 'adminSponsoredAdsTabAdd', $$Agregar$$),
  ('he', 'adminSponsoredAdsTabAdd', $$הוסף$$),
  ('en', 'adminSponsoredAdsTabEdit', $$Edit$$),
  ('es', 'adminSponsoredAdsTabEdit', $$Editar$$),
  ('he', 'adminSponsoredAdsTabEdit', $$ערוך$$),

  -- Previously hard-coded English inside the editor.
  ('en', 'adminInternalAdsPlatformDisabledByMaster', $$Enable this platform in Ad Controls first.$$),
  ('es', 'adminInternalAdsPlatformDisabledByMaster', $$Activa esta plataforma en Controles de anuncios primero.$$),
  ('he', 'adminInternalAdsPlatformDisabledByMaster', $$יש להפעיל את הפלטפורמה הזו בבקרת פרסומות תחילה.$$),
  ('en', 'adminInternalAdsTierNotInMaster', $$This tier is not in the master allowed list. Deselect it to remove.$$),
  ('es', 'adminInternalAdsTierNotInMaster', $$Esta categoría no está en la lista maestra permitida. Desmárcala para quitarla.$$),
  ('he', 'adminInternalAdsTierNotInMaster', $$הרמה זו אינה ברשימה המאושרת. הסר אותה כדי להסיר אותה.$$),
  ('en', 'adminInternalAdsTierDisabledByMaster', $$Enable this tier in Ad Controls first.$$),
  ('es', 'adminInternalAdsTierDisabledByMaster', $$Activa esta categoría en Controles de anuncios primero.$$),
  ('he', 'adminInternalAdsTierDisabledByMaster', $$יש להפעיל את הרמה הזו בבקרת פרסומות תחילה.$$),

  -- Start-time guidance (previously three hard-coded English sentences).
  ('en', 'adminSponsoredAdsStartsAtHintEmpty', $$If no start time is selected, this campaign starts immediately when you save it.$$),
  ('es', 'adminSponsoredAdsStartsAtHintEmpty', $$Si no se selecciona una hora de inicio, esta campaña comienza inmediatamente al guardarla.$$),
  ('he', 'adminSponsoredAdsStartsAtHintEmpty', $$אם לא נבחרה שעת התחלה, הקמפיין יתחיל מיד בעת השמירה.$$),
  ('en', 'adminSponsoredAdsStartsAtHintFuture', $$This campaign is scheduled for the future and will not appear in the app until that time.$$),
  ('es', 'adminSponsoredAdsStartsAtHintFuture', $$Esta campaña está programada para el futuro y no aparecerá en la app hasta entonces.$$),
  ('he', 'adminSponsoredAdsStartsAtHintFuture', $$הקמפיין מתוזמן לעתיד ולא יופיע באפליקציה עד אז.$$),
  ('en', 'adminSponsoredAdsStartsAtHintNow', $$This campaign can start serving immediately, subject to other ad eligibility rules.$$),
  ('es', 'adminSponsoredAdsStartsAtHintNow', $$Esta campaña puede comenzar a mostrarse de inmediato, sujeta a otras reglas de elegibilidad de anuncios.$$),
  ('he', 'adminSponsoredAdsStartsAtHintNow', $$הקמפיין יכול להתחיל להוצג מיד, בכפוף לכללי זכאות אחרים לפרסומות.$$),

  -- Campaign filter chips (adds a distinct "Rejected" and "Disabled" filter).
  ('en', 'adminSponsoredAdsFilterRejected', $$Rejected$$),
  ('es', 'adminSponsoredAdsFilterRejected', $$Rechazada$$),
  ('he', 'adminSponsoredAdsFilterRejected', $$נדחתה$$),
  ('en', 'adminSponsoredAdsFilterDisabled', $$Disabled$$),
  ('es', 'adminSponsoredAdsFilterDisabled', $$Desactivada$$),
  ('he', 'adminSponsoredAdsFilterDisabled', $$מושבתת$$),

  -- Impression caps.
  ('en', 'adminSponsoredAdsDailyCap', $$Daily impression cap$$),
  ('es', 'adminSponsoredAdsDailyCap', $$Límite diario de impresiones$$),
  ('he', 'adminSponsoredAdsDailyCap', $$מכסת חשיפות יומית$$),
  ('en', 'adminSponsoredAdsTotalCap', $$Total impression cap$$),
  ('es', 'adminSponsoredAdsTotalCap', $$Límite total de impresiones$$),
  ('he', 'adminSponsoredAdsTotalCap', $$מכסת חשיפות כוללת$$),

  -- Validation errors.
  ('en', 'adminSponsoredAdsValidationAdvertiserName', $$Advertiser name is required.$$),
  ('es', 'adminSponsoredAdsValidationAdvertiserName', $$El nombre del anunciante es obligatorio.$$),
  ('he', 'adminSponsoredAdsValidationAdvertiserName', $$שם המפרסם הוא שדה חובה.$$),
  ('en', 'adminSponsoredAdsValidationDestinationUrlRequired', $$Destination URL is required.$$),
  ('es', 'adminSponsoredAdsValidationDestinationUrlRequired', $$La URL de destino es obligatoria.$$),
  ('he', 'adminSponsoredAdsValidationDestinationUrlRequired', $$כתובת היעד היא שדה חובה.$$),
  ('en', 'adminSponsoredAdsValidationPlatformRequired', $$Select at least one platform.$$),
  ('es', 'adminSponsoredAdsValidationPlatformRequired', $$Selecciona al menos una plataforma.$$),
  ('he', 'adminSponsoredAdsValidationPlatformRequired', $$יש לבחור לפחות פלטפורמה אחת.$$),
  ('en', 'adminSponsoredAdsValidationTierRequired', $$Select at least one subscription tier.$$),
  ('es', 'adminSponsoredAdsValidationTierRequired', $$Selecciona al menos una categoría de suscripción.$$),
  ('he', 'adminSponsoredAdsValidationTierRequired', $$יש לבחור לפחות רמת מינוי אחת.$$),
  ('en', 'adminSponsoredAdsValidationEndAfterStart', $$End time must be after the start time.$$),
  ('es', 'adminSponsoredAdsValidationEndAfterStart', $$La hora de fin debe ser posterior a la hora de inicio.$$),
  ('he', 'adminSponsoredAdsValidationEndAfterStart', $$שעת הסיום חייבת להיות אחרי שעת ההתחלה.$$),
  ('en', 'adminSponsoredAdsSortPriorityHint', $$Lower numbers are shown first.$$),
  ('es', 'adminSponsoredAdsSortPriorityHint', $$Los números más bajos se muestran primero.$$),
  ('he', 'adminSponsoredAdsSortPriorityHint', $$מספרים נמוכים יותר מוצגים ראשונים.$$),

  -- Unverified-config warning.
  ('en', 'adminSponsoredAdsConfigUnverified', $$Configuration could not be verified from the server. Saving now would overwrite your current settings with defaults. Retry the load, or reconnect and try again.$$),
  ('es', 'adminSponsoredAdsConfigUnverified', $$No se pudo verificar la configuración desde el servidor. Guardar ahora sobrescribiría tus ajustes actuales con los valores predeterminados. Reintenta la carga o vuelve a conectarte.$$),
  ('he', 'adminSponsoredAdsConfigUnverified', $$לא ניתן לאמת את התצורה מהשרת. שמירה עכשיו תדרוס את ההגדרות הקיימות בערכי ברירת המחדל. נסה לטעון שוב או התחבר מחדש.$$),

  -- Save-failure messaging for silent no-op writes.
  ('en', 'adminSponsoredAdsWriteRejected', $$The server rejected the change (no rows were updated). Check that your admin account still has permission, then retry.$$),
  ('es', 'adminSponsoredAdsWriteRejected', $$El servidor rechazó el cambio (no se actualizó ninguna fila). Comprueba que tu cuenta de administrador siga teniendo permiso y reinténtalo.$$),
  ('he', 'adminSponsoredAdsWriteRejected', $$השרת דחה את השינוי (לא עודכנו שורות). ודא שחשבון המנהל שלך עדיין מורשה ונסה שוב.$$),

  -- Campaign preview status.
  ('en', 'adminSponsoredAdsLocalesPreservedNote', $$Locales saved for this campaign in other languages are preserved when you save.$$),
  ('es', 'adminSponsoredAdsLocalesPreservedNote', $$Los idiomas guardados para esta campaña en otros idiomas se conservan al guardar.$$),
  ('he', 'adminSponsoredAdsLocalesPreservedNote', $$השפות שנשמרו עבור קמפיין זה בשפות אחרות נשמרות בעת השמירה.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- ---------------------------------------------------------------------------
-- 6) Clean up the demo translation keys the admin app used to inject into new
--    creatives. They are no longer referenced by the app; leaving them in
--    place risks them being re-attached by hand.
-- ---------------------------------------------------------------------------
DELETE FROM public.translations
 WHERE key IN (
   'ads_test_1777449306261_headline',
   'ads_test_1777449306261_body',
   'ads_test_1777449306261_cta',
   'ads_test_1777449306262_sponsor'
 );

COMMIT;
