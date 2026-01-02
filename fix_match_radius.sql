-- Fix the Edge user's match radius (currently only 5 meters!)
-- This is why the users aren't matching - they're 1167 meters apart

UPDATE users
SET match_radius_default = 2000  -- Set to 2km radius (reasonable for city matching)
WHERE id = '35fe114e-eae5-49d6-9eba-8459617e7b82';

-- Verify the change
SELECT
    id,
    name,
    match_radius_default,
    'Radius updated to ' || match_radius_default || ' meters' as status
FROM users
WHERE id = '35fe114e-eae5-49d6-9eba-8459617e7b82';
