-- Migration: Expand religion profile data and matching filters.
-- Date: 2026-10-20
-- Supersedes: 20262133000000_add_religiosity_profile_and_filter.sql
-- Purpose:
--   * Replace subjective religiousness labels with a concrete practice
--     frequency question.
--   * Add denominations/branches for each religion that has them.
--   * Add non-religious belief options: Atheist, Agnostic, Humanist,
--     Spiritual but not religious, and No religion.
--   * Store data inside the existing user_profiles.religion JSONB map:
--       { religion, denomination, practice }
--   * Store filters inside intent_preferences.religion_filters -> intent:
--       { religions: [], denominations: [], practices: [] }
--   * Enforce all three filters in public.check_preference_filter.
-- English fallbacks live in lib/providers/locale_provider.dart.

BEGIN;

------------------------------------------------------------------------------
-- 0) Remove the superseded religiosity question from the previous migration
------------------------------------------------------------------------------
DELETE FROM public.app_profile_options
WHERE field_key = 'religiosity';

DELETE FROM public.translations
WHERE key LIKE 'religiosity%'
   OR key IN (
     'profileReligiosity',
     'profileWizardReligiosityQuestion',
     'settingsReligiosity',
     'settingsReligiosityAny'
   );

------------------------------------------------------------------------------
-- 1) Broad religion / belief options
------------------------------------------------------------------------------
UPDATE public.app_profile_options
SET profile_sort_order = 99,
    filter_sort_order = 99
WHERE field_key = 'religion'
  AND option_key = 'other';

INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('religion', 'sikhism', 'Sikhism', 'sikhism',
   'religionSikhism', 'religionSikhism', 7, 7),
  ('religion', 'jainism', 'Jainism', 'jainism',
   'religionJainism', 'religionJainism', 8, 8),
  ('religion', 'zoroastrianism', 'Zoroastrianism', 'zoroastrianism',
   'religionZoroastrianism', 'religionZoroastrianism', 9, 9),
  ('religion', 'bahai', 'Bahá''í', 'bahai',
   'religionBahai', 'religionBahai', 10, 10),
  ('religion', 'shinto', 'Shinto', 'shinto',
   'religionShinto', 'religionShinto', 11, 11),
  ('religion', 'taoism', 'Taoism', 'taoism',
   'religionTaoism', 'religionTaoism', 12, 12),
  ('religion', 'indigenous_folk', 'Indigenous or folk religion', 'indigenous or folk religion',
   'religionIndigenousFolk', 'religionIndigenousFolk', 13, 13),
  ('religion', 'pagan_earth', 'Pagan or Earth-based spirituality', 'pagan or earth-based spirituality',
   'religionPaganEarth', 'religionPaganEarth', 14, 14),
  ('religion', 'spiritual_not_religious', 'Spiritual but not religious', 'spiritual but not religious',
   'religionSpiritualNotReligious', 'religionSpiritualNotReligious', 15, 15),
  ('religion', 'atheist', 'Atheist', 'atheist',
   'religionAtheist', 'religionAtheist', 16, 16),
  ('religion', 'agnostic', 'Agnostic', 'agnostic',
   'religionAgnostic', 'religionAgnostic', 17, 17),
  ('religion', 'humanist', 'Humanist', 'humanist',
   'religionHumanist', 'religionHumanist', 18, 18),
  ('religion', 'no_religion', 'No religion', 'no religion',
   'religionNoReligion', 'religionNoReligion', 19, 19)
ON CONFLICT (field_key, option_key) DO NOTHING;

------------------------------------------------------------------------------
-- 2) Denominations / branches
--    option_key format: <religion_option_key>__<denomination>
------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  -- Christianity
  ('denomination', 'christianity__catholic', 'christianity__catholic', 'christianity__catholic',
   'denominationChristianityCatholic', 'denominationChristianityCatholic', 1, 1),
  ('denomination', 'christianity__protestant', 'christianity__protestant', 'christianity__protestant',
   'denominationChristianityProtestant', 'denominationChristianityProtestant', 2, 2),
  ('denomination', 'christianity__anglican', 'christianity__anglican', 'christianity__anglican',
   'denominationChristianityAnglican', 'denominationChristianityAnglican', 3, 3),
  ('denomination', 'christianity__baptist', 'christianity__baptist', 'christianity__baptist',
   'denominationChristianityBaptist', 'denominationChristianityBaptist', 4, 4),
  ('denomination', 'christianity__lutheran', 'christianity__lutheran', 'christianity__lutheran',
   'denominationChristianityLutheran', 'denominationChristianityLutheran', 5, 5),
  ('denomination', 'christianity__methodist', 'christianity__methodist', 'christianity__methodist',
   'denominationChristianityMethodist', 'denominationChristianityMethodist', 6, 6),
  ('denomination', 'christianity__presbyterian_reformed', 'christianity__presbyterian_reformed', 'christianity__presbyterian_reformed',
   'denominationChristianityPresbyterianReformed', 'denominationChristianityPresbyterianReformed', 7, 7),
  ('denomination', 'christianity__pentecostal_charismatic', 'christianity__pentecostal_charismatic', 'christianity__pentecostal_charismatic',
   'denominationChristianityPentecostalCharismatic', 'denominationChristianityPentecostalCharismatic', 8, 8),
  ('denomination', 'christianity__evangelical', 'christianity__evangelical', 'christianity__evangelical',
   'denominationChristianityEvangelical', 'denominationChristianityEvangelical', 9, 9),
  ('denomination', 'christianity__eastern_orthodox', 'christianity__eastern_orthodox', 'christianity__eastern_orthodox',
   'denominationChristianityEasternOrthodox', 'denominationChristianityEasternOrthodox', 10, 10),
  ('denomination', 'christianity__oriental_orthodox', 'christianity__oriental_orthodox', 'christianity__oriental_orthodox',
   'denominationChristianityOrientalOrthodox', 'denominationChristianityOrientalOrthodox', 11, 11),
  ('denomination', 'christianity__latter_day_saints', 'christianity__latter_day_saints', 'christianity__latter_day_saints',
   'denominationChristianityLatterDaySaints', 'denominationChristianityLatterDaySaints', 12, 12),
  ('denomination', 'christianity__jehovahs_witnesses', 'christianity__jehovahs_witnesses', 'christianity__jehovahs_witnesses',
   'denominationChristianityJehovahsWitnesses', 'denominationChristianityJehovahsWitnesses', 13, 13),
  ('denomination', 'christianity__other', 'christianity__other', 'christianity__other',
   'denominationChristianityOther', 'denominationChristianityOther', 14, 14),

  -- Islam
  ('denomination', 'islam__sunni', 'islam__sunni', 'islam__sunni',
   'denominationIslamSunni', 'denominationIslamSunni', 1, 1),
  ('denomination', 'islam__shia', 'islam__shia', 'islam__shia',
   'denominationIslamShia', 'denominationIslamShia', 2, 2),
  ('denomination', 'islam__ibadi', 'islam__ibadi', 'islam__ibadi',
   'denominationIslamIbadi', 'denominationIslamIbadi', 3, 3),
  ('denomination', 'islam__ahmadiyya', 'islam__ahmadiyya', 'islam__ahmadiyya',
   'denominationIslamAhmadiyya', 'denominationIslamAhmadiyya', 4, 4),
  ('denomination', 'islam__sufi', 'islam__sufi', 'islam__sufi',
   'denominationIslamSufi', 'denominationIslamSufi', 5, 5),
  ('denomination', 'islam__other', 'islam__other', 'islam__other',
   'denominationIslamOther', 'denominationIslamOther', 6, 6),

  -- Judaism
  ('denomination', 'judaism__orthodox', 'judaism__orthodox', 'judaism__orthodox',
   'denominationJudaismOrthodox', 'denominationJudaismOrthodox', 1, 1),
  ('denomination', 'judaism__conservative', 'judaism__conservative', 'judaism__conservative',
   'denominationJudaismConservative', 'denominationJudaismConservative', 2, 2),
  ('denomination', 'judaism__reform', 'judaism__reform', 'judaism__reform',
   'denominationJudaismReform', 'denominationJudaismReform', 3, 3),
  ('denomination', 'judaism__reconstructionist', 'judaism__reconstructionist', 'judaism__reconstructionist',
   'denominationJudaismReconstructionist', 'denominationJudaismReconstructionist', 4, 4),
  ('denomination', 'judaism__hasidic', 'judaism__hasidic', 'judaism__hasidic',
   'denominationJudaismHasidic', 'denominationJudaismHasidic', 5, 5),
  ('denomination', 'judaism__secular_cultural', 'judaism__secular_cultural', 'judaism__secular_cultural',
   'denominationJudaismSecularCultural', 'denominationJudaismSecularCultural', 6, 6),
  ('denomination', 'judaism__other', 'judaism__other', 'judaism__other',
   'denominationJudaismOther', 'denominationJudaismOther', 7, 7),

  -- Hinduism
  ('denomination', 'hinduism__vaishnavism', 'hinduism__vaishnavism', 'hinduism__vaishnavism',
   'denominationHinduismVaishnavism', 'denominationHinduismVaishnavism', 1, 1),
  ('denomination', 'hinduism__shaivism', 'hinduism__shaivism', 'hinduism__shaivism',
   'denominationHinduismShaivism', 'denominationHinduismShaivism', 2, 2),
  ('denomination', 'hinduism__shaktism', 'hinduism__shaktism', 'hinduism__shaktism',
   'denominationHinduismShaktism', 'denominationHinduismShaktism', 3, 3),
  ('denomination', 'hinduism__smartism', 'hinduism__smartism', 'hinduism__smartism',
   'denominationHinduismSmartism', 'denominationHinduismSmartism', 4, 4),
  ('denomination', 'hinduism__other', 'hinduism__other', 'hinduism__other',
   'denominationHinduismOther', 'denominationHinduismOther', 5, 5),

  -- Buddhism
  ('denomination', 'buddhism__theravada', 'buddhism__theravada', 'buddhism__theravada',
   'denominationBuddhismTheravada', 'denominationBuddhismTheravada', 1, 1),
  ('denomination', 'buddhism__mahayana', 'buddhism__mahayana', 'buddhism__mahayana',
   'denominationBuddhismMahayana', 'denominationBuddhismMahayana', 2, 2),
  ('denomination', 'buddhism__zen', 'buddhism__zen', 'buddhism__zen',
   'denominationBuddhismZen', 'denominationBuddhismZen', 3, 3),
  ('denomination', 'buddhism__vajrayana', 'buddhism__vajrayana', 'buddhism__vajrayana',
   'denominationBuddhismVajrayana', 'denominationBuddhismVajrayana', 4, 4),
  ('denomination', 'buddhism__pure_land', 'buddhism__pure_land', 'buddhism__pure_land',
   'denominationBuddhismPureLand', 'denominationBuddhismPureLand', 5, 5),
  ('denomination', 'buddhism__nichiren', 'buddhism__nichiren', 'buddhism__nichiren',
   'denominationBuddhismNichiren', 'denominationBuddhismNichiren', 6, 6),
  ('denomination', 'buddhism__other', 'buddhism__other', 'buddhism__other',
   'denominationBuddhismOther', 'denominationBuddhismOther', 7, 7),

  -- Sikhism
  ('denomination', 'sikhism__khalsa', 'sikhism__khalsa', 'sikhism__khalsa',
   'denominationSikhismKhalsa', 'denominationSikhismKhalsa', 1, 1),
  ('denomination', 'sikhism__nanakpanthi', 'sikhism__nanakpanthi', 'sikhism__nanakpanthi',
   'denominationSikhismNanakpanthi', 'denominationSikhismNanakpanthi', 2, 2),
  ('denomination', 'sikhism__other', 'sikhism__other', 'sikhism__other',
   'denominationSikhismOther', 'denominationSikhismOther', 3, 3),

  -- Jainism
  ('denomination', 'jainism__digambara', 'jainism__digambara', 'jainism__digambara',
   'denominationJainismDigambara', 'denominationJainismDigambara', 1, 1),
  ('denomination', 'jainism__svetambara', 'jainism__svetambara', 'jainism__svetambara',
   'denominationJainismSvetambara', 'denominationJainismSvetambara', 2, 2),
  ('denomination', 'jainism__other', 'jainism__other', 'jainism__other',
   'denominationJainismOther', 'denominationJainismOther', 3, 3),

  -- Zoroastrianism
  ('denomination', 'zoroastrianism__orthodox', 'zoroastrianism__orthodox', 'zoroastrianism__orthodox',
   'denominationZoroastrianismOrthodox', 'denominationZoroastrianismOrthodox', 1, 1),
  ('denomination', 'zoroastrianism__reformist', 'zoroastrianism__reformist', 'zoroastrianism__reformist',
   'denominationZoroastrianismReformist', 'denominationZoroastrianismReformist', 2, 2),
  ('denomination', 'zoroastrianism__other', 'zoroastrianism__other', 'zoroastrianism__other',
   'denominationZoroastrianismOther', 'denominationZoroastrianismOther', 3, 3),

  -- Shinto
  ('denomination', 'shinto__shrine', 'shinto__shrine', 'shinto__shrine',
   'denominationShintoShrine', 'denominationShintoShrine', 1, 1),
  ('denomination', 'shinto__sect', 'shinto__sect', 'shinto__sect',
   'denominationShintoSect', 'denominationShintoSect', 2, 2),
  ('denomination', 'shinto__other', 'shinto__other', 'shinto__other',
   'denominationShintoOther', 'denominationShintoOther', 3, 3),

  -- Taoism
  ('denomination', 'taoism__quanzhen', 'taoism__quanzhen', 'taoism__quanzhen',
   'denominationTaoismQuanzhen', 'denominationTaoismQuanzhen', 1, 1),
  ('denomination', 'taoism__zhengyi', 'taoism__zhengyi', 'taoism__zhengyi',
   'denominationTaoismZhengyi', 'denominationTaoismZhengyi', 2, 2),
  ('denomination', 'taoism__other', 'taoism__other', 'taoism__other',
   'denominationTaoismOther', 'denominationTaoismOther', 3, 3),

  -- Pagan / Earth-based
  ('denomination', 'pagan_earth__wiccan', 'pagan_earth__wiccan', 'pagan_earth__wiccan',
   'denominationPaganEarthWiccan', 'denominationPaganEarthWiccan', 1, 1),
  ('denomination', 'pagan_earth__druid', 'pagan_earth__druid', 'pagan_earth__druid',
   'denominationPaganEarthDruid', 'denominationPaganEarthDruid', 2, 2),
  ('denomination', 'pagan_earth__heathen', 'pagan_earth__heathen', 'pagan_earth__heathen',
   'denominationPaganEarthHeathen', 'denominationPaganEarthHeathen', 3, 3),
  ('denomination', 'pagan_earth__other', 'pagan_earth__other', 'pagan_earth__other',
   'denominationPaganEarthOther', 'denominationPaganEarthOther', 4, 4)
ON CONFLICT (field_key, option_key) DO NOTHING;

------------------------------------------------------------------------------
-- 3) Practice frequency (concrete, non-judgmental options)
------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('practice', 'daily', 'daily', 'daily',
   'practiceDaily', 'practiceDaily', 1, 1),
  ('practice', 'weekly', 'weekly', 'weekly',
   'practiceWeekly', 'practiceWeekly', 2, 2),
  ('practice', 'monthly', 'monthly', 'monthly',
   'practiceMonthly', 'practiceMonthly', 3, 3),
  ('practice', 'few_times_a_year', 'few_times_a_year', 'few_times_a_year',
   'practiceFewTimesAYear', 'practiceFewTimesAYear', 4, 4),
  ('practice', 'rarely_or_never', 'rarely_or_never', 'rarely_or_never',
   'practiceRarelyOrNever', 'practiceRarelyOrNever', 5, 5)
ON CONFLICT (field_key, option_key) DO NOTHING;

------------------------------------------------------------------------------
-- 4) Translations (en/es/he)
------------------------------------------------------------------------------
INSERT INTO public.translations (locale, key, value) VALUES
  -- English labels
  ('en', 'profileReligion', $$Religion or belief$$),
  ('en', 'profileDenomination', $$Denomination or branch$$),
  ('en', 'profileReligiousPractice', $$Religious practice$$),
  ('en', 'profileWizardReligionTitle', $$Religion or Belief$$),
  ('en', 'profileWizardReligionSubtitle',
   $$Share your religion or belief, denomination, and practice. All fields are optional.$$),
  ('en', 'profileWizardDenominationQuestion', $$Which denomination or branch?$$),
  ('en', 'profileWizardPracticeQuestion',
   $$How often do you engage in religious or spiritual practices?$$),
  ('en', 'settingsReligion', $$Religion or belief$$),
  ('en', 'settingsDenomination', $$Denomination or branch$$),
  ('en', 'settingsPractice', $$Religious practice$$),
  ('en', 'voiceGuidanceStepReligion',
   $$Choose your religion or belief, denomination, and practice, then tap Next.$$),

  -- English religion options
  ('en', 'religionSikhism', $$Sikhism$$),
  ('en', 'religionJainism', $$Jainism$$),
  ('en', 'religionZoroastrianism', $$Zoroastrianism$$),
  ('en', 'religionBahai', $$Bahá'í$$),
  ('en', 'religionShinto', $$Shinto$$),
  ('en', 'religionTaoism', $$Taoism$$),
  ('en', 'religionIndigenousFolk', $$Indigenous or folk religion$$),
  ('en', 'religionPaganEarth', $$Pagan or Earth-based spirituality$$),
  ('en', 'religionSpiritualNotReligious', $$Spiritual but not religious$$),
  ('en', 'religionAtheist', $$Atheist$$),
  ('en', 'religionAgnostic', $$Agnostic$$),
  ('en', 'religionHumanist', $$Humanist$$),
  ('en', 'religionNoReligion', $$No religion$$),

  -- English denominations
  ('en', 'denominationChristianityCatholic', $$Catholic$$),
  ('en', 'denominationChristianityProtestant', $$Protestant$$),
  ('en', 'denominationChristianityAnglican', $$Anglican or Episcopal$$),
  ('en', 'denominationChristianityBaptist', $$Baptist$$),
  ('en', 'denominationChristianityLutheran', $$Lutheran$$),
  ('en', 'denominationChristianityMethodist', $$Methodist$$),
  ('en', 'denominationChristianityPresbyterianReformed', $$Presbyterian or Reformed$$),
  ('en', 'denominationChristianityPentecostalCharismatic', $$Pentecostal or Charismatic$$),
  ('en', 'denominationChristianityEvangelical', $$Evangelical$$),
  ('en', 'denominationChristianityEasternOrthodox', $$Eastern Orthodox$$),
  ('en', 'denominationChristianityOrientalOrthodox', $$Oriental Orthodox$$),
  ('en', 'denominationChristianityLatterDaySaints', $$Latter-day Saints$$),
  ('en', 'denominationChristianityJehovahsWitnesses', $$Jehovah's Witnesses$$),
  ('en', 'denominationChristianityOther', $$Other Christian$$),
  ('en', 'denominationIslamSunni', $$Sunni$$),
  ('en', 'denominationIslamShia', $$Shia$$),
  ('en', 'denominationIslamIbadi', $$Ibadi$$),
  ('en', 'denominationIslamAhmadiyya', $$Ahmadiyya$$),
  ('en', 'denominationIslamSufi', $$Sufi$$),
  ('en', 'denominationIslamOther', $$Other Muslim$$),
  ('en', 'denominationJudaismOrthodox', $$Orthodox$$),
  ('en', 'denominationJudaismConservative', $$Conservative or Masorti$$),
  ('en', 'denominationJudaismReform', $$Reform$$),
  ('en', 'denominationJudaismReconstructionist', $$Reconstructionist$$),
  ('en', 'denominationJudaismHasidic', $$Hasidic$$),
  ('en', 'denominationJudaismSecularCultural', $$Secular or cultural Jewish$$),
  ('en', 'denominationJudaismOther', $$Other Jewish$$),
  ('en', 'denominationHinduismVaishnavism', $$Vaishnavism$$),
  ('en', 'denominationHinduismShaivism', $$Shaivism$$),
  ('en', 'denominationHinduismShaktism', $$Shaktism$$),
  ('en', 'denominationHinduismSmartism', $$Smartism$$),
  ('en', 'denominationHinduismOther', $$Other Hindu$$),
  ('en', 'denominationBuddhismTheravada', $$Theravada$$),
  ('en', 'denominationBuddhismMahayana', $$Mahayana$$),
  ('en', 'denominationBuddhismZen', $$Zen$$),
  ('en', 'denominationBuddhismVajrayana', $$Vajrayana or Tibetan$$),
  ('en', 'denominationBuddhismPureLand', $$Pure Land$$),
  ('en', 'denominationBuddhismNichiren', $$Nichiren$$),
  ('en', 'denominationBuddhismOther', $$Other Buddhist$$),
  ('en', 'denominationSikhismKhalsa', $$Khalsa$$),
  ('en', 'denominationSikhismNanakpanthi', $$Nanakpanthi$$),
  ('en', 'denominationSikhismOther', $$Other Sikh$$),
  ('en', 'denominationJainismDigambara', $$Digambara$$),
  ('en', 'denominationJainismSvetambara', $$Śvētāmbara$$),
  ('en', 'denominationJainismOther', $$Other Jain$$),
  ('en', 'denominationZoroastrianismOrthodox', $$Orthodox$$),
  ('en', 'denominationZoroastrianismReformist', $$Reformist$$),
  ('en', 'denominationZoroastrianismOther', $$Other Zoroastrian$$),
  ('en', 'denominationShintoShrine', $$Shrine Shinto$$),
  ('en', 'denominationShintoSect', $$Sect Shinto$$),
  ('en', 'denominationShintoOther', $$Other Shinto$$),
  ('en', 'denominationTaoismQuanzhen', $$Quanzhen$$),
  ('en', 'denominationTaoismZhengyi', $$Zhengyi$$),
  ('en', 'denominationTaoismOther', $$Other Taoist$$),
  ('en', 'denominationPaganEarthWiccan', $$Wiccan$$),
  ('en', 'denominationPaganEarthDruid', $$Druid$$),
  ('en', 'denominationPaganEarthHeathen', $$Heathen$$),
  ('en', 'denominationPaganEarthOther', $$Other pagan or Earth-based$$),

  -- English practice options
  ('en', 'practiceDaily', $$Daily or almost daily$$),
  ('en', 'practiceWeekly', $$Weekly$$),
  ('en', 'practiceMonthly', $$Monthly$$),
  ('en', 'practiceFewTimesAYear', $$A few times a year$$),
  ('en', 'practiceRarelyOrNever', $$Rarely or never$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish labels
  ('es', 'profileReligion', $$Religión o creencias$$),
  ('es', 'profileDenomination', $$Denominación o rama$$),
  ('es', 'profileReligiousPractice', $$Práctica religiosa$$),
  ('es', 'profileWizardReligionTitle', $$Religión o creencias$$),
  ('es', 'profileWizardReligionSubtitle',
   $$Comparte tu religión o creencias, denominación y práctica. Todos los campos son opcionales.$$),
  ('es', 'profileWizardDenominationQuestion', $$¿Qué denominación o rama?$$),
  ('es', 'profileWizardPracticeQuestion',
   $$¿Con qué frecuencia practicas actividades religiosas o espirituales?$$),
  ('es', 'settingsReligion', $$Religión o creencias$$),
  ('es', 'settingsDenomination', $$Denominación o rama$$),
  ('es', 'settingsPractice', $$Práctica religiosa$$),
  ('es', 'voiceGuidanceStepReligion',
   $$Elige tu religión o creencias, denominación y práctica, luego toca Siguiente.$$),

  -- Spanish religion options
  ('es', 'religionSikhism', $$Sijismo$$),
  ('es', 'religionJainism', $$Jainismo$$),
  ('es', 'religionZoroastrianism', $$Zoroastrismo$$),
  ('es', 'religionBahai', $$Bahá'í$$),
  ('es', 'religionShinto', $$Sintoísmo$$),
  ('es', 'religionTaoism', $$Taoísmo$$),
  ('es', 'religionIndigenousFolk', $$Religión indígena o popular$$),
  ('es', 'religionPaganEarth', $$Espiritualidad pagana o basada en la tierra$$),
  ('es', 'religionSpiritualNotReligious', $$Espiritual pero no religioso$$),
  ('es', 'religionAtheist', $$Ateo$$),
  ('es', 'religionAgnostic', $$Agnóstico$$),
  ('es', 'religionHumanist', $$Humanista$$),
  ('es', 'religionNoReligion', $$Sin religión$$),

  -- Spanish denominations
  ('es', 'denominationChristianityCatholic', $$Católico$$),
  ('es', 'denominationChristianityProtestant', $$Protestante$$),
  ('es', 'denominationChristianityAnglican', $$Anglicano o episcopal$$),
  ('es', 'denominationChristianityBaptist', $$Bautista$$),
  ('es', 'denominationChristianityLutheran', $$Luterano$$),
  ('es', 'denominationChristianityMethodist', $$Metodista$$),
  ('es', 'denominationChristianityPresbyterianReformed', $$Presbiteriano o reformado$$),
  ('es', 'denominationChristianityPentecostalCharismatic', $$Pentecostal o carismático$$),
  ('es', 'denominationChristianityEvangelical', $$Evangélico$$),
  ('es', 'denominationChristianityEasternOrthodox', $$Ortodoxo oriental$$),
  ('es', 'denominationChristianityOrientalOrthodox', $$Ortodoxo copto$$),
  ('es', 'denominationChristianityLatterDaySaints', $$Santos de los Últimos Días$$),
  ('es', 'denominationChristianityJehovahsWitnesses', $$Testigos de Jehová$$),
  ('es', 'denominationChristianityOther', $$Otro cristiano$$),
  ('es', 'denominationIslamSunni', $$Sunita$$),
  ('es', 'denominationIslamShia', $$Chiita$$),
  ('es', 'denominationIslamIbadi', $$Ibadí$$),
  ('es', 'denominationIslamAhmadiyya', $$Ahmadía$$),
  ('es', 'denominationIslamSufi', $$Sufí$$),
  ('es', 'denominationIslamOther', $$Otro musulmán$$),
  ('es', 'denominationJudaismOrthodox', $$Ortodoxo$$),
  ('es', 'denominationJudaismConservative', $$Conservador o Masortí$$),
  ('es', 'denominationJudaismReform', $$Reformista$$),
  ('es', 'denominationJudaismReconstructionist', $$Reconstruccionista$$),
  ('es', 'denominationJudaismHasidic', $$Jasídico$$),
  ('es', 'denominationJudaismSecularCultural', $$Judío secular o cultural$$),
  ('es', 'denominationJudaismOther', $$Otro judío$$),
  ('es', 'denominationHinduismVaishnavism', $$Vaishnavismo$$),
  ('es', 'denominationHinduismShaivism', $$Shaivismo$$),
  ('es', 'denominationHinduismShaktism', $$Shaktismo$$),
  ('es', 'denominationHinduismSmartism', $$Smartismo$$),
  ('es', 'denominationHinduismOther', $$Otro hindú$$),
  ('es', 'denominationBuddhismTheravada', $$Theravada$$),
  ('es', 'denominationBuddhismMahayana', $$Mahayana$$),
  ('es', 'denominationBuddhismZen', $$Zen$$),
  ('es', 'denominationBuddhismVajrayana', $$Vajrayana o tibetano$$),
  ('es', 'denominationBuddhismPureLand', $$Tierra Pura$$),
  ('es', 'denominationBuddhismNichiren', $$Nichiren$$),
  ('es', 'denominationBuddhismOther', $$Otro budista$$),
  ('es', 'denominationSikhismKhalsa', $$Khalsa$$),
  ('es', 'denominationSikhismNanakpanthi', $$Nanakpanthi$$),
  ('es', 'denominationSikhismOther', $$Otro sij$$),
  ('es', 'denominationJainismDigambara', $$Digambara$$),
  ('es', 'denominationJainismSvetambara', $$Śvētāmbara$$),
  ('es', 'denominationJainismOther', $$Otro jainista$$),
  ('es', 'denominationZoroastrianismOrthodox', $$Ortodoxo$$),
  ('es', 'denominationZoroastrianismReformist', $$Reformista$$),
  ('es', 'denominationZoroastrianismOther', $$Otro zoroastriano$$),
  ('es', 'denominationShintoShrine', $$Sintoísmo de santuarios$$),
  ('es', 'denominationShintoSect', $$Sintoísmo de sectas$$),
  ('es', 'denominationShintoOther', $$Otro sintoísta$$),
  ('es', 'denominationTaoismQuanzhen', $$Quanzhen$$),
  ('es', 'denominationTaoismZhengyi', $$Zhengyi$$),
  ('es', 'denominationTaoismOther', $$Otro taoísta$$),
  ('es', 'denominationPaganEarthWiccan', $$Wiccano$$),
  ('es', 'denominationPaganEarthDruid', $$Druida$$),
  ('es', 'denominationPaganEarthHeathen', $$Heathen$$),
  ('es', 'denominationPaganEarthOther', $$Otro pagano o basado en la tierra$$),

  -- Spanish practice options
  ('es', 'practiceDaily', $$A diario o casi a diario$$),
  ('es', 'practiceWeekly', $$Semanalmente$$),
  ('es', 'practiceMonthly', $$Mensualmente$$),
  ('es', 'practiceFewTimesAYear', $$Algunas veces al año$$),
  ('es', 'practiceRarelyOrNever', $$Rara vez o nunca$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew labels
  ('he', 'profileReligion', $$דת או אמונה$$),
  ('he', 'profileDenomination', $$זרם או עדה$$),
  ('he', 'profileReligiousPractice', $$פרקטיקה דתית$$),
  ('he', 'profileWizardReligionTitle', $$דת או אמונה$$),
  ('he', 'profileWizardReligionSubtitle',
   $$שתף את הדת או האמונה שלך, הזרם והפרקטיקה. כל השדות אופציונליים.$$),
  ('he', 'profileWizardDenominationQuestion', $$איזה זרם או עדה?$$),
  ('he', 'profileWizardPracticeQuestion',
   $$באיזו תדירות אתה עוסק בפרקטיקות דתיות או רוחניות?$$),
  ('he', 'settingsReligion', $$דת או אמונה$$),
  ('he', 'settingsDenomination', $$זרם או עדה$$),
  ('he', 'settingsPractice', $$פרקטיקה דתית$$),
  ('he', 'voiceGuidanceStepReligion',
   $$בחר את הדת או האמונה, הזרם והפרקטיקה שלך, ואז הקש הבא.$$),

  -- Hebrew religion options
  ('he', 'religionSikhism', $$סיקיזם$$),
  ('he', 'religionJainism', $$ג'ייניזם$$),
  ('he', 'religionZoroastrianism', $$זורואסטריות$$),
  ('he', 'religionBahai', $$בהאא'י$$),
  ('he', 'religionShinto', $$שינטו$$),
  ('he', 'religionTaoism', $$טאואיזם$$),
  ('he', 'religionIndigenousFolk', $$דת ילידית או עממית$$),
  ('he', 'religionPaganEarth', $$רוחניות פגנית או מבוססת אדמה$$),
  ('he', 'religionSpiritualNotReligious', $$רוחני אך לא דתי$$),
  ('he', 'religionAtheist', $$אתאיסט$$),
  ('he', 'religionAgnostic', $$אגנוסטי$$),
  ('he', 'religionHumanist', $$הומניסט$$),
  ('he', 'religionNoReligion', $$ללא דת$$),

  -- Hebrew denominations
  ('he', 'denominationChristianityCatholic', $$קתולי$$),
  ('he', 'denominationChristianityProtestant', $$פרוטסטנטי$$),
  ('he', 'denominationChristianityAnglican', $$אנגליקני או אפיסקופלי$$),
  ('he', 'denominationChristianityBaptist', $$בפטיסטי$$),
  ('he', 'denominationChristianityLutheran', $$לותרני$$),
  ('he', 'denominationChristianityMethodist', $$מתודיסטי$$),
  ('he', 'denominationChristianityPresbyterianReformed', $$פרסביטריאני או רפורמי$$),
  ('he', 'denominationChristianityPentecostalCharismatic', $$פנטקוסטלי או כריזמטי$$),
  ('he', 'denominationChristianityEvangelical', $$אוונגלי$$),
  ('he', 'denominationChristianityEasternOrthodox', $$אורתודוקסי מזרחי$$),
  ('he', 'denominationChristianityOrientalOrthodox', $$אורתודוקסי אוריינטלי$$),
  ('he', 'denominationChristianityLatterDaySaints', $$קדושי אחרית הימים$$),
  ('he', 'denominationChristianityJehovahsWitnesses', $$עדי יהוה$$),
  ('he', 'denominationChristianityOther', $$נוצרי אחר$$),
  ('he', 'denominationIslamSunni', $$סוני$$),
  ('he', 'denominationIslamShia', $$שיעי$$),
  ('he', 'denominationIslamIbadi', $$איבאדי$$),
  ('he', 'denominationIslamAhmadiyya', $$אחמדיה$$),
  ('he', 'denominationIslamSufi', $$סופי$$),
  ('he', 'denominationIslamOther', $$מוסלמי אחר$$),
  ('he', 'denominationJudaismOrthodox', $$אורתודוקסי$$),
  ('he', 'denominationJudaismConservative', $$קונסרבטיבי או מסורתי$$),
  ('he', 'denominationJudaismReform', $$רפורמי$$),
  ('he', 'denominationJudaismReconstructionist', $$רקונסטרוקציוניסטי$$),
  ('he', 'denominationJudaismHasidic', $$חסידי$$),
  ('he', 'denominationJudaismSecularCultural', $$יהודי חילוני או תרבותי$$),
  ('he', 'denominationJudaismOther', $$יהודי אחר$$),
  ('he', 'denominationHinduismVaishnavism', $$וישנויזם$$),
  ('he', 'denominationHinduismShaivism', $$שיוויזם$$),
  ('he', 'denominationHinduismShaktism', $$שאקטיזם$$),
  ('he', 'denominationHinduismSmartism', $$סמארטיזם$$),
  ('he', 'denominationHinduismOther', $$הינדי אחר$$),
  ('he', 'denominationBuddhismTheravada', $$תרוואדה$$),
  ('he', 'denominationBuddhismMahayana', $$מהאיאנה$$),
  ('he', 'denominationBuddhismZen', $$זן$$),
  ('he', 'denominationBuddhismVajrayana', $$וג'ריאנה או טיבטי$$),
  ('he', 'denominationBuddhismPureLand', $$ארץ טהורה$$),
  ('he', 'denominationBuddhismNichiren', $$ניצ'ירן$$),
  ('he', 'denominationBuddhismOther', $$בודהיסטי אחר$$),
  ('he', 'denominationSikhismKhalsa', $$ח'אלסה$$),
  ('he', 'denominationSikhismNanakpanthi', $$ננקפנתי$$),
  ('he', 'denominationSikhismOther', $$סיקי אחר$$),
  ('he', 'denominationJainismDigambara', $$דיגמבארה$$),
  ('he', 'denominationJainismSvetambara', $$שווטמבארה$$),
  ('he', 'denominationJainismOther', $$ג'ייני אחר$$),
  ('he', 'denominationZoroastrianismOrthodox', $$אורתודוקסי$$),
  ('he', 'denominationZoroastrianismReformist', $$רפורמיסטי$$),
  ('he', 'denominationZoroastrianismOther', $$זורואסטרי אחר$$),
  ('he', 'denominationShintoShrine', $$שינטו מקדשים$$),
  ('he', 'denominationShintoSect', $$שינטו כתות$$),
  ('he', 'denominationShintoOther', $$שינטו אחר$$),
  ('he', 'denominationTaoismQuanzhen', $$צ'ואנז'ן$$),
  ('he', 'denominationTaoismZhengyi', $$ג'נג'י$$),
  ('he', 'denominationTaoismOther', $$טאואיסט אחר$$),
  ('he', 'denominationPaganEarthWiccan', $$ויקן$$),
  ('he', 'denominationPaganEarthDruid', $$דרואיד$$),
  ('he', 'denominationPaganEarthHeathen', $$פגני נורדי$$),
  ('he', 'denominationPaganEarthOther', $$פגני או מבוסס אדמה אחר$$),

  -- Hebrew practice options
  ('he', 'practiceDaily', $$מדי יום או כמעט מדי יום$$),
  ('he', 'practiceWeekly', $$מדי שבוע$$),
  ('he', 'practiceMonthly', $$מדי חודש$$),
  ('he', 'practiceFewTimesAYear', $$כמה פעמים בשנה$$),
  ('he', 'practiceRarelyOrNever', $$לעיתים רחוקות או אף פעם$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

------------------------------------------------------------------------------
-- 5) check_preference_filter — enforce religion, denomination, and practice.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_preference_filter(
    p_filters JSONB,
    p_candidate JSONB,
    p_candidate_height INTEGER,
    p_filter_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_vals TEXT[];
    v_filter_val TEXT;
BEGIN
    IF p_filters IS NULL THEN
        RETURN TRUE;
    END IF;

    IF p_filter_type = 'lifestyle' THEN
        -- Smoking
        v_vals := _filter_values(p_filters, 'smoking');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'smoking') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'smoking') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Drinking
        v_vals := _filter_values(p_filters, 'drinking');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'drinking') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'drinking') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Diet (stored as 'diets' key)
        v_vals := _filter_values(p_filters, 'diets');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'diet') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'diet') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Exercise
        v_vals := _filter_values(p_filters, 'exercise');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'exercise') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'exercise') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'family' THEN
        -- Has children (stored as boolean string in DB, filter uses 'yes'/'no')
        v_vals := _filter_values(p_filters, 'has_children');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'has_children') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF 'yes' = ANY(v_vals) AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM TRUE THEN
                RETURN FALSE;
            END IF;
            IF 'no' = ANY(v_vals) AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM FALSE THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Wants children
        v_vals := _filter_values(p_filters, 'wants_children');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'wants_children') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'wants_children') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'religion' THEN
        -- Broad religion or belief
        v_vals := _filter_values(p_filters, 'religions');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'religion') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'religion') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Denomination / branch (stored as a religion-qualified slug)
        v_vals := _filter_values(p_filters, 'denominations');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'denomination') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'denomination') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Practice frequency
        v_vals := _filter_values(p_filters, 'practices');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'practice') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'practice') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'height' THEN
        -- No range configured → height is not a criterion at all.
        IF NOT (p_filters ? 'min') AND NOT (p_filters ? 'max') THEN
            RETURN TRUE;
        END IF;
        -- A range is configured, so the candidate must have a height in range.
        IF p_candidate_height IS NULL THEN
            RETURN FALSE;
        END IF;
        IF (p_filters ? 'min') AND p_candidate_height < (p_filters ->> 'min')::numeric THEN
            RETURN FALSE;
        END IF;
        IF (p_filters ? 'max') AND p_candidate_height > (p_filters ->> 'max')::numeric THEN
            RETURN FALSE;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO anon;

COMMIT;
