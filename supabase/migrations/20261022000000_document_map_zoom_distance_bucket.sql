-- Documentation only — no data or schema change.
--
-- matches.map_zoom is written by the matching functions as a DISTANCE BUCKET
-- describing how far apart the two users were when they matched:
--   16   = pair < 0.3 km
--   15.5 = pair < 0.6 km
--   15   = pair < 1.0 km
--   14.5 = pair < 2.0 km
--   13.5 = pair < 5.0 km
--   12.5 = pair < 10 km
--   11   = pair >= 10 km
--
-- It is deliberately NOT a display zoom. The client interprets the bucket in
-- lib/utils/match_map_view.dart and picks a zoom whose frame is large enough
-- to contain the real match location despite map_center_lat/lng being rounded
-- to 2 decimals (~556 m of uncertainty per axis).
--
-- Do NOT rewrite these values to look like display zooms: doing so makes the
-- match minimap show an area that excludes the actual match location.
-- Do NOT tighten the 2-decimal rounding either: that rounding is the privacy
-- guarantee (the minimap must center on the area without exposing a spot).

COMMENT ON COLUMN public.matches.map_zoom IS
  'Distance bucket written by matching (16 <300m, 15.5 <600m, 15 <1km, 14.5 <2km, 13.5 <5km, 12.5 <10km, 11 >=10km). Interpreted client-side by lib/utils/match_map_view.dart; NOT a display zoom.';
