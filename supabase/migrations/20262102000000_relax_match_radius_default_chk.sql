-- Relax the match_radius_default check so km-scale options (e.g. 1000-3000 m
-- and larger, admin-configurable via profile.match_radius_options_meters) are
-- allowed. Previously the cap of 1000 broke updates whenever an option >= 2000
-- was chosen (users_match_radius_default_chk, code 23514).
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_match_radius_default_chk;

ALTER TABLE public.users
  ADD CONSTRAINT users_match_radius_default_chk
  CHECK (match_radius_default BETWEEN 1 AND 1000000);
